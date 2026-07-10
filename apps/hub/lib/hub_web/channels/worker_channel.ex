defmodule HubWeb.WorkerChannel do
  @moduledoc """
  Worker-side of the event-sourcing protocol.

  Topic: `worker:<worker_id>`. The channel pid is what `Hub.WorkerRegistry`
  tracks; it also subscribes to the local PubSub `"events"` topic and
  forwards each new event to its worker.

  Incoming frames (worker → hub):
  - `publish_intent`   → PubSub-broadcast via `Hub.Events.broadcast/3`,
    reply `{:ok, seq: nil}` (Worker ignoriert seq seit Etappe 4a)
  - `catch_up_request` → No-Op-Stub (Backwards-Compat mit Workern < 0.15.0)
  - `ack_applied`      → bump `applied_seq` in the Registry

  Outgoing pushes (hub → worker):
  - `event_appended`   → broadcast of fresh events
  - `catch_up_batch`   → response to a catch_up_request
  """

  use Phoenix.Channel

  alias Hub.{Events, Reader, WorkerRegistry}

  require Logger

  # Issue #702: Obergrenze pro publish_intent_batch-Frame. Der Worker chunkt
  # auf 25 — 100 ist die harte Abwehr gegen degenerierte/malformte Frames.
  @max_batch_size 100

  @impl true
  def join("worker:" <> worker_id, payload, socket) do
    if worker_id != socket.assigns.worker_id do
      {:error, %{reason: "worker_id_mismatch"}}
    else
      {:ok, _} = WorkerRegistry.track(worker_id, socket.assigns.admin_discord_id)
      :ok = Phoenix.PubSub.subscribe(Hub.PubSub, Events.topic())

      # Issue #160 (Etappe 5a): Telemetrie über record_join war bisher DB-
      # Write in worker_tokens. Mit JWT-Auth ist worker_tokens weg — Version/
      # SHA-Diagnose loggen wir einfach, ist eh nur Visibility.
      Logger.info(
        "Worker channel joined: worker_id=#{worker_id} version=#{inspect(payload["worker_version"])} sha=#{inspect(payload["worker_sha"])} protocol=#{inspect(payload["protocol_version"])}"
      )

      send(self(), :after_join)
      # Issue #154 (Etappe 4c.4): kein events-Tabelle mehr → kein head. Wire-
      # Compat: nil-head, der Worker.HubClient loggt das diagnostisch
      # (sync läuft eh über pull_since seit 4a).
      #
      # Issue #492: Hub-SHA/Version im Join-Reply, damit der Worker.Updater
      # einen Versions-Drift erkennen und sich self-updaten kann. Jeder Hub-
      # Deploy droppt den WS → Slipstream-Reconnect → neuer Join → frische SHA.
      # Alte Worker ignorieren die Extra-Keys (wire-kompatibel).
      hv = Hub.Version.current()

      # Issue #702: caps-Liste im Join-Reply (Muster hub_sha/#492) — der Worker
      # sendet publish_intent_batch NUR, wenn der Hub den Cap announced. Ein
      # unbekanntes handle_in-Frame würde den Channel-Prozess crashen, daher
      # ist Capability-Signaling statt Try-and-Error Pflicht. Alte Worker
      # ignorieren den Extra-Key (wire-kompatibel).
      {:ok, %{head: nil, hub_sha: hv.sha, hub_vsn: hv.vsn, caps: ["publish_intent_batch"]},
       assign(socket, :pending_reads, %{})}
    end
  end

  @impl true
  def handle_info(:after_join, socket) do
    # No proactive push at join time; the Worker explicitly sends a
    # catch_up_request once it has read its last_applied_seq from Mnesia.
    {:noreply, socket}
  end

  def handle_info({:event_appended, event}, socket) do
    # Issue #129 (Etappe 3b): nur Worker mit Subscription auf die Campaign
    # bekommen den Push. Events ohne campaign_id sind Global-Events
    # (UserRoleSet, ProbelaufStarted etc.) und gehen an alle.
    if should_route_event?(event, socket) do
      push(socket, "event_appended", event_to_wire(event))
    end

    {:noreply, socket}
  end

  def handle_info({:events_batch, events}, socket) do
    # Issue #702: gebatchte Broadcasts werden Richtung Worker bewusst wieder
    # AUFGEFÄCHERT (N einzelne event_appended-Pushes) — ein neues Hub→Worker-
    # Frame würde von alten Workern still gedroppt (HubClient loggt "unhandled
    # message" und verwirft → Datenlücke bis zum nächsten pull_since). Worker
    # sind wenige + Websocket; der OOM-Treiber war die LV-/Longpoll-Seite.
    subscribed = subscribed_campaigns(socket)

    for event <- events, routable_event?(event, subscribed) do
      push(socket, "event_appended", event_to_wire(event))
    end

    {:noreply, socket}
  end

  def handle_info({:snapshot_request, scope, request_id, _reply_to}, socket) do
    push(socket, "snapshot_request", %{request_id: request_id, scope: scope})
    pending = Map.put(socket.assigns.pending_reads, request_id, true)
    {:noreply, assign(socket, :pending_reads, pending)}
  end

  # Issue #313: Prompt-Vorschau-Anfrage an den Worker weiterreichen.
  def handle_info(
        {:preview_request, campaign_id, stage, overrides, request_id, _reply_to},
        socket
      ) do
    push(socket, "preview_request", %{
      request_id: request_id,
      campaign_id: campaign_id,
      stage: stage,
      overrides: overrides
    })

    {:noreply, socket}
  end

  def handle_info(:shutdown_worker, socket) do
    push(socket, "shutdown_worker", %{})
    {:noreply, socket}
  end

  def handle_info({:update_settings, kv}, socket) do
    push(socket, "update_settings", %{settings: kv})
    {:noreply, socket}
  end

  def handle_info({:start_recording, discord_id, campaign_id, mode}, socket) do
    push(socket, "start_recording", %{
      discord_id: discord_id,
      campaign_id: campaign_id,
      mode: to_string(mode)
    })

    {:noreply, socket}
  end

  def handle_info({:stop_recording, campaign_id}, socket) do
    push(socket, "stop_recording", %{campaign_id: campaign_id})
    {:noreply, socket}
  end

  def handle_info({:start_probelauf, discord_id}, socket) do
    push(socket, "start_probelauf", %{discord_id: discord_id})
    {:noreply, socket}
  end

  # Issue #292: GpuQueue-Job-Verwaltung (move_up/move_down/cancel) vom Admin-LV.
  def handle_info({:gpu_job_action, action, job_id}, socket) do
    push(socket, "gpu_job_action", %{action: action, job_id: job_id})
    {:noreply, socket}
  end

  # Seit #786 Wahrheitsbild-nativ: der Sweep variiert immer den Extraktor-/
  # Render-Slot (model_stage2_<backend>) — keine Stage-Wahl mehr.
  def handle_info({:start_probelauf_sweep, discord_id, models, session_set}, socket) do
    push(socket, "start_probelauf_sweep", %{
      discord_id: discord_id,
      models: models,
      session_set: session_set
    })

    {:noreply, socket}
  end

  def handle_info({:start_campaign_replay, discord_id, campaign_id}, socket) do
    push(socket, "start_campaign_replay", %{discord_id: discord_id, campaign_id: campaign_id})
    {:noreply, socket}
  end

  # Issue #131: Gossip-Pull-Verkehr.
  def handle_info({:pull_request, cid, last_event_id, requester}, socket) do
    push(socket, "pull_request", %{
      campaign_id: cid,
      last_event_id: last_event_id,
      requesting_worker_id: requester
    })

    {:noreply, socket}
  end

  def handle_info({:pull_batch, cid, events}, socket) do
    push(socket, "pull_batch", %{campaign_id: cid, events: events})
    {:noreply, socket}
  end

  # Issue #141: Global-Events-Pull.
  def handle_info({:pull_request_global, last_event_id, requester}, socket) do
    push(socket, "pull_request_global", %{
      last_event_id: last_event_id,
      requesting_worker_id: requester
    })

    {:noreply, socket}
  end

  def handle_info({:pull_batch_global, events}, socket) do
    push(socket, "pull_batch_global", %{events: events})
    {:noreply, socket}
  end

  # Issue #154 (Etappe 4c.1): Bridge-Publish. Hub-Side-Producer rufen
  # `Hub.EventBridge.publish/1`, das picked diesen Worker und pusht ein
  # `bridge_publish`-Frame mit dem Event-Payload. Der Worker erzeugt das
  # Event via `Worker.Intents.publish/1` (Worker-First-Apply + sync
  # zurück über publish_intent → PubSub-Broadcast). Hub-LV sieht das
  # Event danach über die normale event_appended-Schiene.
  def handle_info({:bridge_publish, payload}, socket) do
    push(socket, "bridge_publish", %{payload: payload})
    {:noreply, socket}
  end

  def handle_info({:start_session_regenerate, discord_id, campaign_id, session_id}, socket) do
    push(socket, "start_session_regenerate", %{
      discord_id: discord_id,
      campaign_id: campaign_id,
      session_id: session_id
    })

    {:noreply, socket}
  end

  # Issue #392: graceful Mic-Stop → Worker entfernt den Streamer sofort.
  def handle_info({:mic_leave, session_id, discord_id}, socket) do
    push(socket, "mic_leave", %{session_id: session_id, discord_id: discord_id})
    {:noreply, socket}
  end

  # Issue #400: Mic-Setup-Phrase-Clip an den Worker zum Transkribieren.
  # discord_id reist mit, damit der Worker sie in die Response zurückspiegelt
  # und der Hub die Antwort aufs richtige "mic_clip:<did>"-Topic routen kann.
  def handle_info({:transcribe_clip, request_id, discord_id, chunk}, socket) do
    push(socket, "transcribe_clip_request", %{
      request_id: request_id,
      discord_id: discord_id,
      chunk: chunk
    })

    {:noreply, socket}
  end

  def handle_info({:audio_chunk, session_id, sender_discord_id, mic_mode, chunk_b64}, socket) do
    # Issue #642: `mic_mode` (per_player|multi) als additives Map-Feld an den
    # Worker. Map-Push-Wire ist symmetrisch abwärtskompatibel — ein alter Worker
    # ignoriert das Extra-Feld, ein neuer Worker defaultet bei fehlendem auf
    # :per_player. `nil` weglassen (kein Wire-Müll für den per-Spieler-Default).
    base = %{session_id: session_id, discord_id: sender_discord_id, chunk: chunk_b64}
    payload = if mic_mode, do: Map.put(base, :mic_mode, mic_mode), else: base
    push(socket, "audio_chunk", payload)

    {:noreply, socket}
  end

  # Issue #430: Helfer aus dem handle_info/2-Klausel-Block ausgelagert (waren
  # dazwischen → „clauses should be grouped together").
  defp should_route_event?(event, socket),
    do: routable_event?(event, subscribed_campaigns(socket))

  # Issue #702: Set-Variante, damit der Batch-Pfad den Registry-Scan
  # (subscribed_campaigns/1) nur EINMAL pro Batch macht statt pro Event.
  defp routable_event?(event, %MapSet{} = subscribed) do
    case event[:payload]["campaign_id"] do
      nil -> true
      cid when is_binary(cid) -> MapSet.member?(subscribed, cid)
      _ -> true
    end
  end

  defp subscribed_campaigns(socket) do
    case WorkerRegistry.list()
         |> Enum.find(fn {wid, _meta} -> wid == socket.assigns.worker_id end) do
      {_id, %{subscribed_campaigns: subs}} when not is_nil(subs) -> subs
      _ -> MapSet.new()
    end
  end

  # Issue #152 (Etappe 4b): catch_up_request ist No-Op-Stub. Worker.HubClient
  # ab worker 0.15.0 schickt das Frame nicht mehr — der Sync läuft komplett
  # über pull_since (Etappe 3c) + pull_since_global (Etappe 4a). Stub bleibt
  # für Backwards-Compat mit älteren Workern: leeres catch_up_batch, damit der
  # alte Worker ohne Crash weiterläuft (sync füllt sich dann via pull_since,
  # das auch in den alten Workern aktiv ist). Entfernen kommt mit Etappe 4c.
  @impl true
  def handle_in("catch_up_request", %{"from" => from_seq}, socket)
      when is_integer(from_seq) and from_seq >= 0 do
    push(socket, "catch_up_batch", %{events: [], head_seq: 0})
    {:noreply, socket}
  end

  def handle_in("publish_intent", %{"payload" => payload} = msg, socket) do
    # Issue #152 (Etappe 4b): kein EventLog.append mehr — der Worker hat das
    # Event seit Etappe 2 (Issue #123) lokal materialisiert; andere Worker
    # holen es seit Etappe 3c (Issue #131) via pull_since aus dem per-Campaign-
    # Store des Erzeugers. Hub broadcastet nur noch via PubSub, vergibt keine
    # seq mehr. Reply enthält seq=nil — Worker.HubClient ignoriert das seit 4a.
    #
    # Issue #473: Trust-Boundary in zwei Schichten.
    # Cut 1 — Shape/kind: nur Maps mit bekanntem Shared.Events-kind.
    # Cut 2 — Membership: ein campaign-scopedes Event (payload["campaign_id"])
    #   wird nur gebroadcastet, wenn die Campaign im subscribed_campaigns-Set
    #   DIESES Workers ist (spiegelt should_route_event?/2, die OUTGOING-Seite).
    #   Sonst könnte ein authentifizierter aber fehlerhafter/kompromittierter
    #   Worker Events für FREMDE Campaigns in alle LVs/Worker broadcasten.
    #   Genesis-sicher: CampaignCreated nutzt payload["id"] (kein "campaign_id")
    #   → fällt in den nil-Zweig → erlaubt. Per-Campaign-Mutationen kommen von
    #   subscribed Workern (EventBridge pickt subscribed; Worker-eigene Events =
    #   eigene Campaigns). Falsch-Verwerfen ist über pull_since recoverbar
    #   (kein Datenverlust) — deshalb hart verwerfen + laut loggen.
    cond do
      not valid_intent_payload?(payload) ->
        Logger.warning(
          "WorkerChannel: publish_intent von worker_id=#{socket.assigns.worker_id} verworfen — " <>
            "ungültiger Payload (kind=#{inspect(intent_kind(payload))}, nicht in Shared.Events oder keine Map). " <>
            "NICHT gebroadcastet."
        )

        {:reply, {:error, %{reason: "invalid_intent"}}, socket}

      not authorized_campaign?(payload, subscribed_campaigns(socket)) ->
        Logger.warning(
          "WorkerChannel: publish_intent von worker_id=#{socket.assigns.worker_id} verworfen — " <>
            "kind=#{inspect(intent_kind(payload))} für campaign_id=#{inspect(payload["campaign_id"])} " <>
            "NICHT in subscribed_campaigns dieses Workers (Trust-Boundary #473). NICHT gebroadcastet."
        )

        {:reply, {:error, %{reason: "campaign_not_subscribed"}}, socket}

      true ->
        event_id = msg["event_id"]
        :ok = Events.broadcast(event_id, payload, socket.assigns.worker_id)
        {:reply, {:ok, %{seq: nil}}, socket}
    end
  end

  def handle_in("publish_intent_batch", %{"events" => events}, socket)
      when is_list(events) do
    # Issue #702: gebatchte Variante von publish_intent für den Transkriptions-
    # Backlog nach Session-Ende. Ein Batch → EINE PubSub-Message
    # ({:events_batch, …} via Events.broadcast_batch/2) → ein LV-Diff pro
    # Subscriber statt N. Trust-Boundary (#473, Shape + Membership) gilt pro
    # Event; ungültige Events werden verworfen + aggregiert geloggt, die
    # gültigen trotzdem gebroadcastet (Falsch-Verwerfen ist über pull_since
    # recoverbar, kein Datenverlust).
    if length(events) > @max_batch_size do
      Logger.warning(
        "WorkerChannel: publish_intent_batch von worker_id=#{socket.assigns.worker_id} " <>
          "verworfen — #{length(events)} Events > max #{@max_batch_size}. NICHT gebroadcastet."
      )

      {:reply, {:error, %{reason: "batch_too_large"}}, socket}
    else
      {accepted, rejected} = split_valid_intents(events, subscribed_campaigns(socket))

      if rejected != [] do
        sample =
          rejected
          |> Enum.take(5)
          |> Enum.map(fn ev ->
            payload = if is_map(ev), do: ev["payload"], else: nil
            {intent_kind(payload), is_map(payload) && payload["campaign_id"]}
          end)

        Logger.warning(
          "WorkerChannel: publish_intent_batch von worker_id=#{socket.assigns.worker_id} — " <>
            "#{length(rejected)}/#{length(events)} Events verworfen (ungültiger Payload oder " <>
            "campaign nicht subscribed, Trust-Boundary #473). NICHT gebroadcastet. " <>
            "Sample (kind, campaign_id): #{inspect(sample)}"
        )
      end

      :ok =
        accepted
        |> Enum.map(&%{event_id: &1["event_id"], payload: &1["payload"]})
        |> Events.broadcast_batch(socket.assigns.worker_id)

      {:reply, {:ok, %{seq: nil, accepted: length(accepted), rejected: length(rejected)}}, socket}
    end
  end

  def handle_in("ack_applied", %{"seq" => seq}, socket) when is_integer(seq) do
    {:ok, _} = WorkerRegistry.update_applied_seq(socket.assigns.worker_id, seq)
    {:noreply, socket}
  end

  def handle_in("snapshot_response", %{"request_id" => rid, "payload" => payload}, socket) do
    Reader.handle_response(rid, payload)
    {:noreply, assign(socket, :pending_reads, Map.delete(socket.assigns.pending_reads, rid))}
  end

  # Issue #313: Prompt-Vorschau-Segmente vom Worker an den wartenden LV routen.
  def handle_in("preview_response", %{"request_id" => rid, "segments" => segments}, socket) do
    Hub.PromptPreview.handle_response(rid, segments)
    {:noreply, socket}
  end

  # Issue #400: transkribierter Mic-Setup-Clip → an die wartende CampaignLive
  # des anfragenden Users routen (korreliert über request_id).
  def handle_in(
        "transcribe_clip_response",
        %{"request_id" => rid, "text" => text, "discord_id" => did},
        socket
      ) do
    Phoenix.PubSub.broadcast(Hub.PubSub, "mic_clip:#{did}", {:clip_transcribed, rid, text})
    {:noreply, socket}
  end

  def handle_in("publish_status", %{"payload" => payload}, socket) do
    Phoenix.PubSub.broadcast(Hub.PubSub, "pipeline_status", {:pipeline_status, payload})
    {:noreply, socket}
  end

  # Issue #129 (Etappe 3b): Worker meldet welche Campaigns er abonniert hat
  # (Member-Status). Hub filtert event_appended-Broadcasts darauf — nur
  # subscribed Worker bekommen den Push.
  def handle_in("subscribe_campaigns", %{"campaign_ids" => ids}, socket) when is_list(ids) do
    log_registry_result(
      WorkerRegistry.subscribe(socket.assigns.worker_id, ids),
      :subscribe,
      socket
    )

    {:noreply, socket}
  end

  def handle_in("unsubscribe_campaigns", %{"campaign_ids" => ids}, socket) when is_list(ids) do
    log_registry_result(
      WorkerRegistry.unsubscribe(socket.assigns.worker_id, ids),
      :unsubscribe,
      socket
    )

    {:noreply, socket}
  end

  # Issue #50: Worker meldet seine Liste lokal installierter Ollama-Modelle.
  # Hub aggregiert über alle Worker eines Admins für das Multi-Worker-Union-
  # Badge in der Modell-Combobox in /settings.
  def handle_in("report_models", %{"models" => names}, socket) when is_list(names) do
    log_registry_result(
      WorkerRegistry.report_models(socket.assigns.worker_id, names),
      :report_models,
      socket
    )

    {:noreply, socket}
  end

  # Issue #468 Cut 2: Worker meldet dass er eine Audio-Session in seinem
  # AudioBuffer geöffnet hat. Pick_leader-Stickiness im Audio-Hot-Path
  # bevorzugt diesen Worker für den Rest des Streams, auch wenn ein
  # lexikografisch kleinerer Member-Worker mid-Stream connected wird.
  def handle_in("session_held", %{"session_id" => sid}, socket) when is_binary(sid) do
    log_registry_result(
      WorkerRegistry.add_held_session(socket.assigns.worker_id, sid),
      :add_held_session,
      socket
    )

    {:noreply, socket}
  end

  def handle_in("session_released", %{"session_id" => sid}, socket) when is_binary(sid) do
    log_registry_result(
      WorkerRegistry.remove_held_session(socket.assigns.worker_id, sid),
      :remove_held_session,
      socket
    )

    {:noreply, socket}
  end

  # Issue #772: der verwerfende Worker (Chunk für eine Session ohne offenen Sink
  # — audio_buffer.ex Unknown-Session-Zweig) meldet den Wrong-Worker-Drop. An die
  # MicLive des betroffenen Senders routen (per-User-Topic), die daraus ihren
  # gefensterten Drop-Detektor speist. `discord_id` = Sender, dessen Audio
  # verworfen wurde (nicht der aufnehmende Worker).
  def handle_in("audio_nack", %{"session_id" => sid, "discord_id" => did}, socket)
      when is_binary(sid) and is_binary(did) do
    Phoenix.PubSub.broadcast(Hub.PubSub, HubWeb.MicLive.mic_topic(did), {:audio_nack, sid})
    {:noreply, socket}
  end

  # Issue #131 (Etappe 3c): Gossip-Pull. Worker fragt nach Events die er
  # noch nicht hat. Hub picked pro Campaign einen anderen Worker mit
  # Subscription auf diese Campaign (höchster applied_seq), sendet ihm
  # ein pull_request — die pull_response wird dann als pull_batch an den
  # Anfrager geforwarded.
  def handle_in("pull_since", %{"cursors" => cursors}, socket) when is_list(cursors) do
    requester = socket.assigns.worker_id

    Enum.each(cursors, fn %{"campaign_id" => cid} = c ->
      route_pull_request(cid, c["last_event_id"], requester)
    end)

    {:noreply, socket}
  end

  def handle_in(
        "pull_response",
        %{
          "campaign_id" => cid,
          "requesting_worker_id" => requester,
          "events" => events
        },
        socket
      ) do
    case find_channel_pid(requester) do
      nil ->
        Logger.warning(
          "WorkerChannel: pull_response for campaign=#{cid} cannot reach requester=#{requester} (disconnected)"
        )

      pid ->
        send(pid, {:pull_batch, cid, events})
    end

    {:noreply, socket}
  end

  # Issue #141 (Etappe 4a): Global-Events-Pull. Worker fragt nach campaign-
  # losen Events. Hub picked beliebigen anderen Worker (höchster applied_seq),
  # sendet pull_request_global.
  def handle_in("pull_since_global", %{"last_event_id" => last_event_id}, socket) do
    requester = socket.assigns.worker_id

    case pick_global_pull_source(requester) do
      nil ->
        Logger.debug(fn ->
          "WorkerChannel: pull_since_global — kein anderer Worker online, skipping"
        end)

        :ok

      pid ->
        send(pid, {:pull_request_global, last_event_id, requester})
    end

    {:noreply, socket}
  end

  def handle_in(
        "pull_response_global",
        %{"requesting_worker_id" => requester, "events" => events},
        socket
      ) do
    case find_channel_pid(requester) do
      nil ->
        Logger.warning(
          "WorkerChannel: pull_response_global cannot reach requester=#{requester} (disconnected)"
        )

      pid ->
        send(pid, {:pull_batch_global, events})
    end

    {:noreply, socket}
  end

  # Issue #473: ein publish_intent-Payload ist nur dann broadcast-würdig, wenn
  # er eine Map mit einem bekannten Event-`kind` (Shared.Events.all/0, seit #471
  # die kanonische Liste) ist. Schützt die Trust-Boundary: ein buggy/fehl-
  # deployter Worker kann keine unbekannten/malformten Events in die LV-/Worker-
  # Schicht broadcasten. (Membership-Scoping pro Campaign = möglicher Folge-Cut.)
  # Public @doc false für den Unit-Test (es gibt keine Channel-Test-Harness im Hub).
  @doc false
  def valid_intent_payload?(payload) do
    is_map(payload) and intent_kind(payload) in Shared.Events.all()
  end

  defp intent_kind(payload) when is_map(payload), do: Map.get(payload, "kind")
  defp intent_kind(_), do: nil

  # Issue #473 Cut 2: ein campaign-scopedes Event darf nur gebroadcastet werden,
  # wenn die Campaign im `subscribed`-Set des Absender-Workers ist. Events ohne
  # `campaign_id` (Global-Events wie UserUpserted, oder Genesis wie
  # CampaignCreated mit payload["id"]) sind erlaubt. Spiegelt should_route_event?/2.
  # `subscribed` wird als Arg übergeben (statt aus dem socket gelesen) → pur +
  # unit-testbar ohne WorkerRegistry. Public @doc false für den Test.
  @doc false
  def authorized_campaign?(payload, %MapSet{} = subscribed) when is_map(payload) do
    case Map.get(payload, "campaign_id") do
      cid when is_binary(cid) -> MapSet.member?(subscribed, cid)
      _ -> true
    end
  end

  def authorized_campaign?(_payload, _subscribed), do: true

  # Issue #702: partitioniert einen publish_intent_batch in {accepted, rejected}
  # entlang derselben Trust-Boundary wie publish_intent (Shape/kind via
  # valid_intent_payload?/1 + Membership via authorized_campaign?/2). Pur —
  # `subscribed` kommt als Arg rein. Public @doc false für den Unit-Test
  # (keine Channel-Test-Harness im Hub, Muster valid_intent_payload?/1).
  @doc false
  @spec split_valid_intents([term()], MapSet.t()) :: {[map()], [term()]}
  def split_valid_intents(events, %MapSet{} = subscribed) when is_list(events) do
    Enum.split_with(events, fn ev ->
      payload = is_map(ev) && ev["payload"]
      valid_intent_payload?(payload) and authorized_campaign?(payload, subscribed)
    end)
  end

  defp event_to_wire(%{seq: seq, payload: payload, author_worker_id: author, ts: ts} = ev) do
    %{
      seq: seq,
      event_id: Map.get(ev, :event_id),
      payload: payload,
      author_worker_id: author,
      ts: DateTime.to_iso8601(ts)
    }
  end

  # Issue #131: Routing-Helpers für den Gossip-Pull.
  defp route_pull_request(campaign_id, last_event_id, requester) do
    case pick_pull_source(campaign_id, requester) do
      nil ->
        Logger.debug(fn ->
          "WorkerChannel: pull_since campaign=#{campaign_id} — kein anderer Subscriber online, skipping"
        end)

        :ok

      pid ->
        send(pid, {:pull_request, campaign_id, last_event_id, requester})
    end
  end


  # Pickt aus den Workern die für die Campaign subscribed sind und NICHT der
  # Anfrager sind den mit höchstem applied_seq. nil wenn kein Kandidat.
  defp pick_pull_source(campaign_id, requester_id) do
    WorkerRegistry.list()
    |> Enum.filter(fn {wid, meta} ->
      wid != requester_id and
        MapSet.member?(Map.get(meta, :subscribed_campaigns, MapSet.new()), campaign_id)
    end)
    |> Enum.sort_by(fn {_wid, meta} -> -Map.get(meta, :applied_seq, 0) end)
    |> case do
      [{_wid, %{channel_pid: pid}} | _] -> pid
      [] -> nil
    end
  end

  # Issue #141 (Etappe 4a): Pickt beliebigen anderen Worker für Global-Pull —
  # alle Worker halten worker_events_global, also keine Campaign-Filterung.
  defp pick_global_pull_source(requester_id) do
    WorkerRegistry.list()
    |> Enum.filter(fn {wid, _meta} -> wid != requester_id end)
    |> Enum.sort_by(fn {_wid, meta} -> -Map.get(meta, :applied_seq, 0) end)
    |> case do
      [{_wid, %{channel_pid: pid}} | _] -> pid
      [] -> nil
    end
  end

  defp find_channel_pid(worker_id) do
    WorkerRegistry.list()
    |> Enum.find_value(fn
      {^worker_id, %{channel_pid: pid}} -> pid
      _ -> nil
    end)
  end

  # Issue #589: Registry-Updates (Phoenix.Tracker.update/5) können laut Spec
  # `{:error, reason}` liefern — z.B. `:nonexistent_topic`, wenn die Worker-
  # Presence (transient) nicht getrackt ist. Vorher hart `{:ok, _} =` gematcht:
  # ein Error hätte den ganzen Worker-Channel mit MatchError gecrasht. Jetzt
  # geloggt statt gecrasht — der Worker reconnectet ohnehin und re-trackt.
  #
  # Dialyzer-Caveat: das Success-Typing von `Tracker.update/5` ist (asymmetrisch
  # zu `track/4`) auf `{:error,_}` verengt — ein bekannter Dep-FP. Zur Laufzeit
  # liefert `update/5` `{:ok, ref}`, weil `join/3` den Worker bereits getrackt hat
  # (gleiche pid/topic/key, Zeile 31). Der `{:ok,_ref}`-Zweig hier wird daher von
  # Dialyzer als unerreichbar geflaggt — bewusst via `.dialyzer_ignore.exs`
  # whitelisted (siehe Eintrag dort). Code bleibt laufzeit-korrekt + robust.
  defp log_registry_result({:ok, _ref}, _op, _socket), do: :ok

  defp log_registry_result({:error, reason}, op, socket) do
    Logger.warning(
      "WorkerRegistry.#{op} failed for worker=#{socket.assigns.worker_id}: #{inspect(reason)}"
    )
  end
end
