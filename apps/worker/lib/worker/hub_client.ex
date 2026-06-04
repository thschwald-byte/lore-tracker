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

  # Issue #430: handle_message/4-Helfer aus dem Klausel-Block ausgelagert (waren
  # dazwischen → „clauses should be grouped together").

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

  # Issue #392: Streamer-Liste aus dem Live-Recording-State (AudioBuffer) in den
  # Snapshot mergen — frisch gemountete CampaignLive weiß sofort wer streamt.
  defp maybe_add_mic_streamers(%{"active_session" => %{"id" => sid}} = payload)
       when is_binary(sid) do
    Map.put(payload, "mic_streamers", Worker.Recording.AudioBuffer.streamers(sid))
  end

  defp maybe_add_mic_streamers(payload), do: payload

  # Entwurfs-Overrides (string-keyed vom Hub) in die Campaign mergen. vorgaben-
  # Inner-Keys als Atome (:name/:darstellungsform).
  defp merge_preview_overrides(campaign, stage, overrides)
       when is_map(overrides) and overrides != %{} do
    flavors = Map.merge(campaign[:flavors] || %{}, Map.get(overrides, "flavors", %{}) || %{})

    vorgaben =
      case Map.get(overrides, "vorgaben", %{}) |> Map.get(stage) do
        %{} = v ->
          inner = %{
            name: Map.get(v, "name", ""),
            darstellungsform: Map.get(v, "darstellungsform", "fliesstext")
          }

          Map.put(campaign[:vorgaben] || %{}, stage, inner)

        _ ->
          campaign[:vorgaben] || %{}
      end

    campaign |> Map.put(:flavors, flavors) |> Map.put(:vorgaben, vorgaben)
  end

  defp merge_preview_overrides(campaign, _stage, _), do: campaign

  defp parse_setting_key(k, known_keys) when is_binary(k) do
    atom = String.to_existing_atom(k)
    if MapSet.member?(known_keys, atom), do: {:ok, atom}, else: :error
  rescue
    ArgumentError -> :error
  end

  defp parse_setting_key(_k, _known_keys), do: :error

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
      Materializer.apply_local(%{
        "event_id" => ev["event_id"],
        "payload" => ev["payload"],
        "ts" => ev["ts"],
        "author_worker_id" => nil
      })
    end)

    {:ok, socket}
  end

  # Issue #141 (Etappe 4a): Global-Events-Pull. Hub fragt uns nach campaign-
  # losen Events im worker_events_global ab last_event_id.
  def handle_message(
        _topic,
        "pull_request_global",
        %{"last_event_id" => last_event_id, "requesting_worker_id" => requester},
        socket
      ) do
    events =
      Worker.Schema.DynamicTables.global_events_since(last_event_id)
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
        "HubClient: pull_request_global since=#{inspect(last_event_id)} → #{length(events)} events to worker=#{requester}"
      )
    end

    push(socket, topic(socket), "pull_response_global", %{
      requesting_worker_id: requester,
      events: events
    })

    {:ok, socket}
  end

  def handle_message(_topic, "pull_batch_global", %{"events" => events}, socket) do
    if events != [] do
      Logger.info("HubClient: pull_batch_global → #{length(events)} events")
    end

    Enum.each(events, fn ev ->
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

  def handle_message(_topic, "snapshot_request", %{"request_id" => rid, "scope" => scope}, socket) do
    payload = Worker.Repo.snapshot(scope) |> maybe_add_mic_streamers()
    push(socket, topic(socket), "snapshot_response", %{request_id: rid, payload: payload})
    {:ok, socket}
  end

  # Issue #400: Mic-Setup-Phrase-Clip transkribieren. Kein Session-Kontext,
  # kein Initial-Prompt — der Hub vergleicht den rohen ASR-Output gegen die
  # erwartete Test-Phrase. Fehler (undecodebare Base64, ffmpeg/whisper) →
  # leerer Text, der Hub behandelt das als Fehlschlag + lässt erneut lauschen.
  def handle_message(
        _topic,
        "transcribe_clip_request",
        %{"request_id" => rid, "chunk" => b64, "discord_id" => did},
        socket
      ) do
    text =
      with {:ok, bin} <- Base.decode64(b64),
           {:ok, t} <- Worker.Recording.Transcribe.transcribe_clip(bin) do
        t
      else
        :error ->
          Logger.warning("HubClient: transcribe_clip_request mit undecodebarer Base64")
          ""

        {:error, reason} ->
          Logger.warning("HubClient: transcribe_clip fehlgeschlagen: #{inspect(reason)}")
          ""
      end

    push(socket, topic(socket), "transcribe_clip_response", %{
      request_id: rid,
      text: text,
      discord_id: did
    })

    {:ok, socket}
  end

  # Issue #313: Prompt-Vorschau-Segmente für den Stil-Editor bauen. Tuples aus
  # Pipeline.preview_prompt/2 → JSON-Maps, da der Socket-Serializer keine
  # Tuples kann.
  def handle_message(
        _topic,
        "preview_request",
        %{"request_id" => rid, "campaign_id" => cid, "stage" => stage} = msg,
        socket
      ) do
    # Issue #320: die Hub-Live-Vorschau schickt die aktuellen Entwürfe (noch
    # nicht gespeichert) als `overrides` mit — der Worker baut den echten Prompt
    # mit DIESEN Werten, damit man beim Tippen sieht wie der Prompt sich ändert
    # (inkl. einer neu getippten Überschrift, die im gespeicherten Stand fehlt).
    overrides = Map.get(msg, "overrides", %{})

    segments =
      with true <- stage in ["summary", "epos", "chronik"],
           campaign when is_map(campaign) <- Worker.Repo.get_campaign(cid) do
        campaign
        |> merge_preview_overrides(stage, overrides)
        |> then(&Worker.Recording.Pipeline.preview_prompt(stage, &1))
        |> Enum.map(&serialize_preview_segment/1)
      else
        _ -> []
      end

    push(socket, topic(socket), "preview_response", %{request_id: rid, segments: segments})
    {:ok, socket}
  end

  def handle_message(_topic, "shutdown_worker", _payload, socket) do
    Worker.Lifecycle.shutdown()
    {:ok, socket}
  end

  # Issue #392: graceful Mic-Stop vom Hub (expliziter Stop-Button). Entfernt
  # den Streamer sofort aus der Presence statt auf den Chunk-Recency-Sweep
  # (~4s) zu warten.
  def handle_message(_topic, "mic_leave", %{"session_id" => sid, "discord_id" => did}, socket) do
    Worker.Recording.AudioBuffer.drop_streamer(sid, did)
    {:ok, socket}
  end

  def handle_message(_topic, "update_settings", %{"settings" => kv}, socket) do
    known_keys = Worker.Settings.defaults() |> Map.keys() |> MapSet.new()

    coerced =
      Enum.reduce(kv, %{}, fn {k, v}, acc ->
        case parse_setting_key(k, known_keys) do
          {:ok, key} ->
            Map.put(acc, key, coerce_setting_value(v))

          :error ->
            Logger.warning("HubClient: dropping unknown setting key=#{inspect(k)}")
            acc
        end
      end)

    :ok = Worker.Settings.put_many(coerced)

    # Issue #510: secret-Keys NIE im Log durchreichen. Settings können API-Keys
    # enthalten (anthropic_api_key / openai_api_key / gemini_api_key) — den
    # Wert maskieren, nur den Schlüssel-Namen + Länge loggen.
    Logger.info("HubClient: settings updated: #{inspect(redact_secrets(coerced))}")
    {:ok, socket}
  end

  def handle_message(
        _topic,
        "start_recording",
        %{"discord_id" => did, "campaign_id" => cid} = payload,
        socket
      ) do
    # Issue #19: "single_source" = Tisch-Raummikro (Diarisierung post-session).
    # Fehlt das Feld (Version-Skew während Deploy), fällt's auf :default zurück.
    mode = if payload["mode"] == "single_source", do: :single_source, else: :default

    Task.start(fn ->
      case Worker.Recording.Recorder.start_for_owner(did, cid, mode) do
        {:ok, info} ->
          Logger.info(
            "HubClient: UI-triggered recording started session=#{info.session_id} mode=#{mode}"
          )

        # Issue #355 cleanup: Recorder returnt {:error, :already_recording,
        # existing_info} als 3-Tuple — vorher hat der 2-Tuple-only Match das
        # crashing-loop'd (siehe Worker-Log-Floods bei Doppelklick auf
        # rec_start). Jetzt: warning + Existing-Session-ID loggen.
        {:error, :already_recording, existing} ->
          Logger.warning(
            "HubClient: UI start_recording rejected — already recording session=#{existing.session_id} campaign=#{existing.campaign_id}"
          )

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

  # Issue #292: GpuQueue-Job-Verwaltung vom /admin/jobs-LV.
  def handle_message(
        _topic,
        "gpu_job_action",
        %{"action" => action, "job_id" => job_id},
        socket
      )
      when is_binary(action) and is_binary(job_id) do
    result =
      case action do
        "move_up" -> Worker.GpuQueue.move_up(job_id)
        "move_down" -> Worker.GpuQueue.move_down(job_id)
        "cancel" -> Worker.GpuQueue.cancel(job_id)
        _ -> {:error, :unknown_action}
      end

    case result do
      :ok ->
        Logger.info("HubClient: gpu_job_action #{action} ok job_id=#{job_id}")

      {:error, reason} ->
        Logger.warning(
          "HubClient: gpu_job_action #{action} failed job_id=#{job_id} reason=#{inspect(reason)}"
        )
    end

    {:ok, socket}
  end

  def handle_message(
        _topic,
        "start_probelauf_sweep",
        %{"discord_id" => did, "stage" => stage, "models" => models} = payload,
        socket
      )
      when is_integer(stage) and is_list(models) do
    session_set = payload["session_set"]

    Task.start(fn ->
      case Worker.Probelauf.start_sweep(did, stage, models, session_set) do
        {:ok, sweep_id} ->
          Logger.info(
            "HubClient: UI-triggered probelauf-sweep started sweep_id=#{sweep_id} stage=#{stage} models=#{inspect(models)} session_set=#{inspect(session_set)}"
          )

        {:error, {:already_running, existing}} ->
          Logger.warning(
            "HubClient: UI start_probelauf_sweep rejected — already running #{existing}"
          )

        {:error, reason} ->
          Logger.warning("HubClient: UI start_probelauf_sweep rejected — #{inspect(reason)}")
      end
    end)

    {:ok, socket}
  end

  # Issue #262 / #284: Stage-isolierter Sweep mit optionalem session_set.
  def handle_message(
        _topic,
        "start_probelauf_sweep_isolated",
        %{"discord_id" => did, "stage" => stage, "models" => models} = payload,
        socket
      )
      when is_integer(stage) and is_list(models) do
    session_set = payload["session_set"]

    Task.start(fn ->
      case Worker.Probelauf.start_sweep_isolated(did, stage, models, session_set) do
        {:ok, sweep_id} ->
          Logger.info(
            "HubClient: UI-triggered probelauf-sweep-isolated started sweep_id=#{sweep_id} stage=#{stage} models=#{inspect(models)} session_set=#{inspect(session_set)}"
          )

        {:error, {:already_running, existing}} ->
          Logger.warning(
            "HubClient: UI start_probelauf_sweep_isolated rejected — already running #{existing}"
          )

        {:error, reason} ->
          Logger.warning(
            "HubClient: UI start_probelauf_sweep_isolated rejected — #{inspect(reason)}"
          )
      end
    end)

    {:ok, socket}
  end

  # Issue #289 Phase 4: Param-Sweep über Temperature-Varianten.
  def handle_message(
        _topic,
        "start_probelauf_sweep_isolated_param",
        %{"discord_id" => did, "stage" => stage, "temperatures" => temperatures} = payload,
        socket
      )
      when is_integer(stage) and is_list(temperatures) do
    session_set = payload["session_set"]

    Task.start(fn ->
      case Worker.Probelauf.start_sweep_isolated_param(did, stage, temperatures, session_set) do
        {:ok, sweep_id} ->
          Logger.info(
            "HubClient: UI-triggered probelauf-sweep-isolated-param started " <>
              "sweep_id=#{sweep_id} stage=#{stage} temperatures=#{inspect(temperatures)} " <>
              "session_set=#{inspect(session_set)}"
          )

        {:error, {:already_running, existing}} ->
          Logger.warning(
            "HubClient: UI start_probelauf_sweep_isolated_param rejected — already running #{existing}"
          )

        {:error, reason} ->
          Logger.warning(
            "HubClient: UI start_probelauf_sweep_isolated_param rejected — #{inspect(reason)}"
          )
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

  # Issue #154 (Etappe 4c.1): Hub-Side-Producer (LiveViews/Controllers) rufen
  # `Hub.EventBridge.publish/1` statt direkt in events zu schreiben — Hub
  # picked uns als Ziel-Worker und pusht den Event-Payload. Wir bauen daraus
  # ein normales Worker-Event via `Worker.Intents.publish/1` (Worker-First-
  # Apply lokal, dann publish_intent zurück zum Hub → PubSub-Broadcast).
  def handle_message(_topic, "bridge_publish", %{"payload" => payload}, socket) do
    # Issue #430: Intents.publish/1 gibt immer {:ok, …} (kein toter {:error}-Branch).
    Task.start(fn -> {:ok, _} = Worker.Intents.publish(payload) end)

    {:ok, socket}
  end

  def handle_message(
        _topic,
        "start_campaign_replay",
        %{"discord_id" => did, "campaign_id" => cid},
        socket
      ) do
    Task.start(fn ->
      case Worker.Recording.CampaignReplay.start(cid, did) do
        {:ok, run_id} ->
          Logger.info(
            "HubClient: UI-triggered campaign_replay started campaign=#{cid} run_id=#{run_id}"
          )

        {:error, {:already_running, existing}} ->
          Logger.warning(
            "HubClient: UI start_campaign_replay rejected — already running #{existing}"
          )

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
          # Recorder doesn't have an entry — could be either:
          # (a) Worker restarted while a session was active → AudioBuffer hat
          #     auch nichts pending → wir publishen Fallback-SessionEnded
          #     damit die UI nicht hängen bleibt.
          # (b) Race-Window: Recorder hat State schon gepoppt, AudioBuffer.
          #     finalize hat den Transcribe-Task gestartet, der publisht das
          #     echte SessionEnded selber wenn Stage 1 durch ist. KEIN Fallback
          #     in diesem Fall (Issue #233 — Doppel-SessionEnded triggerte die
          #     Pipeline doppelt mit halbem Transcript).
          case Worker.Repo.active_session_for(cid) do
            nil ->
              Logger.warning("HubClient: UI stop with no Recorder entry and no active session")

            session ->
              if Worker.Recording.AudioBuffer.has_pending_transcribe?(session.id) do
                Logger.info(
                  "HubClient: UI stop_recording during Transcribe — let Transcribe.run publish SessionEnded for session=#{session.id}"
                )
              else
                Logger.warning(
                  "HubClient: Recorder has no entry; fallback SessionEnded for session=#{session.id}"
                )

                {:ok, _} =
                  Worker.Intents.publish(%{
                    "kind" => Shared.Events.session_ended(),
                    "id" => session.id
                  })
              end
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

  # Issue #510: API-Key-Werte vor Logger.info maskieren — Settings können
  # secret-Keys enthalten (anthropic_api_key / openai_api_key /
  # gemini_api_key). redact_secrets/1 ersetzt den Wert durch eine Längen-
  # Notiz; der Schlüssel-Name bleibt für die Diagnose sichtbar. Hinter alle
  # handle_message/4-Klauseln platziert (--warnings-as-errors-Gate).
  @secret_keys ~w(anthropic_api_key openai_api_key gemini_api_key)a

  defp redact_secrets(map) when is_map(map) do
    Enum.into(map, %{}, fn
      {k, v} when k in @secret_keys and is_binary(v) ->
        {k, "<redacted #{String.length(v)} chars>"}

      kv ->
        kv
    end)
  end

  defp coerce_setting_value(v) when is_binary(v) do
    case v do
      "local" -> :local
      "bundled" -> :bundled
      "anthropic" -> :anthropic
      "batch" -> :batch
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

  def handle_info({:report_models, names}, socket) do
    if joined?(socket, topic(socket)) do
      push(socket, topic(socket), "report_models", %{models: names})
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

  # Issue #313: Prompt-Vorschau-Segmente JSON-tauglich machen (Socket-Serializer
  # kann keine Tuples).
  defp serialize_preview_segment({:locked, text}),
    do: %{kind: "locked", text: to_string(text)}

  # Issue #320: Rahmen-Text um die Überschrift — der Hub blendet ihn nur ein,
  # wenn die Überschrift gesetzt ist (deckungsgleich mit heading_directive/1).
  defp serialize_preview_segment({:heading_frame, text}),
    do: %{kind: "heading_frame", text: to_string(text)}

  defp serialize_preview_segment({:editable, slot, text}),
    do: %{kind: "editable", slot: to_string(slot), text: to_string(text)}

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
