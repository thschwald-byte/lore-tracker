defmodule Worker.HubClient.Events do
  @moduledoc """
  Issue #585: Events-Topic-Bündel aus `Worker.HubClient`.

  Behandelt die Event-Replication-Klauseln, die der Hub auf dem `worker:<id>`-
  Channel pusht:

  - `event_appended` — neuer kanonischer Event vom Hub → Materializer.apply_event/1, ack
  - `pull_request` / `pull_request_global` — anderer Worker fragt nach Events (Issue #131/#141)
  - `pull_batch` / `pull_batch_global` — Antwort eines anderen Workers auf unseren pull_since
  - `catch_up_batch` — Hub schickt nach Join verpasste Events; nach erfolgreichem Apply
    läuft `maybe_bootstrap_admin/0` (Issue #34, Auto-Admin auf frischer Instance)

  Frame-Bau läuft über `Worker.HubClient.{ack/2, push_event/3}` — siehe Channel-Helpers
  in HubClient.
  """

  require Logger

  alias Worker.HubClient
  alias Worker.Materializer
  alias Worker.Schema.DynamicTables
  alias Worker.SyncWatermark

  def on_event_appended(payload, socket) do
    case Materializer.apply_event(payload) do
      {:applied, seq} -> HubClient.ack(socket, seq)
      :skipped -> :ok
    end

    {:ok, socket}
  end

  # Issue #131 (Etappe 3c): Hub fragt uns nach Events einer Campaign seit
  # `last_event_id`. Wir lesen aus dem lokalen per-Campaign-Store, schicken
  # pull_response zurück mit dem Anfrager-worker_id (Hub forwarded an ihn).
  def on_pull_request(
        %{
          "campaign_id" => cid,
          "last_event_id" => last_event_id,
          "requesting_worker_id" => requester
        },
        socket
      ) do
    events =
      cid
      |> DynamicTables.events_since(last_event_id)
      |> Enum.map(&to_wire_event/1)

    push_chunked_response(
      socket,
      "pull_response",
      %{campaign_id: cid, requesting_worker_id: requester},
      events,
      "pull_request campaign=#{cid} since=#{inspect(last_event_id)} to worker=#{requester}"
    )

    {:ok, socket}
  end

  # Hub forwarded Events von einem anderen Worker zu uns — durch Materializer
  # schicken, Idempotenz auf event_id verhindert Doppel-Apply. Issue #693:
  # danach Wasserlinie vorschieben + nächsten Pull schicken (Loop-bis-leer).
  def on_pull_batch(%{"campaign_id" => cid, "events" => events}, socket) do
    if events != [] do
      Logger.info("HubClient: pull_batch campaign=#{cid} → #{length(events)} events")
    end

    apply_batch_local(events)
    continue_sync(socket, cid, events)

    {:ok, socket}
  end

  # Issue #141 (Etappe 4a): Global-Events-Pull. Hub fragt uns nach campaign-
  # losen Events im worker_events_global ab last_event_id.
  def on_pull_request_global(
        %{"last_event_id" => last_event_id, "requesting_worker_id" => requester},
        socket
      ) do
    events =
      last_event_id
      |> DynamicTables.global_events_since()
      |> Enum.map(&to_wire_event/1)

    push_chunked_response(
      socket,
      "pull_response_global",
      %{requesting_worker_id: requester},
      events,
      "pull_request_global since=#{inspect(last_event_id)} to worker=#{requester}"
    )

    {:ok, socket}
  end

  def on_pull_batch_global(%{"events" => events}, socket) do
    if events != [] do
      Logger.info("HubClient: pull_batch_global → #{length(events)} events")
    end

    apply_batch_local(events)
    continue_sync(socket, SyncWatermark.global_scope(), events)

    {:ok, socket}
  end

  defp apply_batch_local(events) do
    Enum.each(events, fn ev ->
      Materializer.apply_local(%{
        "event_id" => ev["event_id"],
        "payload" => ev["payload"],
        "ts" => ev["ts"],
        "author_worker_id" => nil
      })
    end)
  end

  # Issue #693: Pull-Loop-Schritt. Nicht-leerer Batch → Wasserlinie auf das
  # Batch-Ende vorschieben (PERSISTIEREN, dann erst weiterpullen — Crash
  # zwischen den beiden Schritten kostet nur einen Dupe-Pull, nie Daten) und
  # den nächsten Pull ab der neuen Wasserlinie schicken. Leerer Batch →
  # aufgeholt, Loop endet; der periodische :sync_tick prüft wieder. Der Sender
  # antwortet seit #693 mit genau EINEM Chunk pro Request (1:1 Pacing durch
  # den Cloud-Proxy) — dieser Loop holt so schrittweise die ganze Historie.
  defp continue_sync(socket, scope, events) do
    case SyncWatermark.sync_step(events) do
      {:advance, last_event_id} ->
        :ok = SyncWatermark.advance(scope, last_event_id)
        push_next_pull(socket, scope)

      :caught_up ->
        :ok
    end
  end

  defp push_next_pull(socket, scope) do
    watermark = SyncWatermark.get(scope)

    if scope == SyncWatermark.global_scope() do
      HubClient.push_event(socket, "pull_since_global", %{last_event_id: watermark})
    else
      HubClient.push_event(socket, "pull_since", %{
        cursors: [%{"campaign_id" => scope, "last_event_id" => watermark}]
      })
    end

    :ok
  end

  # Issue #690: eine Pull-Antwort in Byte-Budget-Chunks teilen statt in EINEM
  # Frame antworten — ein Cold-Start-Sync (z.B. 15134 Events) sprengt sonst die
  # WebSocket-Frame-Grenze des Gigalixir/Google-Cloud-Proxys → 502 → Endlos-
  # Retry, der frische Worker bleibt leer.
  #
  # Issue #693: pro Request wird NUR DER ERSTE Chunk gesendet (Response ≤
  # pull_chunk_max_bytes). Der Empfänger schiebt seine Sync-Wasserlinie auf das
  # Batch-Ende vor und pullt den Rest per Folge-Request (Loop-bis-leer in
  # on_pull_batch*). Ergebnis: 1:1 Request/Response — kein Chunk-Burst durch
  # den Cloud-Proxy, natürliches Pacing, leere Antwort = Anfrager ist
  # aufgeholt. Message-Shapes unverändert (kein Hub-/Wire-Change); eine leere
  # Event-Liste wird weiterhin als genau EIN leerer Batch beantwortet.
  defp push_chunked_response(socket, event_name, base_params, events, log_label) do
    max_bytes = Worker.Settings.get(:pull_chunk_max_bytes, 200_000)

    {chunk, total} =
      case chunk_by_budget(events, max_bytes) do
        [] -> {[], 1}
        [first | _] = cs -> {first, length(cs)}
      end

    if chunk != [] do
      Logger.info(
        "HubClient: #{log_label} → chunk 1/#{total} (#{length(chunk)} events, Rest via Re-Pull)"
      )
    end

    HubClient.push_event(socket, event_name, Map.put(base_params, :events, chunk))

    :ok
  end

  defp to_wire_event({event_id, hub_seq, payload, ts}) do
    %{
      event_id: event_id,
      hub_seq: hub_seq,
      payload: payload,
      ts: DateTime.to_iso8601(ts)
    }
  end

  # Issue #690: teilt eine Event-Liste in Chunks, deren serialisierte Größe je
  # unter `max_bytes` bleibt. Byte-Schätzung via `:erlang.external_size/1` (guter
  # Proxy für die Wire-Größe). Invarianten: Reihenfolge bleibt exakt erhalten;
  # jeder Chunk hat mindestens ein Event (ein einzelnes über-Budget-Event geht
  # allein raus, statt hängenzubleiben); leere Eingabe → []. Public (@doc false)
  # nur für den Unit-Test.
  @doc false
  def chunk_by_budget(events, max_bytes)
      when is_list(events) and is_integer(max_bytes) and max_bytes > 0 do
    {chunks, cur, _cur_size} =
      Enum.reduce(events, {[], [], 0}, fn ev, {chunks, cur, cur_size} ->
        ev_size = :erlang.external_size(ev)

        cond do
          # Erstes Event im aktuellen Chunk — immer aufnehmen (min. 1 pro Chunk).
          cur == [] -> {chunks, [ev], ev_size}
          # Würde das Budget sprengen → aktuellen Chunk abschließen, neuen beginnen.
          cur_size + ev_size > max_bytes -> {[Enum.reverse(cur) | chunks], [ev], ev_size}
          # Passt noch rein.
          true -> {chunks, [ev | cur], cur_size + ev_size}
        end
      end)

    chunks = if cur == [], do: chunks, else: [Enum.reverse(cur) | chunks]
    Enum.reverse(chunks)
  end

  def on_catch_up_batch(%{"events" => events, "head_seq" => head}, socket) do
    Logger.info("HubClient: catch_up_batch (#{length(events)} events, hub head=#{head})")
    last = Materializer.apply_batch(events)

    if last > 0 do
      HubClient.ack(socket, last)
    end

    # Auto-Admin-Bootstrap (Issue #34): wenn nach komplettem Catch-Up
    # KEIN Admin existiert + wir selbst sind als User registriert, machen
    # wir uns zum Admin. Per-Instance einmaliger Bootstrap.
    maybe_bootstrap_admin()

    {:ok, socket}
  end

  defp maybe_bootstrap_admin do
    me = Worker.Repo.get_state(:admin_discord_id)

    cond do
      is_nil(me) ->
        :ok

      Worker.Repo.admin_exists?() ->
        :ok

      true ->
        Logger.info(
          "HubClient: Auto-Admin-Bootstrap — keine Admin auf dieser Instance, promoviere self=#{me}"
        )

        # Publish in eigenem Task — wir sind IM handle_message des HubClient-
        # GenServers, und Intents.publish ist ein GenServer.call AUF diese
        # Instance. Synchron würde das deadlocken.
        # Issue #571: Return matchen — Auto-Admin-Bootstrap ist genau der
        # Silent-Failure-Pfad, der einen Worker headless lassen würde.
        Task.Supervisor.start_child(Worker.TaskSupervisor, fn ->
          {:ok, _} =
            Worker.Intents.publish(%{
              "kind" => Shared.Events.user_role_set(),
              "discord_id" => me,
              "role" => "admin",
              "set_by" => "auto-bootstrap"
            })
        end)

        :ok
    end
  end
end
