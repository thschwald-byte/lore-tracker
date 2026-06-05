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
  alias Worker.HubClient.{Bridge, Events, Mic, Probelauf, Replay, Rpc}

  # ─── Lifecycle ────────────────────────────────────────────────────

  def start_link(opts) do
    Slipstream.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Publish an event payload through the channel. Synchronous — blocks until
  the hub assigns a seq and replies, or returns `{:error, :not_connected}`
  if the socket is down.

  Issue #123: 2-arg-Variante (event_id, payload) wird vom Worker-First-Apply
  benutzt — der Worker hat den Event lokal schon materialisiert und schickt
  ihn jetzt zum Hub, mit seiner eigenen UUIDv7.
  """
  # Issue #430: kein Default-Wert in einer von mehreren publish/2-Klauseln
  # (Compiler-Warnung) — stattdessen eine explizite publish/1, die das alte
  # 1-arg-map-Verhalten (timeout 5_000) erhält.
  @spec publish(map()) :: {:ok, pos_integer()} | {:error, term()}
  def publish(payload) when is_map(payload), do: publish(payload, 5_000)

  @spec publish(map(), timeout()) :: {:ok, pos_integer()} | {:error, term()}
  def publish(payload, timeout) when is_map(payload) and is_integer(timeout) do
    GenServer.call(__MODULE__, {:publish_intent, nil, payload}, timeout)
  catch
    :exit, reason -> {:error, reason}
  end

  @spec publish(String.t(), map()) :: {:ok, pos_integer()} | {:error, term()}
  def publish(event_id, payload) when is_binary(event_id) and is_map(payload) do
    GenServer.call(__MODULE__, {:publish_intent, event_id, payload}, 5_000)
  catch
    :exit, reason -> {:error, reason}
  end

  @doc """
  Issue #129 (Etappe 3b): Worker meldet dem Hub neue Campaign-Subscriptions
  (typischerweise nach einem Membership-Event). Fire-and-forget — wenn der
  WebSocket gerade down ist, wird die Subscription beim Reconnect via
  handle_join nachgeholt (das schickt initial die volle Liste).
  """
  @spec subscribe_campaign(String.t()) :: :ok
  def subscribe_campaign(campaign_id) when is_binary(campaign_id) do
    if Process.whereis(__MODULE__), do: send(__MODULE__, {:subscribe_campaigns, [campaign_id]})
    :ok
  end

  @spec unsubscribe_campaign(String.t()) :: :ok
  def unsubscribe_campaign(campaign_id) when is_binary(campaign_id) do
    if Process.whereis(__MODULE__), do: send(__MODULE__, {:unsubscribe_campaigns, [campaign_id]})
    :ok
  end

  @doc """
  Issue #50: Push der lokalen Ollama-Modell-Liste an den Hub. Settings-LV
  aggregiert über alle Worker eines Admins für das "auf N/M Workern"-Badge.
  Fire-and-forget. Wird nach jedem erfolgreichen `Worker.LLM.Local.list_models/0`
  in `Worker.Repo.snapshot(%{"kind" => "settings"})` aufgerufen.
  """
  @spec report_models([String.t()]) :: :ok
  def report_models(model_names) when is_list(model_names) do
    if Process.whereis(__MODULE__), do: send(__MODULE__, {:report_models, model_names})
    :ok
  end

  @doc """
  Issue #468 Cut 2: Worker meldet Hub dass er die Session in seinem
  AudioBuffer geöffnet hat. Hub.Commands.pick_leader bevorzugt diesen
  Worker für nachfolgende `forward_audio_chunk`-Calls (Stickiness). Wird
  von `Worker.AudioBuffer.handle_call({:open, …})` aufgerufen.

  Fire-and-forget. Wenn der WebSocket gerade down ist, wird die
  Information beim Reconnect NICHT automatisch nachgeholt — der Worker
  würde nach einem Hub-Reconnect alle offenen Sessions neu melden müssen
  (heute out-of-scope; Cut 3 / #466).
  """
  @spec announce_session_held(String.t()) :: :ok
  def announce_session_held(session_id) when is_binary(session_id) do
    if Process.whereis(__MODULE__), do: send(__MODULE__, {:session_held, session_id})
    :ok
  end

  @doc "Issue #468 Cut 2: Gegenstück zu announce_session_held — Session finalisiert."
  @spec announce_session_released(String.t()) :: :ok
  def announce_session_released(session_id) when is_binary(session_id) do
    if Process.whereis(__MODULE__), do: send(__MODULE__, {:session_released, session_id})
    :ok
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
    {:ok, join(socket, topic(socket), join_payload())}
  end

  defp join_payload do
    v = Worker.Version.current()

    %{
      "worker_version" => v.vsn,
      "worker_sha" => v.sha,
      "shared_version" => shared_version(),
      "protocol_version" => 1
    }
  end

  defp shared_version do
    case Application.spec(:shared, :vsn) do
      vsn when is_list(vsn) -> List.to_string(vsn)
      vsn when is_binary(vsn) -> vsn
      _ -> "unknown"
    end
  end

  # Issue #152 (Etappe 4b): kein catch_up_request mehr beim Join. Sync läuft
  # komplett über subscribe_campaigns + pull_since (Etappe 3c) + pull_since_global
  # (Etappe 4a) — `push_initial_subscriptions/1` schickt beide Pulls direkt nach
  # dem Subscribe. Der head-Wert aus dem Join-Reply zählt seit 4b nur noch die
  # Hub-Side-Producer-Events (LiveView/Controller-Edits), nicht mehr die
  # Worker-Push-Events — wir loggen ihn weiter als reine Diagnostik.
  @impl Slipstream
  def handle_join(_topic, %{"head" => head} = reply, socket) do
    from = Materializer.last_applied_seq()

    Logger.info("HubClient: channel joined (hub head=#{head}, local last_applied_seq=#{from})")

    # Issue #492: Hub meldet seine SHA im Join-Reply (per Map.get, nicht im
    # Pattern — ein noch-alter Hub schickt den Key nicht). An den Updater
    # weiterreichen; der ist nur bei aktivem Auto-Update gestartet (no-op sonst).
    maybe_notify_updater(reply["hub_sha"])
    mark_self_boot_good()

    push_initial_subscriptions(socket)
    push_initial_models(socket)
    {:ok, socket}
  end

  def handle_join(_topic, join_response, socket) do
    Logger.info("HubClient: channel joined (no head): #{inspect(join_response)}")
    maybe_notify_updater(join_response["hub_sha"])
    mark_self_boot_good()
    push_initial_subscriptions(socket)
    push_initial_models(socket)
    {:ok, socket}
  end

  # Issue #492: Hub-SHA an den Updater. Fire-and-forget + Process.whereis-Guard
  # (wie subscribe_campaign/1) — wenn Auto-Update aus ist, läuft kein Updater
  # und der Aufruf ist ein no-op.
  defp maybe_notify_updater(sha) when is_binary(sha) do
    if Process.whereis(Worker.Updater), do: Worker.Updater.hub_sha_seen(sha)
    :ok
  end

  defp maybe_notify_updater(_), do: :ok

  # Issue #500: erfolgreicher Join = der Worker ist voll oben (Bootstrap + Tree +
  # Pairing + WS ok) → die laufende SHA als „good" markieren (Boot-Crash-Rollback-
  # Baseline). No-op ohne Auto-Update.
  defp mark_self_boot_good do
    Worker.Updater.mark_boot_good(Worker.Version.current().sha)
    :ok
  end

  # Issue #50: nach Join die initiale Modell-Liste an den Hub melden, damit
  # die Settings-LV das "auf N/M Workern"-Badge schon ohne Snapshot-Trigger
  # zeigen kann.
  defp push_initial_models(socket) do
    case Worker.LLM.Local.list_models() do
      {:ok, names} ->
        push(socket, topic(socket), "report_models", %{models: names})
        Logger.info("HubClient: initial report_models (#{length(names)} models)")

      {:error, _reason} ->
        push(socket, topic(socket), "report_models", %{models: []})
    end
  end

  # Issue #129 (Etappe 3b): nach Reconnect schickt der Worker die Liste
  # seiner aktuellen Member-Campaigns als initial subscribe — der Hub-Tracker
  # nach Disconnect hat den Worker-Eintrag verloren, subscribed_campaigns
  # muss neu aufgebaut werden.
  #
  # Issue #131 (Etappe 3c): direkt danach pull_since pro Campaign — fragt
  # andere Worker via Hub-Broker nach Events die wir noch nicht haben (z.B.
  # weil ein Peer sie lokal erzeugt hat während wir offline waren).
  #
  # Issue #141 (Etappe 4a): zusätzlich pull_since_global für die campaign-
  # losen Events (UserRoleSet, ProbelaufStarted etc.) im worker_events_global.
  defp push_initial_subscriptions(socket) do
    me = Repo.get_state(:admin_discord_id)

    if is_binary(me) do
      # Issue #215: für ALLE lokalen Campaigns subscriben, nicht nur die wo
      # der Admin Member ist. Wenn dieser Worker eine fremde Campaign hostet
      # (Single-Worker-Setup, Hub-User ohne eigenen Worker), muss er auch die
      # Hub-Subscription dafür haben — sonst routet EventBridge die Folge-
      # Events der Campaign zu :no_worker_online und sie failen silent.
      campaign_ids = Repo.all_campaigns() |> Enum.map(& &1.id)

      if campaign_ids != [] do
        push(socket, topic(socket), "subscribe_campaigns", %{campaign_ids: campaign_ids})
        Logger.info("HubClient: initial subscribe (#{length(campaign_ids)} campaigns)")

        cursors =
          Enum.map(campaign_ids, fn cid ->
            %{
              "campaign_id" => cid,
              "last_event_id" => Worker.Schema.DynamicTables.last_event_id(cid)
            }
          end)

        push(socket, topic(socket), "pull_since", %{cursors: cursors})
        Logger.info("HubClient: pull_since for #{length(cursors)} campaigns")
      end

      # Issue #141: Global-Cursor immer schicken — egal ob Worker Campaigns hat
      # oder nicht. Andere Worker können Global-Events haben die uns fehlen
      # (UserRoleSet von einem anderen Admin etc.).
      global_cursor = Worker.Schema.DynamicTables.last_global_event_id()
      push(socket, topic(socket), "pull_since_global", %{last_event_id: global_cursor})
      Logger.info("HubClient: pull_since_global (cursor=#{inspect(global_cursor)})")
    end

    :ok
  end

  @impl Slipstream
  def handle_message(_topic, "event_appended", payload, socket),
    do: Events.on_event_appended(payload, socket)

  def handle_message(_topic, "pull_request", payload, socket),
    do: Events.on_pull_request(payload, socket)

  def handle_message(_topic, "pull_batch", payload, socket),
    do: Events.on_pull_batch(payload, socket)

  def handle_message(_topic, "pull_request_global", payload, socket),
    do: Events.on_pull_request_global(payload, socket)

  def handle_message(_topic, "pull_batch_global", payload, socket),
    do: Events.on_pull_batch_global(payload, socket)

  def handle_message(_topic, "catch_up_batch", payload, socket),
    do: Events.on_catch_up_batch(payload, socket)

  def handle_message(_topic, "snapshot_request", payload, socket),
    do: Rpc.on_snapshot(payload, socket)

  def handle_message(_topic, "transcribe_clip_request", payload, socket),
    do: Mic.on_transcribe_clip_request(payload, socket)

  def handle_message(_topic, "preview_request", payload, socket),
    do: Rpc.on_preview(payload, socket)

  def handle_message(_topic, "shutdown_worker", _payload, socket) do
    Worker.Lifecycle.shutdown()
    {:ok, socket}
  end

  def handle_message(_topic, "mic_leave", payload, socket),
    do: Mic.on_mic_leave(payload, socket)

  def handle_message(_topic, "update_settings", payload, socket),
    do: Rpc.on_update_settings(payload, socket)

  def handle_message(_topic, "start_recording", payload, socket),
    do: Mic.on_start_recording(payload, socket)

  def handle_message(_topic, "audio_chunk", payload, socket),
    do: Mic.on_audio_chunk(payload, socket)

  def handle_message(_topic, "start_probelauf", payload, socket),
    do: Probelauf.on_start(payload, socket)

  def handle_message(_topic, "gpu_job_action", payload, socket),
    do: Rpc.on_gpu_job_action(payload, socket)

  def handle_message(_topic, "start_probelauf_sweep", payload, socket),
    do: Probelauf.on_sweep(payload, socket)

  def handle_message(_topic, "start_probelauf_sweep_isolated", payload, socket),
    do: Probelauf.on_sweep_isolated(payload, socket)

  def handle_message(_topic, "start_probelauf_sweep_isolated_param", payload, socket),
    do: Probelauf.on_sweep_isolated_param(payload, socket)

  def handle_message(_topic, "start_session_regenerate", payload, socket),
    do: Replay.on_session_regenerate(payload, socket)

  def handle_message(_topic, "bridge_publish", payload, socket),
    do: Bridge.on_publish(payload, socket)

  def handle_message(_topic, "start_campaign_replay", payload, socket),
    do: Replay.on_campaign_replay(payload, socket)

  def handle_message(_topic, "stop_recording", payload, socket),
    do: Mic.on_stop_recording(payload, socket)

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

  @impl Slipstream
  def handle_info({:subscribe_campaigns, ids}, socket) when is_list(ids) do
    if joined?(socket, topic(socket)) do
      push(socket, topic(socket), "subscribe_campaigns", %{campaign_ids: ids})
    end

    {:noreply, socket}
  end

  def handle_info({:unsubscribe_campaigns, ids}, socket) when is_list(ids) do
    if joined?(socket, topic(socket)) do
      push(socket, topic(socket), "unsubscribe_campaigns", %{campaign_ids: ids})
    end

    {:noreply, socket}
  end

  def handle_info({:publish_status, payload}, socket) do
    if joined?(socket, topic(socket)) do
      push(socket, topic(socket), "publish_status", %{payload: payload})
    end

    {:noreply, socket}
  end

  def handle_info({:report_models, names}, socket) do
    if joined?(socket, topic(socket)) do
      push(socket, topic(socket), "report_models", %{models: names})
    end

    {:noreply, socket}
  end

  def handle_info({:session_held, sid}, socket) do
    if joined?(socket, topic(socket)) do
      push(socket, topic(socket), "session_held", %{session_id: sid})
    end

    {:noreply, socket}
  end

  def handle_info({:session_released, sid}, socket) do
    if joined?(socket, topic(socket)) do
      push(socket, topic(socket), "session_released", %{session_id: sid})
    end

    {:noreply, socket}
  end

  @impl Slipstream
  def handle_call({:publish_intent, event_id, payload}, _from, socket) do
    if joined?(socket, topic(socket)) do
      frame =
        case event_id do
          nil -> %{payload: payload}
          id when is_binary(id) -> %{event_id: id, payload: payload}
        end

      case push(socket, topic(socket), "publish_intent", frame) do
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

  # ─── Channel-Helpers ──────────────────────────────────────────────
  # Issue #585: public, damit HubClient-Submodule (Worker.HubClient.Events,
  # .Mic, .Probelauf, .Replay, .Bridge, .Rpc) Slipstream-Frames bauen können
  # ohne `use Slipstream` zu kopieren.

  @doc false
  def topic(%{assigns: %{worker_id: id}}), do: "worker:#{id}"

  @doc false
  def ack(socket, seq) do
    push(socket, topic(socket), "ack_applied", %{seq: seq})
  end

  @doc false
  def push_event(socket, event, params) when is_binary(event) and is_map(params) do
    push(socket, topic(socket), event, params)
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
