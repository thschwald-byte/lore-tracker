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

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec apply_event(map()) :: {:applied, pos_integer()} | :skipped
  def apply_event(event), do: GenServer.call(__MODULE__, {:apply, event})

  @spec apply_batch([map()]) :: non_neg_integer()
  def apply_batch(events) when is_list(events) do
    Enum.reduce(events, last_applied_seq(), fn ev, acc ->
      case apply_event(ev) do
        {:applied, seq} -> max(seq, acc)
        :skipped -> acc
      end
    end)
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
    GenServer.call(__MODULE__, {:apply_local, event})
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

  # ─── Per-kind handlers ───────────────────────────────────────────

  defp apply_kind("CampaignCreated", payload, ts, _meta) do
    id = payload["id"]
    # Issue #140: owner_discord_id bleibt im Wire-Event (Hub kennt den
    # Ersteller), wird aber nicht mehr ins campaigns-Schema geschrieben.
    # Stattdessen legen wir den Ersteller als Auto-Member mit role
    # :spielleiter an — die per-Campaign-Membership ist die einzige
    # Quelle der Wahrheit für „wer ist SL dieser Kampagne".
    creator = payload["owner_discord_id"]

    :ok =
      :mnesia.write({
        S.campaigns(),
        id,
        payload["name"],
        payload["icon_url"],
        payload["theme_blurb"],
        :active,
        ts,
        %{},
        nil
      })

    :ok =
      :mnesia.write({
        S.campaign_members(),
        S.member_key(id, creator),
        id,
        creator,
        :spielleiter,
        ts,
        nil,
        nil
      })

    display_name = payload["owner_display_name"] || creator

    {existing_joined_at, existing_avatar_url, existing_role} =
      case :mnesia.read(S.users(), creator) do
        [{_, _, _, j, a, r}] -> {j, a, r}
        [] -> {ts, nil, :spieler}
      end

    :ok =
      :mnesia.write(
        {S.users(), creator, display_name, existing_joined_at, existing_avatar_url, existing_role}
      )
  end

  defp apply_kind("CampaignUpdated", payload, _ts, _meta) do
    id = payload["id"]

    case :mnesia.read(S.campaigns(), id) do
      [{_, ^id, name, icon, theme, status, created_at, flavors, vocab_hint}] ->
        :ok =
          :mnesia.write({
            S.campaigns(),
            id,
            payload["name"] || name,
            payload["icon_url"] || icon,
            payload["theme_blurb"] || theme,
            payload["status"] || status,
            created_at,
            flavors,
            vocab_hint
          })

      [] ->
        Logger.warning("CampaignUpdated for unknown id=#{id} — ignoring")
    end
  end

  defp apply_kind("CampaignVocabUpdated", payload, _ts, _meta) do
    id = payload["campaign_id"]
    vocab = payload["vocab_hint"]

    case :mnesia.read(S.campaigns(), id) do
      [{_, ^id, name, icon, theme, status, created_at, flavors, _old_hint}] ->
        :ok = :mnesia.write({S.campaigns(), id, name, icon, theme, status, created_at, flavors, vocab})

      [] ->
        Logger.warning("CampaignVocabUpdated for unknown id=#{id} — ignoring")
    end
  end

  defp apply_kind("CampaignDeleted", payload, _ts, _meta) do
    id = payload["campaign_id"]

    case :mnesia.read(S.campaigns(), id) do
      [] ->
        Logger.warning("CampaignDeleted for unknown id=#{id} — ignoring")

      [_] ->
        # Sessions zuerst — wir brauchen ihre IDs für utterances + markers.
        session_ids =
          S.sessions()
          |> :mnesia.index_read(id, :campaign_id)
          |> Enum.map(&elem(&1, 1))

        Enum.each(session_ids, fn sid ->
          :mnesia.index_read(S.utterances(), sid, :session_id)
          |> Enum.each(fn row -> :mnesia.delete({S.utterances(), elem(row, 1)}) end)

          :mnesia.index_read(S.markers(), sid, :session_id)
          |> Enum.each(fn row -> :mnesia.delete({S.markers(), elem(row, 1)}) end)

          :mnesia.delete({S.sessions(), sid})
        end)

        # Campaign-scoped tables.
        delete_by_campaign(S.campaign_members(), id)
        delete_by_campaign(S.campaign_invites(), id)
        delete_by_campaign(S.session_summaries(), id)
        delete_by_campaign(S.session_faithfulness_scores(), id)
        delete_by_campaign(S.chronik_entries(), id)
        delete_by_campaign(S.epos_entries(), id)

        # Epos-Historie ist nach entry_id indiziert (entry_id == campaign_id
        # für die single-entry-pro-campaign-Welt).
        :mnesia.index_read(S.epos_history(), id, :entry_id)
        |> Enum.each(fn row -> :mnesia.delete({S.epos_history(), elem(row, 1)}) end)

        :mnesia.delete({S.campaigns(), id})

        Logger.info(
          "CampaignDeleted id=#{id} — cascade dropped #{length(session_ids)} session(s)"
        )
    end
  end

  defp delete_by_campaign(table, campaign_id) do
    :mnesia.index_read(table, campaign_id, :campaign_id)
    |> Enum.each(fn row ->
      # PK ist immer im 2. Tupel-Slot (Mnesia-Konvention für unsere Tabellen);
      # für campaign_members ist es der composite key cm_key.
      :mnesia.delete({table, elem(row, 1)})
    end)
  end

  @flavor_slots ~w(base summary epos chronik)

  defp apply_kind("CampaignFlavorSet", payload, _ts, _meta) do
    id = payload["campaign_id"]
    slot = payload["slot"] || "base"
    raw = payload["flavor"]

    cond do
      slot not in @flavor_slots ->
        Logger.warning("CampaignFlavorSet: unknown slot=#{inspect(slot)} for id=#{id} — dropping")

      true ->
        case :mnesia.read(S.campaigns(), id) do
          [{_, ^id, name, icon, theme, status, created_at, old_flavors, vocab_hint}] ->
            existing =
              case old_flavors do
                m when is_map(m) -> m
                s when is_binary(s) and s != "" -> %{"base" => s}
                _ -> %{}
              end

            cleaned =
              case raw do
                nil -> nil
                s when is_binary(s) -> if String.trim(s) == "", do: nil, else: s
                _ -> nil
              end

            new_flavors =
              if is_nil(cleaned),
                do: Map.delete(existing, slot),
                else: Map.put(existing, slot, cleaned)

            :ok =
              :mnesia.write({
                S.campaigns(),
                id,
                name,
                icon,
                theme,
                status,
                created_at,
                new_flavors,
                vocab_hint
              })

          [] ->
            Logger.warning("CampaignFlavorSet for unknown id=#{id} — ignoring")
        end
    end
  end

  defp apply_kind("SessionScheduled", payload, _ts, _meta) do
    :ok =
      :mnesia.write({
        S.sessions(),
        payload["id"],
        payload["campaign_id"],
        payload["number"],
        payload["name"],
        :scheduled,
        parse_ts(payload["scheduled_for"]),
        nil,
        nil
      })
  end

  defp apply_kind("SessionStarted", payload, ts, _meta) do
    update_session(payload["id"], fn {_, id, cid, num, name, _status, sched, _started, ended} ->
      {S.sessions(), id, cid, num, name, :recording, sched, ts, ended}
    end)
  end

  defp apply_kind("SessionEnded", payload, ts, _meta) do
    update_session(payload["id"], fn {_, id, cid, num, name, _status, sched, started, _ended} ->
      {S.sessions(), id, cid, num, name, :completed, sched, started, ts}
    end)
  end

  defp apply_kind("RecordingStateChanged", payload, _ts, _meta) do
    new_status = String.to_atom(payload["state"])

    update_session(payload["session_id"], fn {_, id, cid, num, name, _status, sched, started,
                                              ended} ->
      {S.sessions(), id, cid, num, name, new_status, sched, started, ended}
    end)
  end

  defp apply_kind("UtteranceAppended", payload, event_ts, _meta) do
    # Issue #95: utterance-ts darf nie nil sein, sonst crasht `Worker.Repo.list_utterances`
    # in Enum.sort_by mit DateTime.compare(nil, nil). Seed-Events (Schlegel-JSONL)
    # tragen nur das Envelope-`ts`, kein payload `timestamp` — Fallback nötig.
    utt_ts = parse_ts(payload["timestamp"]) || event_ts || DateTime.utc_now()

    :ok =
      :mnesia.write({
        S.utterances(),
        payload["id"],
        payload["session_id"],
        payload["discord_id"],
        utt_ts,
        payload["text"],
        payload["confidence"],
        String.to_atom(payload["status"] || "confirmed"),
        nil
      })
  end

  defp apply_kind("UtteranceEdited", payload, _ts, _meta) do
    id = payload["id"]

    case :mnesia.read(S.utterances(), id) do
      [{tbl, ^id, sid, did, ts, _old_text, conf, _old_status, deleted_at}] ->
        new_text = payload["new_text"] || ""
        :ok = :mnesia.write({tbl, id, sid, did, ts, new_text, conf, :edited, deleted_at})

      [] ->
        Logger.warning("UtteranceEdited for unknown id=#{id} — dropping")
        :ok
    end
  end

  # Issue #133 (Etappe 3d): Tombstone statt :mnesia.delete.
  defp apply_kind("UtteranceDeleted", payload, ts, _meta) do
    id = payload["id"]

    case :mnesia.read(S.utterances(), id) do
      [{tbl, ^id, sid, did, ts_ut, text, conf, status, _old_del}] ->
        :ok = :mnesia.write({tbl, id, sid, did, ts_ut, text, conf, status, ts})

      [] ->
        :ok
    end
  end

  defp apply_kind("LiveUtterancesCleared", payload, _ts, _meta) do
    session_id = payload["session_id"]

    rows = :mnesia.index_read(S.utterances(), session_id, :session_id)

    Enum.each(rows, fn row ->
      {id, status} =
        case row do
          {_, id, _sid, _did, _ts, _text, _conf, status, _del} -> {id, status}
          {_, id, _sid, _did, _ts, _text, _conf, status} -> {id, status}
        end

      if status == :live, do: :mnesia.delete({S.utterances(), id})
    end)

    :ok
  end

  defp apply_kind("UserUpserted", payload, ts, _meta) do
    discord_id = payload["discord_id"]
    display_name = payload["display_name"] || discord_id

    {existing_joined_at, existing_avatar_url, existing_role} =
      case :mnesia.read(S.users(), discord_id) do
        [{_, _, _, j, a, r}] -> {j, a, r}
        [] -> {ts, nil, :spieler}
      end

    # avatar_url in the payload wins (allows refresh); fall back to existing
    # so an older event without the field doesn't blank the avatar.
    avatar_url =
      case Map.fetch(payload, "avatar_url") do
        {:ok, url} -> url
        :error -> existing_avatar_url
      end

    :ok =
      :mnesia.write({
        S.users(),
        discord_id,
        display_name,
        existing_joined_at,
        avatar_url,
        existing_role
      })
  end

  # Issue #64: pro Discord-User wird vermerkt dass das Audio-Consent-Modal
  # akzeptiert wurde. version ("v1") taggt den Wording-Stand — wenn der
  # Inhalt später ändert (v2), kann eine neue Akzeptanz erzwungen werden,
  # indem die LV nur v_current als "consented" durchgehen lässt.
  # Issue #177: Spend-Tracking — pro Cloud-LLM-Call ein Row in `worker_llm_spend`.
  # event_id ist der UUIDv7 aus dem Envelope (Materializer-Outer-Wrap), nicht
  # vom payload — wir greifen via meta.event_id zu, oder generieren einen
  # synthetischen Key wenn das je passieren sollte (sicherheitsnetz).
  defp apply_kind("LLMCallBilled", payload, ts, meta) do
    event_id = Map.get(meta, :event_id) || "synth-#{:erlang.unique_integer([:positive])}"

    :ok =
      :mnesia.write({
        S.llm_spend(),
        event_id,
        ts,
        payload["provider"],
        payload["model"],
        payload["input_tokens"] || 0,
        payload["output_tokens"] || 0,
        payload["cost_usd"] || 0.0,
        payload["requested_by_discord_id"],
        payload["session_id"],
        payload["stage"],
        payload["duration_ms"]
      })
  end

  defp apply_kind("AudioConsentRecorded", payload, ts, _meta) do
    discord_id = payload["discord_id"]
    version = payload["version"] || "v1"

    accepted_at =
      case payload["accepted_at"] do
        nil -> ts
        s when is_binary(s) ->
          case DateTime.from_iso8601(s) do
            {:ok, dt, _} -> dt
            _ -> ts
          end
        %DateTime{} = dt -> dt
      end

    :ok =
      :mnesia.write({
        S.audio_consents(),
        discord_id,
        version,
        accepted_at
      })
  end

  defp apply_kind("AdminMemberAdded", payload, ts, _meta) do
    campaign_id = payload["campaign_id"]
    discord_id = payload["discord_id"]
    display_name = payload["display_name"] || discord_id

    case :mnesia.read(S.campaigns(), campaign_id) do
      [] ->
        Logger.warning("AdminMemberAdded for unknown campaign=#{campaign_id} — ignoring")

      [_] ->
        # User-Row anlegen wenn nicht vorhanden (preserves existing role).
        {existing_joined_at, existing_avatar_url, existing_role} =
          case :mnesia.read(S.users(), discord_id) do
            [{_, _, _, j, a, r}] -> {j, a, r}
            [] -> {ts, nil, :spieler}
          end

        :ok =
          :mnesia.write({
            S.users(),
            discord_id,
            display_name,
            existing_joined_at,
            existing_avatar_url,
            existing_role
          })

        # Member-Row anlegen (idempotent — gleicher composite key überschreibt).
        # character_name bleibt erhalten falls schon Mitglied. deleted_at wird
        # explizit auf nil gesetzt (Re-Join nach Remove ist möglich).
        existing_character_name =
          case :mnesia.read(S.campaign_members(), S.member_key(campaign_id, discord_id)) do
            [{_, _, _, _, _, _, name, _deleted_at}] -> name
            [{_, _, _, _, _, _, name}] -> name
            _ -> nil
          end

        :ok =
          :mnesia.write({
            S.campaign_members(),
            S.member_key(campaign_id, discord_id),
            campaign_id,
            discord_id,
            :spieler,
            ts,
            existing_character_name,
            nil
          })
    end
  end

  @valid_roles ~w(admin spielleiter spieler)

  defp apply_kind("UserRoleSet", payload, ts, _meta) do
    discord_id = payload["discord_id"]
    role_str = payload["role"]

    cond do
      role_str not in @valid_roles ->
        Logger.warning(
          "UserRoleSet: unknown role=#{inspect(role_str)} for discord_id=#{discord_id} — dropping"
        )

      true ->
        role = String.to_atom(role_str)

        {display_name, joined_at, avatar_url} =
          case :mnesia.read(S.users(), discord_id) do
            [{_, _, name, j, a, _}] -> {name, j, a}
            [] -> {discord_id, ts, nil}
          end

        :ok =
          :mnesia.write({S.users(), discord_id, display_name, joined_at, avatar_url, role})
    end
  end

  defp apply_kind("MarkerAdded", payload, _ts, _meta) do
    :ok =
      :mnesia.write({
        S.markers(),
        payload["id"],
        payload["session_id"],
        parse_ts(payload["at_ts"]),
        String.to_atom(payload["marker_kind"] || "plot"),
        payload["label"]
      })
  end

  defp apply_kind("InviteCreated", payload, ts, _meta) do
    :ok =
      :mnesia.write({
        S.campaign_invites(),
        payload["token"],
        payload["campaign_id"],
        payload["created_by_discord_id"],
        ts,
        parse_ts(payload["expires_at"]),
        :active,
        nil
      })
  end

  defp apply_kind("InviteRevoked", payload, _ts, _meta) do
    token = payload["token"]

    case :mnesia.read(S.campaign_invites(), token) do
      [{_, ^token, cid, by, created, expires, _status, redeemed_by}] ->
        :ok =
          :mnesia.write({
            S.campaign_invites(),
            token,
            cid,
            by,
            created,
            expires,
            :revoked,
            redeemed_by
          })

      [] ->
        Logger.warning("InviteRevoked for unknown token=#{token}")
    end
  end

  defp apply_kind("InviteRedeemed", payload, ts, _meta) do
    token = payload["token"]
    discord_id = payload["discord_id"]
    display_name = payload["display_name"] || "User #{discord_id}"

    case :mnesia.read(S.campaign_invites(), token) do
      [{_, ^token, campaign_id, created_by, created_at, expires_at, _status, _redeemed_by}] ->
        # Mark invite redeemed.
        :ok =
          :mnesia.write({
            S.campaign_invites(),
            token,
            campaign_id,
            created_by,
            created_at,
            expires_at,
            :redeemed,
            discord_id
          })

        # Upsert user (preserve joined_at + avatar_url if already known).
        {existing_joined_at, existing_avatar_url, existing_role} =
          case :mnesia.read(S.users(), discord_id) do
            [{_, _, _, j, a, r}] -> {j, a, r}
            [] -> {ts, nil, :spieler}
          end

        :ok =
          :mnesia.write({
            S.users(),
            discord_id,
            display_name,
            existing_joined_at,
            existing_avatar_url,
            existing_role
          })

        # Add membership (idempotent — same key overwrites).
        # Preserve any existing character_name if the user is being
        # re-added (e.g. invite re-redeemed); default nil for first-time.
        # Re-Join nach Tombstone: deleted_at wird auf nil zurückgesetzt.
        existing_character_name =
          case :mnesia.read(S.campaign_members(), S.member_key(campaign_id, discord_id)) do
            [{_, _, _, _, _, _, name, _deleted_at}] -> name
            [{_, _, _, _, _, _, name}] -> name
            _ -> nil
          end

        :ok =
          :mnesia.write({
            S.campaign_members(),
            S.member_key(campaign_id, discord_id),
            campaign_id,
            discord_id,
            :spieler,
            ts,
            existing_character_name,
            nil
          })

      [] ->
        Logger.warning("InviteRedeemed for unknown token=#{token}")
    end
  end

  # Issue #133 (Etappe 3d): Tombstone statt :mnesia.delete. Bei Re-Sync von
  # alten Edit-Events respektiert apply_kind den Tombstone (LWW). Repo-Reads
  # filtern Rows mit deleted_at != nil aus.
  defp apply_kind("MemberRemoved", payload, ts, _meta) do
    key = S.member_key(payload["campaign_id"], payload["discord_id"])

    case :mnesia.read(S.campaign_members(), key) do
      [{tbl, ^key, cid, did, role, joined_at, character_name, _old_deleted_at}] ->
        :ok = :mnesia.write({tbl, key, cid, did, role, joined_at, character_name, ts})

      [] ->
        # Tombstone für Member den wir nicht kannten — Sync-Korrektheit:
        # neuer Worker holt sich beide Events (MemberAdded + MemberRemoved),
        # apply-Reihenfolge: Tombstone wird über schwebenden InviteRedeemed
        # gewinnen. Wir markieren nicht-existierende Row hier nicht — beim
        # Re-Sync wäre MemberRemoved nach InviteRedeemed angekommen.
        :ok
    end
  end

  defp apply_kind("CampaignAliasSet", payload, _ts, _meta) do
    campaign_id = payload["campaign_id"]
    discord_id = payload["discord_id"]
    name = normalize_alias(payload["character_name"])
    key = S.member_key(campaign_id, discord_id)

    case :mnesia.read(S.campaign_members(), key) do
      [{tbl, ^key, ^campaign_id, ^discord_id, role, joined_at, _old_name, deleted_at}] ->
        :ok =
          :mnesia.write({tbl, key, campaign_id, discord_id, role, joined_at, name, deleted_at})

      [] ->
        Logger.warning(
          "CampaignAliasSet for unknown member campaign=#{campaign_id} did=#{discord_id} — dropping"
        )

        :ok
    end
  end

  defp apply_kind("SessionSummaryGenerated", payload, ts, _meta) do
    # Issue #133 (Etappe 3d): LWW pro session_id. Bei Sync mit älteren Events
    # nach lokalem Apply von einer neueren Edition wird der ältere skipped.
    if lww_accept_summary?(payload["session_id"], ts) do
      :ok =
        :mnesia.write({
          S.session_summaries(),
          payload["session_id"],
          payload["campaign_id"],
          payload["content_md"] || "",
          ts,
          String.to_atom(payload["source"] || "llm")
        })
    end

    :ok
  end

  defp apply_kind("SessionSummaryEdited", payload, ts, _meta) do
    case :mnesia.read(S.session_summaries(), payload["session_id"]) do
      [{_, sid, cid, _content, existing_ts, _source}] ->
        if datetime_lt?(existing_ts, ts) do
          :ok =
            :mnesia.write({
              S.session_summaries(),
              sid,
              cid,
              payload["new_md"] || "",
              ts,
              :manual
            })
        end

        :ok

      [] ->
        Logger.warning("SessionSummaryEdited for unknown session=#{payload["session_id"]}")
    end
  end

  defp lww_accept_summary?(session_id, incoming_ts) do
    case :mnesia.read(S.session_summaries(), session_id) do
      [{_, _, _, _, existing_ts, _}] -> datetime_lt?(existing_ts, incoming_ts)
      [] -> true
    end
  end

  # true wenn a < b (also incoming-Event ist neuer als existing — write OK).
  # Nil-existing → write OK; nil-incoming → ablehnen (defensiv).
  defp datetime_lt?(nil, _), do: true
  defp datetime_lt?(_, nil), do: false

  defp datetime_lt?(%DateTime{} = a, %DateTime{} = b),
    do: DateTime.compare(a, b) == :lt

  defp apply_kind("SessionFaithfulnessScored", payload, ts, _meta) do
    :ok =
      :mnesia.write({
        S.session_faithfulness_scores(),
        payload["session_id"],
        payload["campaign_id"],
        payload["score"],
        Jason.encode!(payload["claims"] || []),
        ts
      })
  end

  defp apply_kind("ChronikEntryChanged", payload, _ts, _meta) do
    # Issue #135: in_game_sort_key wird nicht mehr persistiert — Sort am
    # Read-Path. Payload-Feld bleibt akzeptiert (BC für ältere Events) und
    # wird ignoriert.
    :ok =
      :mnesia.write({
        S.chronik_entries(),
        payload["id"],
        payload["campaign_id"],
        payload["in_game_date"],
        payload["label"],
        payload["summary"],
        payload["session_id"]
      })
  end

  # Issue #227: Bulk-Clear aller Chronik-Rows einer (campaign, session)-Paarung.
  # Pipeline emittiert diesen Event vor jedem Stage-4-Publish, damit Re-Runs
  # keine Halluzinationen aus früheren Läufen akkumulieren. Idempotent —
  # Replay löscht erneut, was schon gelöscht ist.
  defp apply_kind("ChronikClearedForSession", payload, _ts, _meta) do
    campaign_id = payload["campaign_id"]
    session_id = payload["session_id"]

    :mnesia.index_read(S.chronik_entries(), campaign_id, :campaign_id)
    |> Enum.each(fn row ->
      # Schema: {table, id, campaign_id, in_game_date, label, summary, session_id}
      if elem(row, 6) == session_id do
        :mnesia.delete({S.chronik_entries(), elem(row, 1)})
      end
    end)
  end

  defp apply_kind("EposEntryEdited", payload, ts, meta) do
    entry_id = payload["entry_id"]
    campaign_id = payload["campaign_id"] || entry_id
    new_md = payload["new_md"] || ""

    # Issue #133 (Etappe 3d): LWW auf updated_at. Bei Sync mit älteren Events
    # nach lokalem Apply einer neueren Edition wird der ältere skipped — die
    # History-Row wird aber weiterhin geschrieben (Audit-Spur bleibt vollständig).
    upsert_current? =
      case :mnesia.read(S.epos_entries(), entry_id) do
        [{_, _, _, _, _, existing_updated_at}] -> datetime_lt?(existing_updated_at, ts)
        [] -> true
      end

    if upsert_current? do
      :ok =
        :mnesia.write({
          S.epos_entries(),
          entry_id,
          campaign_id,
          payload["parent_id"],
          new_md,
          ts
        })
    end

    # Append a history row. History id is derived from event_id (Issue #123)
    # so re-applying the same event is idempotent (overwrites the same row).
    # Worker-First-Apply (seq=nil) und Hub-Broadcast-Reapply matchen über die
    # event_id auf denselben history_id. Pre-Migration-Events ohne event_id
    # fallen auf seq als Fallback zurück.
    history_id =
      case meta do
        %{event_id: id} when is_binary(id) -> "ehist-#{id}"
        %{seq: seq} when is_integer(seq) -> "ehist-#{seq}"
      end

    :ok =
      :mnesia.write({
        S.epos_history(),
        history_id,
        entry_id,
        new_md,
        ts,
        meta.author_worker_id,
        String.to_atom(payload["source"] || "manual"),
        meta.seq
      })
  end

  defp apply_kind("ProbelaufStarted", payload, ts, _meta) do
    :ok =
      :mnesia.write({
        S.probelauf_runs(),
        payload["run_id"],
        ts,
        nil,
        payload["started_by"],
        [],
        payload["settings_snapshot"] || %{},
        payload["sweep_id"],
        payload["sweep_variant"]
      })
  end

  defp apply_kind("ProbelaufFinished", payload, ts, _meta) do
    run_id = payload["run_id"]

    {started_at, sweep_id_existing, sweep_variant_existing} =
      case :mnesia.read(S.probelauf_runs(), run_id) do
        # Post-migration shape (8 attrs + table tag = arity 9)
        [{_, _, started_at, _, _, _, _, sid, svar}] -> {started_at, sid, svar}
        # Pre-migration shape (6 attrs + table tag = arity 7) — defensive fallback
        [{_, _, started_at, _, _, _, _}] -> {started_at, nil, nil}
        _ -> {ts, nil, nil}
      end

    :ok =
      :mnesia.write({
        S.probelauf_runs(),
        run_id,
        started_at,
        ts,
        payload["started_by"],
        payload["sessions"] || [],
        payload["settings_snapshot"] || %{},
        payload["sweep_id"] || sweep_id_existing,
        payload["sweep_variant"] || sweep_variant_existing
      })
  end

  defp apply_kind("ProbelaufSweepStarted", payload, ts, _meta) do
    :ok =
      :mnesia.write({
        S.probelauf_sweeps(),
        payload["sweep_id"],
        ts,
        nil,
        payload["started_by"],
        payload["stage"],
        payload["models"] || [],
        payload["default_model"]
      })
  end

  defp apply_kind("ProbelaufSweepFinished", payload, ts, _meta) do
    sweep_id = payload["sweep_id"]

    case :mnesia.read(S.probelauf_sweeps(), sweep_id) do
      [{_, _, started_at, _, started_by, stage, models, default_model}] ->
        :ok =
          :mnesia.write({
            S.probelauf_sweeps(),
            sweep_id,
            started_at,
            ts,
            started_by,
            stage,
            models,
            default_model
          })

      _ ->
        # SweepFinished without prior SweepStarted — shouldn't happen, but
        # don't crash. Materializer would be stuck on a corrupt eventlog.
        Logger.warning("Materializer: ProbelaufSweepFinished for unknown sweep_id=#{sweep_id}")
        :ok
    end
  end

  # Issue #140 Phase B: Spielleiter befördert / demotet einen Member.
  # `new_role ∈ "spielleiter" | "spieler"`. Idempotent — Re-Apply mit
  # gleichem Wert ist no-op. Tombstone-Schutz: ein per `MemberRemoved`
  # gelöschter Member wird NICHT durch ein nachgelagertes
  # `MemberRolePromoted` „wiederbelebt"; deleted_at bleibt erhalten und
  # die Repo-Reads filtern weiterhin raus.
  defp apply_kind("MemberRolePromoted", payload, _ts, _meta) do
    key = S.member_key(payload["campaign_id"], payload["discord_id"])

    new_role =
      case payload["new_role"] do
        "spielleiter" -> :spielleiter
        "spieler" -> :spieler
        _ -> nil
      end

    cond do
      is_nil(new_role) ->
        Logger.warning(
          "MemberRolePromoted: invalid new_role=#{inspect(payload["new_role"])} for campaign=#{payload["campaign_id"]} did=#{payload["discord_id"]}"
        )

        :ok

      true ->
        case :mnesia.read(S.campaign_members(), key) do
          [{tbl, ^key, cid, did, _role, joined_at, character_name, deleted_at}] ->
            :mnesia.write(
              {tbl, key, cid, did, new_role, joined_at, character_name, deleted_at}
            )

          [] ->
            Logger.warning(
              "MemberRolePromoted for unknown member campaign=#{payload["campaign_id"]} did=#{payload["discord_id"]}"
            )

            :ok
        end
    end
  end

  defp apply_kind(kind, _payload, _ts, _meta) do
    Logger.debug(fn ->
      "Materializer: ignoring unknown kind=#{kind} (handler not implemented yet)"
    end)

    :ok
  end

  defp parse_ts(nil), do: nil
  defp parse_ts(%DateTime{} = dt), do: dt

  defp parse_ts(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp update_session(id, fun) do
    case :mnesia.read(S.sessions(), id) do
      [row] -> :ok = :mnesia.write(fun.(row))
      [] -> Logger.warning("Session update for unknown id=#{id}")
    end
  end

  defp normalize_alias(nil), do: nil

  defp normalize_alias(name) when is_binary(name) do
    trimmed = String.trim(name)
    if trimmed == "", do: nil, else: trimmed
  end
end
