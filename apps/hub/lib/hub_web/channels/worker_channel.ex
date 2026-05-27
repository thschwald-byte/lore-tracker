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
      {:ok, %{head: nil}, assign(socket, :pending_reads, %{})}
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

  defp should_route_event?(event, socket) do
    case event[:payload]["campaign_id"] do
      nil -> true
      cid when is_binary(cid) -> MapSet.member?(subscribed_campaigns(socket), cid)
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

  def handle_info({:snapshot_request, scope, request_id, _reply_to}, socket) do
    push(socket, "snapshot_request", %{request_id: request_id, scope: scope})
    pending = Map.put(socket.assigns.pending_reads, request_id, true)
    {:noreply, assign(socket, :pending_reads, pending)}
  end

  def handle_info(:shutdown_worker, socket) do
    push(socket, "shutdown_worker", %{})
    {:noreply, socket}
  end

  def handle_info({:update_settings, kv}, socket) do
    push(socket, "update_settings", %{settings: kv})
    {:noreply, socket}
  end

  def handle_info({:start_recording, discord_id, campaign_id}, socket) do
    push(socket, "start_recording", %{discord_id: discord_id, campaign_id: campaign_id})
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

  def handle_info({:start_probelauf_sweep, discord_id, stage, models, session_set}, socket) do
    push(socket, "start_probelauf_sweep", %{
      discord_id: discord_id,
      stage: stage,
      models: models,
      session_set: session_set
    })

    {:noreply, socket}
  end

  # Issue #262: Stage-isolierter Sweep gegen Goldstandard-Pre-Seed.
  def handle_info(
        {:start_probelauf_sweep_isolated, discord_id, stage, models, session_set},
        socket
      ) do
    push(socket, "start_probelauf_sweep_isolated", %{
      discord_id: discord_id,
      stage: stage,
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

  def handle_info({:audio_chunk, session_id, sender_discord_id, chunk_b64}, socket) do
    push(socket, "audio_chunk", %{
      session_id: session_id,
      discord_id: sender_discord_id,
      chunk: chunk_b64
    })

    {:noreply, socket}
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
    event_id = msg["event_id"]
    :ok = Events.broadcast(event_id, payload, socket.assigns.worker_id)
    {:reply, {:ok, %{seq: nil}}, socket}
  end

  def handle_in("ack_applied", %{"seq" => seq}, socket) when is_integer(seq) do
    {:ok, _} = WorkerRegistry.update_applied_seq(socket.assigns.worker_id, seq)
    {:noreply, socket}
  end

  def handle_in("snapshot_response", %{"request_id" => rid, "payload" => payload}, socket) do
    Reader.handle_response(rid, payload)
    {:noreply, assign(socket, :pending_reads, Map.delete(socket.assigns.pending_reads, rid))}
  end

  def handle_in("publish_status", %{"payload" => payload}, socket) do
    Phoenix.PubSub.broadcast(Hub.PubSub, "pipeline_status", {:pipeline_status, payload})
    {:noreply, socket}
  end

  # Issue #129 (Etappe 3b): Worker meldet welche Campaigns er abonniert hat
  # (Member-Status). Hub filtert event_appended-Broadcasts darauf — nur
  # subscribed Worker bekommen den Push.
  def handle_in("subscribe_campaigns", %{"campaign_ids" => ids}, socket) when is_list(ids) do
    {:ok, _} = WorkerRegistry.subscribe(socket.assigns.worker_id, ids)
    {:noreply, socket}
  end

  def handle_in("unsubscribe_campaigns", %{"campaign_ids" => ids}, socket) when is_list(ids) do
    {:ok, _} = WorkerRegistry.unsubscribe(socket.assigns.worker_id, ids)
    {:noreply, socket}
  end

  # Issue #50: Worker meldet seine Liste lokal installierter Ollama-Modelle.
  # Hub aggregiert über alle Worker eines Admins für das Multi-Worker-Union-
  # Badge in der Modell-Combobox in /settings.
  def handle_in("report_models", %{"models" => names}, socket) when is_list(names) do
    {:ok, _} = WorkerRegistry.report_models(socket.assigns.worker_id, names)
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
end
