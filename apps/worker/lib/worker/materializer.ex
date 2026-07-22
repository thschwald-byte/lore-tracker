defmodule Worker.Materializer do
  @moduledoc """
  Applies events from the Hub to the local Mnesia view.

  Idempotent: events with `seq <= last_applied_seq` are dropped (echo
  protection on reconnect / repeated catch-ups). Each apply happens in a
  single Mnesia transaction that also bumps `last_applied_seq`, so the
  cursor never drifts from the materialized state.

  Per-kind handlers (`apply_kind/3`) are added as new event types land.
  Unknown kinds are logged + ignored — forward-compatible: a fresh
  worker can replay an event log produced by a newer hub without dying.
  """

  use GenServer

  require Logger

  alias Worker.Schema.Mnesia, as: S

  # ─── API ──────────────────────────────────────────────────────────

  # Issue #717: expliziter Call-Timeout statt implizitem 5s-Default. Ein
  # Einzel-Apply ist eine Mnesia-Tx + Store-Writes — unter Last (Backfill
  # parallel zu Recording, Disc-Flush) sind 5 s knapp; die Aufrufer sitzen
  # im Slipstream-Handler bzw. in Intents-Tasks, ein Timeout-Raise reißt
  # dort den Sync-Pfad mit. 15 s ist bewusst großzügig, aber endlich.
  @call_timeout 15_000

  # Issue #717: Batch-Timeout wächst mit der Batch-Größe (Cold-Start-Chunks
  # kommen mit Hunderten Events, vgl. #690: 15k-Backfill in 200-KB-Chunks),
  # gedeckelt damit ein echter Hänger nicht ewig blockiert.
  @batch_timeout_base 15_000
  @batch_timeout_per_event 25
  @batch_timeout_max 120_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec apply_event(map()) :: {:applied, pos_integer()} | :skipped
  def apply_event(event), do: GenServer.call(__MODULE__, {:apply, event}, @call_timeout)

  @doc """
  Issue #717: Batch-Apply als EIN GenServer-Call statt N serieller Roundtrips.
  Vorher iterierte `apply_batch/1` call-für-call — bei Cold-Start-Backfills
  (Hunderte Events pro Pull-Chunk) hieß das N × Message-Roundtrip aus dem
  Slipstream-Handler, und jeder Einzel-Call trug sein eigenes 5s-Fenster.
  Jetzt läuft die Schleife im Materializer-Prozess; der Timeout skaliert mit
  der Batch-Größe. Events bleiben strikt sequenziell applied (Reihenfolge +
  Idempotenz unverändert). Liefert wie zuvor die höchste applied seq.
  """
  @spec apply_batch([map()]) :: non_neg_integer()
  def apply_batch([]), do: last_applied_seq()

  def apply_batch(events) when is_list(events) do
    timeout =
      min(@batch_timeout_base + @batch_timeout_per_event * length(events), @batch_timeout_max)

    GenServer.call(__MODULE__, {:apply_batch, events}, timeout)
  end

  @spec last_applied_seq() :: non_neg_integer()
  def last_applied_seq, do: Worker.Repo.get_state(:last_applied_seq) || 0

  @doc """
  Issue #123 (Etappe 2): Worker-First-Apply. Wird aus `Worker.Intents.publish/1`
  aufgerufen, bevor der Hub den Event sieht. Erwartet einen event_id im
  `event`-Map, aber keinen seq. Schreibt event_id in `applied_event_ids` und
  führt den apply_kind-Dispatch. Späterer Hub-Broadcast desselben event_id
  wird via `do_apply/1` als bereits-applied erkannt + skipped.
  """
  @spec apply_local(map()) :: :ok
  def apply_local(%{"event_id" => event_id} = event) when is_binary(event_id) do
    GenServer.call(__MODULE__, {:apply_local, event}, @call_timeout)
  end

  # ─── GenServer ────────────────────────────────────────────────────

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:apply, event}, _from, state) do
    {:reply, do_apply(event), state}
  end

  def handle_call({:apply_local, event}, _from, state) do
    {:reply, do_apply_local(event), state}
  end

  def handle_call({:apply_batch, events}, _from, state) do
    last =
      Enum.reduce(events, last_applied_seq(), fn ev, acc ->
        case do_apply(ev) do
          {:applied, seq} -> max(seq, acc)
          :skipped -> acc
        end
      end)

    {:reply, last, state}
  end

  @topic "applied_events"
  def topic, do: @topic

  # ─── Apply ───────────────────────────────────────────────────────

  # Hub-Broadcast mit seq=nil (Issue #152, Etappe 4b+): seit der Hub keine
  # events-Tabelle mehr hat, broadcastet er nur noch event_id. Wenn das
  # Event lokal schon applied wurde (Worker-First-Apply seit Etappe 2), skip.
  # Sonst (z.B. Event von einem anderen Worker): regulär materializeen
  # ohne seq-Cursor-Update (gibt's nicht mehr).
  defp do_apply(%{"seq" => nil, "event_id" => event_id} = event)
       when is_binary(event_id) do
    maybe_create_campaign_store(event)

    {:atomic, result} =
      :mnesia.transaction(fn ->
        cond do
          already_applied_in_tx?(event_id) ->
            :skipped

          true ->
            :mnesia.write({S.applied_event_ids(), event_id, nil})
            apply_payload(event, event_id)
            store_event_in_tx(event, event_id, nil)
            :applied_no_seq
        end
      end)

    maybe_drop_campaign_store(event)

    case result do
      :applied_no_seq -> Phoenix.PubSub.broadcast(Worker.PubSub, @topic, {:applied, event})
      _ -> :ok
    end

    # HubClient erwartet {:applied, seq} | :skipped — seit 4b broadcastet der
    # Hub keine seq mehr, also gibt's nichts zu ack'en. :skipped reicht.
    :skipped
  end

  # Hub-Broadcast mit Integer-seq oder Catch-Up: Event hat seq + (ab Etappe 2)
  # event_id. Pre-Migration-Events haben kein event_id → seq-Cursor-Pfad.
  # Hub-side ab 4c.4 broadcasted seq=nil — diese Klausel ist Catch-Up- und
  # Backwards-Compat-Pfad für Worker die noch alte EventLog-broadcasts sehen.
  defp do_apply(%{"seq" => seq} = event) when is_integer(seq) do
    event_id = event["event_id"]

    # Issue #127 Etappe 3a: Membership-Trigger vor der Tx — ggf. neue
    # Campaign-Event-Tabelle anlegen. Schema-Ops (create_table) gehen
    # nicht innerhalb einer :mnesia.transaction.
    maybe_create_campaign_store(event)

    {:atomic, result} =
      :mnesia.transaction(fn ->
        cond do
          # Pre-Migration-Event (kein event_id) → klassischer seq-Cursor-Pfad
          is_nil(event_id) ->
            apply_with_seq_cursor(event, seq)

          # event_id schon bekannt (Worker-First-Apply hat's gemacht) → seq
          # nachfüllen, sonst skip
          already_applied_in_tx?(event_id) ->
            :mnesia.write({S.applied_event_ids(), event_id, seq})
            store_event_in_tx(event, event_id, seq)
            maybe_bump_cursor_in_tx(seq)
            :skipped

          # Neuer Event mit event_id, kommt zum ersten Mal vom Hub
          true ->
            :mnesia.write({S.applied_event_ids(), event_id, seq})
            apply_payload(event, event_id)
            store_event_in_tx(event, event_id, seq)
            maybe_bump_cursor_in_tx(seq)
            {:applied, seq}
        end
      end)

    # Post-Tx Membership-Drop (Schema-Op kann nicht in Tx)
    maybe_drop_campaign_store(event)

    case result do
      {:applied, _} -> Phoenix.PubSub.broadcast(Worker.PubSub, @topic, {:applied, event})
      _ -> :ok
    end

    result
  end

  # Worker-First-Apply: kein seq, nur event_id. last_applied_seq bleibt
  # unverändert (der Cursor wird erst beim Hub-Broadcast nachgezogen).
  defp do_apply_local(%{"event_id" => event_id} = event) do
    maybe_create_campaign_store(event)

    {:atomic, result} =
      :mnesia.transaction(fn ->
        cond do
          already_applied_in_tx?(event_id) ->
            :skipped

          true ->
            :mnesia.write({S.applied_event_ids(), event_id, nil})
            apply_payload(event, event_id)
            store_event_in_tx(event, event_id, nil)
            :applied_local
        end
      end)

    maybe_drop_campaign_store(event)

    case result do
      :applied_local -> Phoenix.PubSub.broadcast(Worker.PubSub, @topic, {:applied, event})
      _ -> :ok
    end

    :ok
  end

  # Pre-Migration-Pfad — heutiges Verhalten, exakt unverändert (außer
  # store_event_in_tx als zusätzlicher Side-Effect für Etappe 3a; Events ohne
  # event_id landen einfach mit `nil` als Key — Etappe 3a hat noch keinen
  # Use-Case dafür, das wird mit Etappe 3c relevant).
  defp apply_with_seq_cursor(event, seq) do
    cursor = current_cursor_in_tx()

    cond do
      seq <= cursor ->
        :skipped

      true ->
        if seq > cursor + 1 do
          Logger.warning(
            "Materializer: gap detected (cursor=#{cursor}, incoming=#{seq}). Applying anyway."
          )
        end

        apply_payload(event, nil)
        # Pre-Migration-Events haben kein event_id — Store-Write übersprungen.
        :mnesia.write({S.worker_state(), :last_applied_seq, seq})
        {:applied, seq}
    end
  end

  # ─── Etappe 3a: Event-Store-Routing ──────────────────────────────

  # Schreibt den Event in die richtige Store-Tabelle:
  # - campaign_id im Payload + Worker hält den Campaign-Store → per-Campaign-Tabelle
  # - sonst → worker_events_global
  # Aufruf innerhalb der Materializer-Tx.
  defp store_event_in_tx(event, event_id, hub_seq) do
    payload = event["payload"] || %{}
    ts = parse_ts(event["ts"]) || DateTime.utc_now()

    case payload["campaign_id"] do
      cid when is_binary(cid) ->
        if Worker.Schema.DynamicTables.exists?(cid) do
          Worker.Schema.DynamicTables.write_in_tx(cid, event_id, hub_seq, payload, ts)
        else
          # Kein Campaign-Store (Worker ist kein Member) — Event wird nicht
          # in den per-Campaign-Speicher gespiegelt. Materializer hat aber
          # die Domain-Tabellen schon befüllt; das ist heutiges Verhalten.
          :ok
        end

      _ ->
        # Campaign-loser Event (UserRoleSet, ProbelaufStarted, etc.)
        :ok = :mnesia.write({S.events_global(), event_id, hub_seq, payload, ts})
        :ok
    end
  end

  # Falls der Event eine Campaign etabliert (durch uns ODER durch jemand
  # anderen, dessen Event auf diesem Worker materialisiert wurde): passende
  # Campaign-Event-Tabelle anlegen + Hub abonnieren (Etappe 3b — der Hub
  # filtert event_appended-Broadcasts nach Subscription). Issue #215: vor
  # diesem Fix wurde nur abonniert wenn admin_discord_id == owner — Single-
  # Worker-Setups, in denen ein Hub-User ohne eigenen Worker eine Campaign
  # auf einem fremden Worker erstellt, hatten die Campaign zwar im lokalen
  # Mnesia, aber keine Hub-Subscription → InviteCreated/MemberAdded/...
  # routeten zu :no_worker_online und failten silent. Jetzt subscriben wir
  # für jede CampaignCreated/InviteRedeemed/AdminMemberAdded die wir
  # apply'n, unabhängig vom Owner. Beides ausserhalb der Tx.
  defp maybe_create_campaign_store(event) do
    payload = event["payload"] || %{}

    cid =
      case {payload["kind"], payload} do
        {"CampaignCreated", %{"id" => c}} when is_binary(c) -> c
        {"InviteRedeemed", %{"campaign_id" => c}} when is_binary(c) -> c
        {"AdminMemberAdded", %{"campaign_id" => c}} when is_binary(c) -> c
        _ -> nil
      end

    if cid do
      Worker.Schema.DynamicTables.ensure_campaign_store!(cid)
      Worker.HubClient.subscribe_campaign(cid)
    end

    :ok
  end

  # Falls der Event eine Membership entfernt oder die ganze Campaign löscht:
  # Campaign-Event-Tabelle droppen + Hub-Subscription abbestellen.
  defp maybe_drop_campaign_store(event) do
    payload = event["payload"] || %{}
    me = Worker.Repo.get_state(:admin_discord_id)

    cid =
      case {payload["kind"], payload} do
        {"MemberRemoved", %{"campaign_id" => c, "discord_id" => ^me}}
        when is_binary(c) and not is_nil(me) ->
          c

        {"CampaignDeleted", %{"campaign_id" => c}} when is_binary(c) ->
          c

        _ ->
          nil
      end

    if cid do
      Worker.Schema.DynamicTables.drop_campaign_store!(cid)
      Worker.HubClient.unsubscribe_campaign(cid)
    end

    :ok
  end

  defp already_applied_in_tx?(event_id) do
    case :mnesia.read(S.applied_event_ids(), event_id) do
      [] -> false
      _ -> true
    end
  end

  defp maybe_bump_cursor_in_tx(seq) do
    cursor = current_cursor_in_tx()
    if seq > cursor, do: :mnesia.write({S.worker_state(), :last_applied_seq, seq})
    :ok
  end

  defp current_cursor_in_tx do
    case :mnesia.read(S.worker_state(), :last_applied_seq) do
      [{_, _, n}] when is_integer(n) -> n
      _ -> 0
    end
  end

  defp apply_payload(%{"payload" => %{"kind" => kind} = payload, "ts" => ts} = event, event_id) do
    meta = %{
      seq: event["seq"],
      event_id: event_id,
      author_worker_id: event["author_worker_id"]
    }

    apply_kind(kind, payload, parse_ts(ts), meta)
  end

  defp apply_payload(other, _event_id) do
    Logger.warning("Materializer: unrecognized event shape #{inspect(other)}")
    :ok
  end

  # ─── Per-kind dispatch (Issue #582: God-Module-Split) ─────────────
  # Die ~40 apply_kind/4-Klauseln liegen jetzt in Worker.Materializer.Apply1
  # + .Apply2 (beide via import an die geteilten Decode-/Write-Helfer hier).
  # Router: Apply1 zuerst; dessen Sentinel `:__unhandled__` → Apply2, das auch
  # den Unknown-Kind-Catch-all (#471) hält. Läuft im selben Tx-Kontext.
  defp apply_kind(kind, payload, ts, meta) do
    # Issue #894 (I7-Bucket-D-Rest): zentrales Lösch-Tombstone-Gate — single
    # choke point für live + pull + worker-first + seq-cursor. Sitzt im
    # Kontrollfluss NACH applied_event_ids-Write + store_event_in_tx → gated
    # Events bleiben als applied markiert, gespeichert und weiter-repliziert
    # (Relay-Kette intakt); nur der Fold entfällt.
    if deletion_gated?(kind, payload, meta) do
      Logger.debug("Materializer: fold gated by deletion tombstone kind=#{kind}")
      :ok
    else
      case Worker.Materializer.Apply1.apply_kind(kind, payload, ts, meta) do
        :__unhandled__ -> Worker.Materializer.Apply2.apply_kind(kind, payload, ts, meta)
        result -> result
      end
    end
  end

  # ─── Geteilte Decode-/Write-Helfer (Issue #582: @doc false-public, von
  # Apply1/Apply2 via import genutzt) ───────────────────────────────

  # Issue #865 (Cascade-Split): Single-Source der Flavor-/Vorgabe-Slot-Listen —
  # Apply1 validiert Writes dagegen, Cascade räumt die fold_meta-Keys damit auf.
  @doc false
  def flavor_slots, do: ~w(base summary epos chronik)

  @doc false
  def vorgabe_stages, do: ~w(summary epos chronik)

  def delete_by_campaign(table, campaign_id) do
    :mnesia.index_read(table, campaign_id, :campaign_id)
    |> Enum.each(fn row ->
      # PK ist immer im 2. Tupel-Slot (Mnesia-Konvention für unsere Tabellen);
      # für campaign_members ist es der composite key cm_key.
      :mnesia.delete({table, elem(row, 1)})
    end)
  end

  # ─── Issue #766 (I7-Bucket-C): generische fold_meta-Sidecar-Guards ──

  @doc """
  LWW-Guard über die generische `fold_meta`-Sidecar. `fold` ist i.d.R. das
  Event-Kind (snake_case), außer wenn mehrere Event-Kinds um dasselbe Feld
  derselben Row konkurrieren (dann geteilter Fold-Name, z.B. `:invite_status`
  für InviteRevoked+InviteRedeemed) oder ein Event-Kind mehrere unabhängige
  Feld-Gruppen schreibt (dann pro Feld-Gruppe ein eigener Fold-Name, z.B.
  `:utterance_edited_text`/`:utterance_edited_ts`) — Voll-Snapshot-Invariante
  pro Fold ist Voraussetzung für Konvergenz, siehe PR-Beschreibung #816.
  """
  @spec fold_supersedes?(atom(), term(), atom(), String.t() | nil) :: boolean()
  def fold_supersedes?(table, row_key, fold, event_id) do
    key = {table, row_key, fold}

    existing =
      case :mnesia.read(S.fold_meta(), key) do
        [{_, ^key, existing_event_id}] -> existing_event_id
        [] -> nil
      end

    result = event_id_supersedes?(event_id, existing)

    # Diagnose-Log — verworfene Folds sind sonst unsichtbar; genau die Klasse,
    # die #698 erst spät auffiel (22 Chronik-Zombies).
    unless result do
      Logger.debug(
        "Materializer: fold rejected table=#{inspect(table)} row=#{inspect(row_key)} " <>
          "fold=#{fold} incoming=#{inspect(event_id)} winner=#{inspect(existing)}"
      )
    end

    result
  end

  @doc "Trägt `event_id` als neuen Fold-Winner in die `fold_meta`-Sidecar ein."
  @spec record_fold_winner!(atom(), term(), atom(), String.t() | nil) :: :ok
  def record_fold_winner!(table, row_key, fold, event_id) do
    :mnesia.write({S.fold_meta(), {table, row_key, fold}, event_id})
    :ok
  end

  # ─── Issue #894 (I7-Bucket-D-Rest): Lösch-Tombstones ────────────────

  # Die Kinds, die selbst Tombstones schreiben — ihre Folds MÜSSEN laufen
  # (Re-Apply ist idempotent, weil write_deletion_tombstone! max-only ist).
  @gate_exempt_kinds ~w(CampaignDeleted SessionDeleted)

  @doc "Liest den Tombstone-Watermark (max event_id) für einen Scope. Aufruf in Tx."
  @spec deletion_tombstone(term()) :: String.t() | nil
  def deletion_tombstone(scope) do
    case :mnesia.read(S.deletion_tombstones(), scope) do
      [{_, ^scope, event_id}] -> event_id
      [] -> nil
    end
  end

  @doc """
  Hebt den Tombstone-Watermark eines Scopes auf `max(existing, event_id)`. Nie
  ein Delete (monoton). `nil`-event_id (Legacy-Delete ohne event_id) kann nicht
  schützen → No-op. Aufruf in Tx.
  """
  @spec write_deletion_tombstone!(term(), String.t() | nil) :: :ok
  def write_deletion_tombstone!(_scope, nil) do
    Logger.debug("Materializer: deletion tombstone ohne event_id — kein Schutz möglich")
    :ok
  end

  def write_deletion_tombstone!(scope, event_id) do
    if event_id_supersedes?(event_id, deletion_tombstone(scope)) do
      :mnesia.write({S.deletion_tombstones(), scope, event_id})
    end

    :ok
  end

  # Gate: soll dieser Fold wegen eines Lösch-Tombstones übersprungen werden?
  # Watermark-Semantik: gated gdw. ein Tombstone existiert UND das eintreffende
  # Event ihn NICHT übertrifft (Pre-Delete-Event → weg; Rebirth-Event mit
  # größerer event_id → passiert). `nil`-event_id bei vorhandenem Tombstone →
  # gated (fail-closed für schlüssellose Legacy-Events).
  defp deletion_gated?(kind, _payload, _meta) when kind in @gate_exempt_kinds, do: false

  defp deletion_gated?(_kind, payload, %{event_id: event_id}) do
    Enum.any?(deletion_scopes(payload), fn scope ->
      case deletion_tombstone(scope) do
        nil -> false
        tomb -> not event_id_supersedes?(event_id, tomb)
      end
    end)
  end

  # Extrahiert die Lösch-Scopes eines Payloads. Meist explizite
  # `campaign_id`/`session_id`-Keys; die wenigen Kinds mit `"id"` als Scope-Key
  # sind kuratiert gelistet (verifiziert gegen Apply1/Apply2): CampaignCreated/
  # CampaignUpdated → campaign, SessionScheduled/SessionStarted/SessionEnded →
  # session. Ein Payload kann beide Scopes tragen (session-scoped Events führen
  # meist auch campaign_id) → dann gaten beide.
  @campaign_id_via_id_kinds ~w(CampaignCreated CampaignUpdated)
  @session_id_via_id_kinds ~w(SessionScheduled SessionStarted SessionEnded)

  defp deletion_scopes(payload) do
    kind = payload["kind"]

    campaign =
      case payload do
        %{"campaign_id" => c} when is_binary(c) ->
          [{:campaign, c}]

        %{"id" => c} when is_binary(c) ->
          if kind in @campaign_id_via_id_kinds, do: [{:campaign, c}], else: []

        _ ->
          []
      end

    session =
      case payload do
        %{"session_id" => s} when is_binary(s) ->
          [{:session, s}]

        %{"id" => s} when is_binary(s) ->
          if kind in @session_id_via_id_kinds, do: [{:session, s}], else: []

        _ ->
          []
      end

    campaign ++ session
  end

  # Issue #698/#781 (I7): generischer LWW-Guard über einen UUIDv7-Ordnungs-
  # schlüssel (event_id). Höherer Schlüssel gewinnt (UUIDv7 ist lexikografisch
  # = chronologisch sortierbar). existing nil → immer schreiben (neue Row /
  # Pre-Migration). incoming nil bei vorhandenem existing → NICHT clobbern
  # (schlüsselloses Alt-Event darf eine reguläre Row nicht überschreiben).
  # beide nil → schreiben (degradiert zu ungeguardetem Last-Write-Wins für
  # reine Legacy-Event-Ströme ohne event_id — bewusst, siehe #816).
  #
  # Issue #766: hier hoch gezogen (war private Kopie in apply2.ex) — jetzt
  # von `fold_supersedes?/4` UND von ChronikEntryChanged (apply2.ex, bewusst
  # nicht auf die fold_meta-Sidecar migriert, siehe #816) gemeinsam genutzt,
  # statt zweimal denselben 3-Zeiler zu pflegen.
  @doc false
  @spec event_id_supersedes?(String.t() | nil, String.t() | nil) :: boolean()
  def event_id_supersedes?(_new, nil), do: true
  def event_id_supersedes?(nil, _existing), do: false
  def event_id_supersedes?(new, existing), do: new > existing

  def vorgabe_clean(s) when is_binary(s) do
    case String.trim(s) do
      "" -> nil
      t -> t
    end
  end

  def vorgabe_clean(_), do: nil

  def parse_recording_state("recording"), do: :recording
  def parse_recording_state("idle"), do: :idle
  def parse_recording_state("processing"), do: :processing
  def parse_recording_state("completed"), do: :completed
  def parse_recording_state("scheduled"), do: :scheduled

  def parse_recording_state(other) do
    Logger.warning("RecordingStateChanged: unknown state=#{inspect(other)} — fallback :scheduled")
    :scheduled
  end

  def parse_utterance_status("confirmed"), do: :confirmed
  def parse_utterance_status("live"), do: :live
  def parse_utterance_status("edited"), do: :edited
  def parse_utterance_status("deleted"), do: :deleted
  def parse_utterance_status(nil), do: :confirmed

  def parse_utterance_status(other) do
    Logger.warning("UtteranceAppended: unknown status=#{inspect(other)} — fallback :confirmed")
    :confirmed
  end

  def parse_cap(nil), do: nil
  def parse_cap(n) when is_number(n), do: n * 1.0
  def parse_cap(_), do: nil

  def parse_marker_kind("plot"), do: :plot
  def parse_marker_kind("notable"), do: :notable
  def parse_marker_kind("funny"), do: :funny
  def parse_marker_kind(nil), do: :plot

  def parse_marker_kind(other) do
    Logger.warning("MarkerAdded: unknown marker_kind=#{inspect(other)} — fallback :plot")
    :plot
  end

  def parse_summary_source("llm"), do: :llm
  def parse_summary_source("manual"), do: :manual
  def parse_summary_source("goldstandard"), do: :goldstandard
  def parse_summary_source("imported"), do: :imported
  def parse_summary_source(nil), do: :llm

  def parse_summary_source(other) do
    Logger.warning("SessionSummary: unknown source=#{inspect(other)} — fallback :llm")
    :llm
  end

  def lww_accept_summary?(session_id, incoming_ts) do
    case :mnesia.read(S.session_summaries(), session_id) do
      [{_, _, _, _, existing_ts, _, _refs, _flagged, _render_backend, _render_model}] ->
        datetime_lt?(existing_ts, incoming_ts)

      [] ->
        true
    end
  end

  # Issue #114: bei manuellem Epos-Edit ohne source_refs im Payload behalten
  # wir die bisherigen refs (kein Drift). Bei fehlendem Eintrag default [].
  def existing_epos_source_refs(entry_id) do
    case :mnesia.read(S.epos_entries(), entry_id) do
      [{_, _, _, _, _, _, refs, _backend, _model}] when is_list(refs) -> refs
      _ -> []
    end
  end

  # #783 Phase 2 (Nachtrag, Design E): epos_backend/epos_model trailing an
  # epos_entries — analog `existing_epos_source_refs/1`. Bei manuellem Edit
  # (kein LLM-Output im Payload) bleibt die Provenance des letzten LLM-Renders
  # erhalten statt auf nil zurückzufallen.
  def existing_epos_provenance(entry_id) do
    case :mnesia.read(S.epos_entries(), entry_id) do
      [{_, _, _, _, _, _, _refs, backend, model}] -> {backend, model}
      _ -> {nil, nil}
    end
  end

  # true wenn a < b (also incoming-Event ist neuer als existing — write OK).
  # Nil-existing → write OK; nil-incoming → ablehnen (defensiv).
  def datetime_lt?(nil, _), do: true
  def datetime_lt?(_, nil), do: false

  def datetime_lt?(%DateTime{} = a, %DateTime{} = b),
    do: DateTime.compare(a, b) == :lt

  def parse_epos_source("manual"), do: :manual
  def parse_epos_source("llm"), do: :llm
  def parse_epos_source("goldstandard"), do: :goldstandard
  def parse_epos_source(nil), do: :manual

  def parse_epos_source(other) do
    Logger.warning("EposVersion: unknown source=#{inspect(other)} — fallback :manual")
    :manual
  end

  def parse_ts(nil), do: nil
  def parse_ts(%DateTime{} = dt), do: dt

  def parse_ts(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  # Issue #824 (Bucket C2, Epic #766): Session-Status ist eine monotone
  # Zustandsmaschine, kein reines LWW-Feld — ein `:completed` darf nie von
  # einem nachgezogenen `:recording`/`:scheduled` überschrieben werden,
  # unabhängig von Ankunftsreihenfolge oder Timestamp (Bucket C reicht hier
  # nicht: zwei chronologisch geordnete Events können durch Reordering
  # trotzdem einen niedrigeren Rang zuletzt schreiben). Rang statt Zeit.
  # `:idle`/`:recording` sind gleichrangig — `:idle` hat aktuell keinen
  # Live-Producer, ihre relative Ordnung zueinander ist nicht beobachtbar,
  # nur die Ordnung zu :scheduled/:processing/:completed zählt.
  @session_status_rank %{scheduled: 0, idle: 1, recording: 1, processing: 2, completed: 3}

  @doc false
  @spec status_supersedes?(atom(), atom()) :: boolean()
  def status_supersedes?(new_status, existing_status) do
    Map.fetch!(@session_status_rank, new_status) >=
      Map.fetch!(@session_status_rank, existing_status)
  end

  @doc false
  def update_session_status(id, new_status, fun) do
    case :mnesia.read(S.sessions(), id) do
      [{_, _id, _cid, _num, _name, current_status, _sched, _started, _ended} = row] ->
        if status_supersedes?(new_status, current_status) do
          :ok = :mnesia.write(fun.(row))
        else
          Logger.debug(
            "Materializer: session status rejected id=#{id} incoming=#{new_status} " <>
              "current=#{current_status}"
          )
        end

      [] ->
        Logger.warning("Session update for unknown id=#{id}")
    end
  end

  # Issue #824: Consent-Version ist ebenfalls eine monotone Zustandsmaschine
  # (Max-Lattice) — eine ältere Consent-Version darf eine bereits erteilte
  # neuere nie überschreiben, unabhängig von Ankunftsreihenfolge. Bei
  # Gleichstand (erneute Zustimmung zur selben Version) gewinnt der spätere
  # accepted_at (Bucket-B-LWW, nur für diesen Randfall).
  @doc false
  @spec version_rank(String.t()) :: non_neg_integer()
  def version_rank("v" <> n) do
    case Integer.parse(n) do
      {num, ""} -> num
      _ -> 0
    end
  end

  def version_rank(_), do: 0

  @doc false
  def consent_version_supersedes?(discord_id, new_version, new_accepted_at) do
    case :mnesia.read(S.audio_consents(), discord_id) do
      [{_, _, existing_version, existing_accepted_at}] ->
        new_rank = version_rank(new_version)
        existing_rank = version_rank(existing_version)

        cond do
          new_rank > existing_rank -> true
          new_rank < existing_rank -> false
          true -> datetime_lt?(existing_accepted_at, new_accepted_at)
        end

      [] ->
        true
    end
  end

  def normalize_alias(nil), do: nil

  def normalize_alias(name) when is_binary(name) do
    trimmed = String.trim(name)
    if trimmed == "", do: nil, else: trimmed
  end
end
