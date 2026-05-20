defmodule Worker.HubClient do
  @moduledoc """
  Persistent WebSocket connection from this Worker to the Hub, joining
  `worker:<worker_id>`. On connect we send a `catch_up_request` from the
  Materializer's last_applied_seq; thereafter every `event_appended`
  push goes through the Materializer and we ack the seq back.

  Auth: `worker_id` + `hub_token` from `worker_state` end up as query params
  on the WS URL; `HubWeb.WorkerSocket.connect/3` validates them.

  Slipstream's built-in reconnect handles transient hub outages.
  """

  use Slipstream, restart: :permanent

  require Logger

  alias Worker.{Materializer, Repo}

  # ─── Lifecycle ────────────────────────────────────────────────────

  def start_link(opts) do
    Slipstream.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Publish an event payload through the channel. Synchronous — blocks until
  the hub assigns a seq and replies, or returns `{:error, :not_connected}`
  if the socket is down.
  """
  @spec publish(map(), timeout()) :: {:ok, pos_integer()} | {:error, term()}
  def publish(payload, timeout \\ 5_000) when is_map(payload) do
    GenServer.call(__MODULE__, {:publish_intent, payload}, timeout)
  catch
    :exit, reason -> {:error, reason}
  end

  @doc """
  Publish a transient status update (not an event, not replicated, no seq).
  The hub broadcasts it on the `"pipeline_status"` PubSub topic so LiveViews
  can react (e.g. show LLM-busy indicators). Fire-and-forget.
  """
  @spec publish_status(map()) :: :ok
  def publish_status(payload) when is_map(payload) do
    send(__MODULE__, {:publish_status, payload})
    :ok
  end

  @impl Slipstream
  def init(_opts) do
    config = config()

    case connect(config) do
      {:ok, socket} ->
        {:ok, assign(socket, :worker_id, Repo.get_state(:worker_id))}

      {:error, reason} ->
        Logger.error("HubClient: initial connect failed: #{inspect(reason)}")
        # Slipstream will auto-reconnect; just return a disconnected socket.
        {:ok, new_socket() |> assign(:worker_id, Repo.get_state(:worker_id))}
    end
  end

  # ─── Slipstream callbacks ─────────────────────────────────────────

  @impl Slipstream
  def handle_connect(socket) do
    Logger.info("HubClient: WebSocket up, joining worker:#{socket.assigns.worker_id}")
    {:ok, join(socket, topic(socket))}
  end

  @impl Slipstream
  def handle_join(_topic, %{"head" => head}, socket) do
    from = Materializer.last_applied_seq()

    Logger.info(
      "HubClient: channel joined (hub head=#{head}, local last_applied_seq=#{from}); requesting catch-up"
    )

    push(socket, topic(socket), "catch_up_request", %{from: from})
    {:ok, socket}
  end

  def handle_join(_topic, join_response, socket) do
    Logger.info("HubClient: channel joined (no head): #{inspect(join_response)}")
    push(socket, topic(socket), "catch_up_request", %{from: Materializer.last_applied_seq()})
    {:ok, socket}
  end

  @impl Slipstream
  def handle_message(_topic, "event_appended", payload, socket) do
    case Materializer.apply_event(payload) do
      {:applied, seq} -> ack(socket, seq)
      :skipped -> :ok
    end

    {:ok, socket}
  end

  def handle_message(_topic, "catch_up_batch", %{"events" => events, "head_seq" => head}, socket) do
    Logger.info("HubClient: catch_up_batch (#{length(events)} events, hub head=#{head})")
    last = Materializer.apply_batch(events)

    if last > 0 do
      ack(socket, last)
    end

    {:ok, socket}
  end

  def handle_message(_topic, "snapshot_request", %{"request_id" => rid, "scope" => scope}, socket) do
    payload = Worker.Repo.snapshot(scope)
    push(socket, topic(socket), "snapshot_response", %{request_id: rid, payload: payload})
    {:ok, socket}
  end

  def handle_message(_topic, "shutdown_worker", _payload, socket) do
    Worker.Lifecycle.shutdown()
    {:ok, socket}
  end

  def handle_message(_topic, "update_settings", %{"settings" => kv}, socket) do
    coerced =
      Enum.into(kv, %{}, fn {k, v} -> {String.to_atom(k), coerce_setting_value(v)} end)

    :ok = Worker.Settings.put_many(coerced)
    Logger.info("HubClient: settings updated: #{inspect(coerced)}")
    {:ok, socket}
  end

  def handle_message(_topic, "start_recording", %{"discord_id" => did, "campaign_id" => cid}, socket) do
    Task.start(fn ->
      case Worker.Recording.Recorder.start_for_owner(did, cid) do
        {:ok, info} ->
          Logger.info("HubClient: UI-triggered recording started session=#{info.session_id}")

        {:error, reason} ->
          Logger.warning("HubClient: UI start_recording failed: #{inspect(reason)}")
      end
    end)

    {:ok, socket}
  end

  def handle_message(
        _topic,
        "audio_chunk",
        %{"session_id" => sid, "discord_id" => did, "chunk" => chunk},
        socket
      ) do
    Worker.Recording.AudioBuffer.append(sid, did, chunk)
    {:ok, socket}
  end

  def handle_message(_topic, "stop_recording", %{"campaign_id" => cid}, socket) do
    Task.start(fn ->
      case Worker.Recording.Recorder.stop_for_campaign(cid) do
        {:ok, info} ->
          Logger.info("HubClient: UI-triggered recording stopped session=#{info.session_id}")

        {:error, :not_recording} ->
          # Recorder doesn't have an entry — likely worker restarted while a
          # session was active. End the session directly so the UI unsticks.
          case Worker.Repo.active_session_for(cid) do
            nil ->
              Logger.warning("HubClient: UI stop with no Recorder entry and no active session")

            session ->
              Logger.warning(
                "HubClient: Recorder has no entry; fallback SessionEnded for session=#{session.id}"
              )

              {:ok, _} =
                Worker.Intents.publish(%{
                  "kind" => Shared.Events.session_ended(),
                  "id" => session.id
                })
          end

        {:error, reason} ->
          Logger.warning("HubClient: UI stop_recording failed: #{inspect(reason)}")
      end
    end)

    {:ok, socket}
  end

  def handle_message(topic, event, payload, socket) do
    Logger.warning(
      "HubClient: unhandled message topic=#{topic} event=#{event} payload=#{inspect(payload)}"
    )

    {:ok, socket}
  end

  defp coerce_setting_value(v) when is_binary(v) do
    case v do
      "local" -> :local
      "bundled" -> :bundled
      "batch" -> :batch
      "live" -> :live
      "listen" -> :listen
      other -> other
    end
  end

  defp coerce_setting_value(v), do: v

  @impl Slipstream
  def handle_disconnect(reason, socket) do
    Logger.warning("HubClient: disconnected (#{inspect(reason)}); will reconnect")
    reconnect(socket)
  end

  @impl Slipstream
  def handle_info({:publish_status, payload}, socket) do
    if joined?(socket, topic(socket)) do
      push(socket, topic(socket), "publish_status", %{payload: payload})
    end

    {:noreply, socket}
  end

  @impl Slipstream
  def handle_call({:publish_intent, payload}, _from, socket) do
    if joined?(socket, topic(socket)) do
      case push(socket, topic(socket), "publish_intent", %{payload: payload}) do
        {:ok, ref} ->
          case await_reply(ref, 5_000) do
            {:ok, %{"seq" => seq}} -> {:reply, {:ok, seq}, socket}
            {:error, reason} -> {:reply, {:error, reason}, socket}
            other -> {:reply, {:error, {:bad_reply, other}}, socket}
          end

        {:error, reason} ->
          {:reply, {:error, reason}, socket}
      end
    else
      {:reply, {:error, :not_connected}, socket}
    end
  end

  # ─── Helpers ──────────────────────────────────────────────────────

  defp topic(%{assigns: %{worker_id: id}}), do: "worker:#{id}"

  defp ack(socket, seq) do
    push(socket, topic(socket), "ack_applied", %{seq: seq})
  end

  defp config do
    worker_id = Repo.get_state(:worker_id)
    token = Repo.get_state(:hub_token)
    base = Repo.get_state(:hub_base_url)

    uri =
      ws_base(base) <>
        "/worker_socket/websocket?" <>
        URI.encode_query(token: token, worker_id: worker_id, vsn: "2.0.0")

    [
      uri: uri,
      reconnect_after_msec: [200, 500, 1_000, 2_000, 5_000],
      heartbeat_interval_msec: 30_000
    ]
  end

  defp ws_base("http://" <> rest), do: "ws://" <> rest
  defp ws_base("https://" <> rest), do: "wss://" <> rest
end
