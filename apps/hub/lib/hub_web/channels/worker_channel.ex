defmodule HubWeb.WorkerChannel do
  @moduledoc """
  Worker-side of the event-sourcing protocol.

  Topic: `worker:<worker_id>`. The channel pid is what `Hub.WorkerRegistry`
  tracks; it also subscribes to the local PubSub `"events"` topic and
  forwards each new event to its worker.

  Incoming frames (worker → hub):
  - `publish_intent`   → `Hub.EventLog.append/2`, reply `{:ok, seq}`
  - `catch_up_request` → ship a `catch_up_batch` push back
  - `ack_applied`      → bump `applied_seq` in the Registry

  Outgoing pushes (hub → worker):
  - `event_appended`   → broadcast of fresh events
  - `catch_up_batch`   → response to a catch_up_request
  """

  use Phoenix.Channel

  alias Hub.{EventLog, Reader, WorkerRegistry}

  require Logger

  @impl true
  def join("worker:" <> worker_id, payload, socket) do
    if worker_id != socket.assigns.worker_id do
      {:error, %{reason: "worker_id_mismatch"}}
    else
      {:ok, _} = WorkerRegistry.track(worker_id, socket.assigns.admin_discord_id)
      :ok = Phoenix.PubSub.subscribe(Hub.PubSub, EventLog.topic())
      :ok = Hub.WorkerTokens.record_join(socket.assigns.token, payload)

      Logger.info(
        "Worker channel joined: worker_id=#{worker_id} version=#{inspect(payload["worker_version"])} sha=#{inspect(payload["worker_sha"])}"
      )

      send(self(), :after_join)
      {:ok, %{head: EventLog.head()}, assign(socket, :pending_reads, %{})}
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

  def handle_info({:start_probelauf_sweep, discord_id, stage, models}, socket) do
    push(socket, "start_probelauf_sweep", %{
      discord_id: discord_id,
      stage: stage,
      models: models
    })

    {:noreply, socket}
  end

  def handle_info({:start_campaign_replay, discord_id, campaign_id}, socket) do
    push(socket, "start_campaign_replay", %{discord_id: discord_id, campaign_id: campaign_id})
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

  @impl true
  def handle_in("catch_up_request", %{"from" => from_seq}, socket)
      when is_integer(from_seq) and from_seq >= 0 do
    events = EventLog.stream(from_seq)

    push(socket, "catch_up_batch", %{
      events: Enum.map(events, &event_to_wire/1),
      head_seq: EventLog.head()
    })

    {:noreply, socket}
  end

  def handle_in("publish_intent", %{"payload" => payload} = msg, socket) do
    # Issue #123: Worker schickt event_id top-level mit (Worker-First-Apply).
    # Hub übernimmt die ID unverändert. Pre-Migration-Worker (ohne event_id)
    # bekommen eine vom Hub generiert via EventLog.append/2.
    event_id = msg["event_id"]
    {:ok, seq} = EventLog.append(event_id, payload, socket.assigns.worker_id)
    {:reply, {:ok, %{seq: seq}}, socket}
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

  defp event_to_wire(%{seq: seq, payload: payload, author_worker_id: author, ts: ts} = ev) do
    %{
      seq: seq,
      event_id: Map.get(ev, :event_id),
      payload: payload,
      author_worker_id: author,
      ts: DateTime.to_iso8601(ts)
    }
  end
end
