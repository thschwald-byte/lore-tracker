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

  def handle_message(topic, event, payload, socket) do
    Logger.warning(
      "HubClient: unhandled message topic=#{topic} event=#{event} payload=#{inspect(payload)}"
    )

    {:ok, socket}
  end

  @impl Slipstream
  def handle_disconnect(reason, socket) do
    Logger.warning("HubClient: disconnected (#{inspect(reason)}); will reconnect")
    reconnect(socket)
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
