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

  Issue #123: 2-arg-Variante (event_id, payload) wird vom Worker-First-Apply
  benutzt — der Worker hat den Event lokal schon materialisiert und schickt
  ihn jetzt zum Hub, mit seiner eigenen UUIDv7.
  """
  @spec publish(map(), timeout()) :: {:ok, pos_integer()} | {:error, term()}
  def publish(payload, timeout \\ 5_000) when is_map(payload) do
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
    send(__MODULE__, {:subscribe_campaigns, [campaign_id]})
    :ok
  end

  @spec unsubscribe_campaign(String.t()) :: :ok
  def unsubscribe_campaign(campaign_id) when is_binary(campaign_id) do
    send(__MODULE__, {:unsubscribe_campaigns, [campaign_id]})
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

  @impl Slipstream
  def handle_join(_topic, %{"head" => head}, socket) do
    from = Materializer.last_applied_seq()

    Logger.info(
      "HubClient: channel joined (hub head=#{head}, local last_applied_seq=#{from}); requesting catch-up"
    )

    push(socket, topic(socket), "catch_up_request", %{from: from})
    push_initial_subscriptions(socket)
    {:ok, socket}
  end

  def handle_join(_topic, join_response, socket) do
    Logger.info("HubClient: channel joined (no head): #{inspect(join_response)}")
    push(socket, topic(socket), "catch_up_request", %{from: Materializer.last_applied_seq()})
    push_initial_subscriptions(socket)
    {:ok, socket}
  end

  # Issue #129 (Etappe 3b): nach Reconnect schickt der Worker die Liste
  # seiner aktuellen Member-Campaigns als initial subscribe — der Hub-Tracker
  # nach Disconnect hat den Worker-Eintrag verloren, subscribed_campaigns
  # muss neu aufgebaut werden.
  #
  # Issue #131 (Etappe 3c): direkt danach pull_since pro Campaign — fragt
  # andere Worker via Hub-Broker nach Events die wir noch nicht haben (z.B.
  # weil ein Peer sie lokal erzeugt hat während wir offline waren).
  defp push_initial_subscriptions(socket) do
    me = Repo.get_state(:admin_discord_id)

    if is_binary(me) do
      campaign_ids = Repo.list_campaign_ids_for(me)

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
    end

    :ok
  end

  @impl Slipstream
  def handle_message(_topic, "event_appended", payload, socket) do
    case Materializer.apply_event(payload) do
      {:applied, seq} -> ack(socket, seq)
      :skipped -> :ok
    end

    {:ok, socket}
  end

  # Issue #131 (Etappe 3c): Hub fragt uns nach Events einer Campaign seit
  # `last_event_id`. Wir lesen aus dem lokalen per-Campaign-Store, schicken
  # pull_response zurück mit dem Anfrager-worker_id (Hub forwarded an ihn).
  def handle_message(
        _topic,
        "pull_request",
        %{
          "campaign_id" => cid,
          "last_event_id" => last_event_id,
          "requesting_worker_id" => requester
        },
        socket
      ) do
    events =
      Worker.Schema.DynamicTables.events_since(cid, last_event_id)
      |> Enum.map(fn {event_id, hub_seq, payload, ts} ->
        %{
          event_id: event_id,
          hub_seq: hub_seq,
          payload: payload,
          ts: DateTime.to_iso8601(ts)
        }
      end)

    if events != [] do
      Logger.info(
        "HubClient: pull_request for campaign=#{cid} since=#{inspect(last_event_id)} → #{length(events)} events to worker=#{requester}"
      )
    end

    push(socket, topic(socket), "pull_response", %{
      campaign_id: cid,
      requesting_worker_id: requester,
      events: events
    })

    {:ok, socket}
  end

  # Hub forwarded Events von einem anderen Worker zu uns — durch Materializer
  # schicken, Idempotenz auf event_id verhindert Doppel-Apply.
  def handle_message(_topic, "pull_batch", %{"campaign_id" => cid, "events" => events}, socket) do
    if events != [] do
      Logger.info("HubClient: pull_batch campaign=#{cid} → #{length(events)} events")
    end

    Enum.each(events, fn ev ->
      # Wire-Frame: %{event_id, hub_seq, payload, ts}. Materializer-Pfad
      # do_apply braucht "seq" oder erkennt nil → für sync-Pull machen
      # wir den lokalen Apply ohne seq (Hub-Sync war nicht durch).
      Materializer.apply_local(%{
        "event_id" => ev["event_id"],
        "payload" => ev["payload"],
        "ts" => ev["ts"],
        "author_worker_id" => nil
      })
    end)

    {:ok, socket}
  end

  def handle_message(_topic, "catch_up_batch", %{"events" => events, "head_seq" => head}, socket) do
    Logger.info("HubClient: catch_up_batch (#{length(events)} events, hub head=#{head})")
    last = Materializer.apply_batch(events)

    if last > 0 do
      ack(socket, last)
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

        # Publish in a separate task — wir sind hier IM handle_message des
        # HubClient-GenServers, und Worker.Intents.publish ist ein
        # GenServer.call AUF diese GenServer-Instance. Synchron würde das
        # deadlocken (timeout nach 5s, publish failed silently).
        Task.start(fn ->
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

  def handle_message(_topic, "start_probelauf", %{"discord_id" => did}, socket) do
    Task.start(fn ->
      case Worker.Probelauf.start(did) do
        {:ok, run_id} ->
          Logger.info("HubClient: UI-triggered probelauf started run_id=#{run_id}")

        {:error, {:already_running, existing}} ->
          Logger.warning("HubClient: UI start_probelauf rejected — already running #{existing}")
      end
    end)

    {:ok, socket}
  end

  def handle_message(
        _topic,
        "start_probelauf_sweep",
        %{"discord_id" => did, "stage" => stage, "models" => models},
        socket
      )
      when is_integer(stage) and is_list(models) do
    Task.start(fn ->
      case Worker.Probelauf.start_sweep(did, stage, models) do
        {:ok, sweep_id} ->
          Logger.info("HubClient: UI-triggered probelauf-sweep started sweep_id=#{sweep_id} stage=#{stage} models=#{inspect(models)}")

        {:error, {:already_running, existing}} ->
          Logger.warning("HubClient: UI start_probelauf_sweep rejected — already running #{existing}")

        {:error, reason} ->
          Logger.warning("HubClient: UI start_probelauf_sweep rejected — #{inspect(reason)}")
      end
    end)

    {:ok, socket}
  end

  def handle_message(
        _topic,
        "start_session_regenerate",
        %{"discord_id" => did, "campaign_id" => cid, "session_id" => sid},
        socket
      ) do
    Task.start(fn ->
      # Owner-Check macht die Pipeline selbst (maybe_run filtert nach
      # campaign.owner_discord_id == admin_discord_id). Wir leiten den Trigger
      # einfach weiter — der Hub hat schon den Owner-Worker gepickt.
      Logger.info(
        "HubClient: UI-triggered session-regenerate by=#{did} campaign=#{cid} session=#{sid}"
      )

      :ok = Worker.Recording.Pipeline.run_for_session(sid)
    end)

    {:ok, socket}
  end

  def handle_message(_topic, "start_campaign_replay", %{"discord_id" => did, "campaign_id" => cid}, socket) do
    Task.start(fn ->
      case Worker.Recording.CampaignReplay.start(cid, did) do
        {:ok, run_id} ->
          Logger.info("HubClient: UI-triggered campaign_replay started campaign=#{cid} run_id=#{run_id}")

        {:error, {:already_running, existing}} ->
          Logger.warning("HubClient: UI start_campaign_replay rejected — already running #{existing}")

        {:error, :no_sessions_with_utterances} ->
          Logger.warning("HubClient: UI start_campaign_replay for empty campaign=#{cid}")

        {:error, reason} ->
          Logger.warning("HubClient: UI start_campaign_replay failed: #{inspect(reason)}")
      end
    end)

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
      "anthropic" -> :anthropic
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
