defmodule Worker.Probelauf do
  @moduledoc """
  LLM-Smoke-Test (Issue #74). Bei UI-Trigger seedet eine dedizierte
  Probelauf-Kampagne (3 Sessions à 10/30/100 hartkodierte Utterances —
  short/medium/long Prompts), fährt sie sequentiell durch die normale
  `Worker.Recording.Pipeline` und misst pro Stage Wall-Clock-Dauer +
  Erfolg/Fehler-Kategorie.

  Am Ende publisht der GenServer ein `ProbelaufFinished`-Event mit dem
  gesamten Mess-Payload + Settings-Snapshot, danach `CampaignDeleted` für
  die Probelauf-Kampagne (Cleanup via Materializer-Cascade).

  ## Locking-Modell (post-#292 / #354)

  Zwei orthogonale Locks, beide notwendig:

  - **Probelauf-Lock** (`state.running != nil`, hier im Modul): „nur ein
    Probelauf-Auftrag gleichzeitig". UI-Schutz gegen Doppel-Klicks auf
    „Probelauf starten" / „Sweep starten". Kommt in vier Varianten
    (`start`, `start_sweep`, `start_sweep_isolated`,
    `start_sweep_isolated_param`) — jeder reserviert denselben
    `running`-Slot.
  - **GpuQueue-Lock** (`Worker.GpuQueue`, Issue #292): „nur ein
    GPU-schwerer Job gleichzeitig". Hardware-Schutz. Jede Pipeline-Stage
    die dieser Probelauf triggert läuft automatisch durch die Queue —
    dieses Modul interagiert nicht direkt mit der GpuQueue.

  Per-Stage-Timings kommen aus `Worker.Recording.Pipeline.notify_status/3`
  über den Worker.PubSub-Topic `"pipeline_status"`.
  """

  use GenServer
  require Logger

  alias Worker.{Intents, Recording, Repo, Settings}

  # Wie lange max. auf eine Pipeline-Stage warten, bevor die Probelauf-Engine
  # die Session als `:timeout` markiert und weitermacht. Großzügig, weil
  # Stage 3 mit 30B-Modellen auch >5min dauern kann.
  @stage_timeout_ms 15 * 60_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # ─── Public API ────────────────────────────────────────────────────

  @doc """
  Startet einen Probelauf für den angegebenen Admin. Returns:
  - `{:ok, run_id}` wenn losgelegt
  - `{:error, {:already_running, run_id}}` wenn schon einer läuft
  """
  @spec start(String.t()) :: {:ok, String.t()} | {:error, {:already_running, String.t()}}
  def start(started_by_discord_id) when is_binary(started_by_discord_id) do
    GenServer.call(__MODULE__, {:start, started_by_discord_id})
  end

  @doc """
  Startet einen LLM-Probelauf-Sweep (Issue #88, Phase 2a). Variiert genau
  EINE Stage durch eine Liste von Modellen — andere Stages bleiben auf
  ihrem aktuellen Default. Pro Modell ein voller Probelauf-Run
  (3 Sessions short/medium/long), alle mit gemeinsamer `sweep_id`.

  Returns:
  - `{:ok, sweep_id}` wenn losgelegt
  - `{:error, {:already_running, run_or_sweep_id}}` wenn schon ein Lauf da ist
  - `{:error, :invalid_stage}` / `{:error, :no_models}` bei ungültigen Args
  """
  @spec start_sweep(String.t(), 2 | 3 | 4, [String.t()]) ::
          {:ok, String.t()}
          | {:error, {:already_running, String.t()} | :invalid_stage | :no_models}
  def start_sweep(started_by, stage, models),
    do: start_sweep(started_by, stage, models, nil)

  @doc """
  Issue #284: erweitertes Sweep-Start mit `session_set` — wählt welche der
  Eval-Sessions (short/medium/long) gemessen werden. `nil` oder `[]` = alle.
  """
  @spec start_sweep(String.t(), 2 | 3 | 4, [String.t()], [String.t()] | nil) ::
          {:ok, String.t()}
          | {:error, {:already_running, String.t()} | :invalid_stage | :no_models}
  def start_sweep(started_by, stage, models, session_set)
      when is_binary(started_by) and stage in [2, 3, 4] and is_list(models) do
    cond do
      models == [] ->
        {:error, :no_models}

      true ->
        GenServer.call(
          __MODULE__,
          {:start_sweep, started_by, stage, models, session_set},
          60_000
        )
    end
  end

  def start_sweep(_started_by, _stage, _models, _session_set), do: {:error, :invalid_stage}

  @doc """
  Issue #262 (Phase 1c): Stage-isolierter Sweep gegen Goldstandard-Pre-Seed
  (Issue #201). Pro Modell läuft NUR die Ziel-Stage (statt voller Pipeline) auf
  den 3 Eval-Sessions (10/30/100 Utterances), Pre-Stage-Inputs kommen aus dem
  Goldstandard. Faithfulness-Score wird gegen Original-Utterances gemessen.

  Vorteil gegenüber start_sweep/3: ~3-5× schneller (keine Beifang-Stages) und
  fair vergleichbar für Stage 3+4 (jedes Modell sieht denselben Goldstandard-
  Input, kein Drift durch davor laufende Default-Stage).

  Returns:
  - `{:ok, sweep_id}` wenn losgelegt
  - `{:error, {:already_running, run_or_sweep_id}}` wenn schon ein Lauf da ist
  - `{:error, :invalid_stage}` / `{:error, :no_models}` bei ungültigen Args
  """
  @spec start_sweep_isolated(String.t(), 2 | 3 | 4, [String.t()]) ::
          {:ok, String.t()}
          | {:error, {:already_running, String.t()} | :invalid_stage | :no_models}
  def start_sweep_isolated(started_by, stage, models),
    do: start_sweep_isolated(started_by, stage, models, nil)

  @doc """
  Issue #284: erweitertes Isolated-Sweep-Start mit `session_set` — wählt
  welche der Eval-Sessions (short/medium/long) gemessen werden. `nil` oder
  `[]` = alle.
  """
  @spec start_sweep_isolated(String.t(), 2 | 3 | 4, [String.t()], [String.t()] | nil) ::
          {:ok, String.t()}
          | {:error, {:already_running, String.t()} | :invalid_stage | :no_models}
  def start_sweep_isolated(started_by, stage, models, session_set)
      when is_binary(started_by) and stage in [2, 3, 4] and is_list(models) do
    cond do
      models == [] ->
        {:error, :no_models}

      true ->
        GenServer.call(
          __MODULE__,
          {:start_sweep_isolated, started_by, stage, models, session_set},
          60_000
        )
    end
  end

  def start_sweep_isolated(_started_by, _stage, _models, _session_set),
    do: {:error, :invalid_stage}

  @doc """
  Issue #289 Phase 4: Stage-isolierter Param-Sweep — variiert
  `temperature_stageN` über eine Werte-Liste bei fixem Modell. Pro
  Temperatur eine Variante mit `"model"`-Label `"temperature=0.05"` (so
  bleibt der bestehende Aggregator/UI-Pfad ohne Änderungen).

  - `started_by` — Discord-ID des Auslösers.
  - `stage` — 2/3/4.
  - `temperatures` — Liste von Floats (z.B. `[0.05, 0.1, 0.15, 0.2]`).
  - `session_set` — wie bei start_sweep_isolated/4.
  """
  @spec start_sweep_isolated_param(String.t(), 2 | 3 | 4, [float()], [String.t()] | nil) ::
          {:ok, String.t()}
          | {:error,
             {:already_running, String.t()} | :invalid_stage | :no_temperatures}
  def start_sweep_isolated_param(started_by, stage, temperatures, session_set \\ nil)

  def start_sweep_isolated_param(started_by, stage, temperatures, session_set)
      when is_binary(started_by) and stage in [2, 3, 4] and is_list(temperatures) do
    cond do
      temperatures == [] ->
        {:error, :no_temperatures}

      true ->
        GenServer.call(
          __MODULE__,
          {:start_sweep_isolated_param, started_by, stage, temperatures, session_set},
          60_000
        )
    end
  end

  def start_sweep_isolated_param(_started_by, _stage, _temperatures, _session_set),
    do: {:error, :invalid_stage}

  @doc "Aktueller Run (oder nil)."
  @spec running() :: nil | map()
  def running, do: GenServer.call(__MODULE__, :running)

  # ─── GenServer-Callbacks ──────────────────────────────────────────

  @impl true
  def init(_) do
    {:ok, %{running: nil}}
  end

  @impl true
  def handle_call({:start, started_by}, _from, %{running: nil} = state) do
    run_id = UUIDv7.generate()
    settings = settings_snapshot()
    started_at = DateTime.utc_now()

    pid = self()
    Task.start(fn -> run_loop(run_id, started_by, settings, started_at, pid) end)

    {:reply, {:ok, run_id},
     %{state | running: %{run_id: run_id, started_by: started_by, started_at: started_at}}}
  end

  def handle_call({:start, _}, _from, %{running: run} = state) do
    {:reply, {:error, {:already_running, run_or_sweep_id(run)}}, state}
  end

  def handle_call(
        {:start_sweep, started_by, stage, models, session_set},
        _from,
        %{running: nil} = state
      ) do
    sweep_id = UUIDv7.generate()
    started_at = DateTime.utc_now()

    pid = self()

    Task.start(fn ->
      run_sweep_loop(sweep_id, started_by, stage, models, session_set, started_at, pid)
    end)

    {:reply, {:ok, sweep_id},
     %{
       state
       | running: %{
           type: :sweep,
           sweep_id: sweep_id,
           started_by: started_by,
           started_at: started_at,
           stage: stage,
           models: models,
           session_set: normalize_session_set(session_set),
           current_model: nil
         }
     }}
  end

  def handle_call({:start_sweep, _, _, _, _}, _from, %{running: run} = state) do
    {:reply, {:error, {:already_running, run_or_sweep_id(run)}}, state}
  end

  # Issue #262: Stage-isolierter Sweep
  def handle_call(
        {:start_sweep_isolated, started_by, stage, models, session_set},
        _from,
        %{running: nil} = state
      ) do
    sweep_id = UUIDv7.generate()
    started_at = DateTime.utc_now()

    pid = self()

    Task.start(fn ->
      run_sweep_isolated_loop(
        sweep_id,
        started_by,
        stage,
        models,
        session_set,
        started_at,
        pid
      )
    end)

    {:reply, {:ok, sweep_id},
     %{
       state
       | running: %{
           type: :sweep_isolated,
           sweep_id: sweep_id,
           started_by: started_by,
           started_at: started_at,
           stage: stage,
           models: models,
           session_set: normalize_session_set(session_set),
           current_model: nil
         }
     }}
  end

  def handle_call({:start_sweep_isolated, _, _, _, _}, _from, %{running: run} = state) do
    {:reply, {:error, {:already_running, run_or_sweep_id(run)}}, state}
  end

  # Issue #289 Phase 4: Param-Sweep über Temperature-Varianten.
  def handle_call(
        {:start_sweep_isolated_param, started_by, stage, temperatures, session_set},
        _from,
        %{running: nil} = state
      ) do
    sweep_id = UUIDv7.generate()
    started_at = DateTime.utc_now()

    pid = self()

    Task.start(fn ->
      run_sweep_isolated_param_loop(
        sweep_id,
        started_by,
        stage,
        temperatures,
        session_set,
        started_at,
        pid
      )
    end)

    # Pseudo-Modelle für die running-State damit das LV-Progress den
    # bestehenden current_model-Mechanismus weiter nutzen kann.
    pseudo_models = Enum.map(temperatures, &temperature_label/1)

    {:reply, {:ok, sweep_id},
     %{
       state
       | running: %{
           type: :sweep_isolated_param,
           sweep_id: sweep_id,
           started_by: started_by,
           started_at: started_at,
           stage: stage,
           models: pseudo_models,
           temperatures: temperatures,
           session_set: normalize_session_set(session_set),
           current_model: nil
         }
     }}
  end

  def handle_call({:start_sweep_isolated_param, _, _, _, _}, _from, %{running: run} = state) do
    {:reply, {:error, {:already_running, run_or_sweep_id(run)}}, state}
  end

  def handle_call(:running, _from, state), do: {:reply, state.running, state}

  def handle_call({:sweep_progress, sweep_id, model}, _from, state) do
    case state.running do
      %{sweep_id: ^sweep_id, models: models} = run ->
        # Issue #279: Beim Modell-Wechsel ein pipeline_status-Frame zum Hub
        # pushen, damit /admin/probelauf LiveView den aktuellen Stand
        # ohne Polling/Reload sieht.
        completed = Enum.find_index(models, &(&1 == model)) || 0

        Worker.HubClient.publish_status(%{
          "kind" => "probelauf_sweep_progress",
          "sweep_id" => sweep_id,
          "current_model" => model,
          "completed" => completed,
          "total" => length(models),
          "ts" => DateTime.utc_now() |> DateTime.to_iso8601()
        })

        {:reply, :ok, %{state | running: %{run | current_model: model}}}

      _ ->
        {:reply, :ignored, state}
    end
  end

  defp run_or_sweep_id(%{type: :sweep, sweep_id: sid}), do: sid
  defp run_or_sweep_id(%{type: :sweep_isolated, sweep_id: sid}), do: sid
  defp run_or_sweep_id(%{type: :sweep_isolated_param, sweep_id: sid}), do: sid
  defp run_or_sweep_id(%{run_id: rid}), do: rid

  # Issue #289 Phase 4: Label-Helper. Pro Temperature ein einheitlicher
  # String der im UI als "Modell-Name" der Variante angezeigt wird.
  defp temperature_label(t) when is_float(t) or is_integer(t),
    do: "temperature=#{t}"

  @impl true
  def handle_info({:run_done, id}, state) do
    case state.running do
      %{run_id: ^id} ->
        Logger.info("Probelauf: run #{id} cleared")
        {:noreply, %{state | running: nil}}

      %{sweep_id: ^id} ->
        Logger.info("Probelauf-Sweep: #{id} cleared")
        {:noreply, %{state | running: nil}}

      _ ->
        {:noreply, state}
    end
  end

  # ─── Probelauf-Loop (im Task ausgeführt) ──────────────────────────

  defp run_loop(run_id, started_by, settings, started_at, parent) do
    Phoenix.PubSub.subscribe(Worker.PubSub, "pipeline_status")
    do_single_run(run_id, started_by, settings, started_at, [])
    send(parent, {:run_done, run_id})
  end

  # Single Probelauf-Run: ProbelaufStarted → seed → measure → ProbelaufFinished
  # → CampaignDeleted cleanup. Pulled out from run_loop so the Sweep-Loop can
  # call it N× with shared sweep_id + sweep_variant tags.
  defp do_single_run(run_id, started_by, settings, started_at, opts) do
    sweep_id = Keyword.get(opts, :sweep_id)
    sweep_variant = Keyword.get(opts, :sweep_variant)
    session_set = Keyword.get(opts, :session_set)

    Logger.info(
      "Probelauf: starting run=#{run_id} by=#{started_by}" <>
        if(sweep_id, do: " sweep_id=#{sweep_id} variant=#{inspect(sweep_variant)}", else: "")
    )

    {:ok, _} =
      Intents.publish(
        %{
          "kind" => Shared.Events.probelauf_started(),
          "run_id" => run_id,
          "started_by" => started_by,
          "started_at" => DateTime.to_iso8601(started_at),
          "settings_snapshot" => settings
        }
        |> maybe_put_sweep(sweep_id, sweep_variant)
      )

    campaign_id = "probelauf-" <> run_id
    owner = Repo.get_state(:admin_discord_id) || started_by

    sessions = seed(campaign_id, owner, session_set)

    metrics =
      sessions
      |> Enum.map(fn s -> measure_session(s, campaign_id) end)

    {:ok, _} =
      Intents.publish(
        %{
          "kind" => Shared.Events.probelauf_finished(),
          "run_id" => run_id,
          "started_by" => started_by,
          "finished_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "sessions" => metrics,
          "settings_snapshot" => settings
        }
        |> maybe_put_sweep(sweep_id, sweep_variant)
      )

    # Cleanup: Cascade-Delete der Probelauf-Campaign (Materializer kaskadiert).
    {:ok, _} =
      Intents.publish(%{
        "kind" => Shared.Events.campaign_deleted(),
        "campaign_id" => campaign_id,
        "deleted_by" => "probelauf-cleanup"
      })

    Logger.info("Probelauf: run #{run_id} finished + cleaned up")
  end

  defp maybe_put_sweep(payload, nil, _), do: payload

  defp maybe_put_sweep(payload, sweep_id, sweep_variant) do
    payload
    |> Map.put("sweep_id", sweep_id)
    |> Map.put("sweep_variant", normalize_variant(sweep_variant))
  end

  defp normalize_variant(%{stage: stage, model: model}),
    do: %{"stage" => stage, "model" => model}

  defp normalize_variant(other), do: other

  # ─── Sweep-Loop (Phase 2a, Issue #88) ─────────────────────────────

  defp run_sweep_loop(sweep_id, started_by, stage, models, session_set, started_at, parent) do
    session_set = normalize_session_set(session_set)

    Logger.info(
      "Probelauf-Sweep starting sweep_id=#{sweep_id} stage=#{stage} models=#{inspect(models)} session_set=#{inspect(session_set)}"
    )

    Phoenix.PubSub.subscribe(Worker.PubSub, "pipeline_status")

    setting_key = String.to_atom("model_stage#{stage}")
    default_model = Settings.get(setting_key)

    {:ok, _} =
      Intents.publish(%{
        "kind" => Shared.Events.probelauf_sweep_started(),
        "sweep_id" => sweep_id,
        "stage" => stage,
        "models" => models,
        "default_model" => default_model,
        "session_set" => session_set,
        "started_by" => started_by,
        "started_at" => DateTime.to_iso8601(started_at)
      })

    try do
      Enum.each(models, fn model ->
        Logger.info("Probelauf-Sweep #{sweep_id}: variant stage#{stage}=#{model}")
        :ok = Settings.put(setting_key, model)
        _ = GenServer.call(__MODULE__, {:sweep_progress, sweep_id, model})

        do_single_run(
          UUIDv7.generate(),
          started_by,
          settings_snapshot(),
          DateTime.utc_now(),
          sweep_id: sweep_id,
          sweep_variant: %{stage: stage, model: model},
          session_set: session_set
        )
      end)
    after
      # Always restore the user's default model — even if an iteration crashed.
      Settings.put(setting_key, default_model)
    end

    {:ok, _} =
      Intents.publish(%{
        "kind" => Shared.Events.probelauf_sweep_finished(),
        "sweep_id" => sweep_id,
        "session_set" => session_set,
        "finished_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      })

    Logger.info("Probelauf-Sweep #{sweep_id} done — default model #{default_model} restored")
    send(parent, {:run_done, sweep_id})
  end

  # ─── Seed (Sessions short/medium/long, gefiltert per session_set) ─

  defp seed(campaign_id, owner, session_set) do
    {:ok, _} =
      Intents.publish(%{
        "kind" => Shared.Events.campaign_created(),
        "id" => campaign_id,
        "name" => "LLM-Probelauf #{String.slice(campaign_id, -8, 8)}",
        "icon_url" => nil,
        "theme_blurb" =>
          "Automatischer Smoke-Test (Issue #74). Wird nach Abschluss automatisch gelöscht.",
        "owner_discord_id" => owner,
        "owner_display_name" => "Probelauf",
        # Marker für Hub.Reader-Filter — Dashboards ignorieren Probelauf-Campaigns.
        "probelauf" => true
      })

    session_set_specs(session_set)
    |> Enum.map(fn {_tag, num, utts} -> seed_session(campaign_id, owner, num, utts) end)
  end

  # Issue #284: liefert die zu seedenden/messenden {tag, number, utterances}-Tupel
  # gefiltert nach session_set. `nil` / `[]` heißt alle 3.
  defp session_set_specs(nil), do: all_session_specs()
  defp session_set_specs([]), do: all_session_specs()

  defp session_set_specs(set_list) when is_list(set_list) do
    set_set = MapSet.new(set_list)

    Enum.filter(all_session_specs(), fn {tag, _num, _utts} ->
      MapSet.member?(set_set, tag)
    end)
  end

  defp all_session_specs do
    [
      {"short", 1, short_utterances()},
      {"medium", 2, medium_utterances()},
      {"long", 3, long_utterances()},
      {"real", 4, real_utterances()}
    ]
  end

  # Issue #284: normalisiert die session_set-Eingabe für State + Event-Payload.
  # Akzeptiert `nil`, leere Liste, Strings oder Atoms — gibt sortierte Stringliste
  # zurück (z.B. ["long", "short"] für den Set {"short", "long"}).
  defp normalize_session_set(nil), do: ["short", "medium", "long"]
  defp normalize_session_set([]), do: ["short", "medium", "long"]

  defp normalize_session_set(list) when is_list(list) do
    list
    |> Enum.map(fn
      a when is_atom(a) -> Atom.to_string(a)
      s when is_binary(s) -> s
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&(&1 in ["short", "medium", "long", "real"]))
    |> Enum.uniq()
    |> Enum.sort()
  end

  # Issue #284: filtert die seed_eval_campaign-Sessions auf das session_set.
  # Mapping: "short" → number 1, "medium" → 2, "long" → 3.
  # Issue #286: "real" → 4.
  defp filter_eval_sessions(sessions, session_set) do
    numbers =
      session_set
      |> Enum.map(fn
        "short" -> 1
        "medium" -> 2
        "long" -> 3
        "real" -> 4
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    Enum.filter(sessions, fn s -> MapSet.member?(numbers, s.number) end)
  end

  defp seed_session(campaign_id, owner, num, texts) do
    sid = UUIDv7.generate()

    {:ok, _} =
      Intents.publish(%{
        "kind" => Shared.Events.session_scheduled(),
        "id" => sid,
        "campaign_id" => campaign_id,
        "number" => num,
        "name" => "Probelauf-Session #{num} (#{length(texts)} Utterances)",
        "scheduled_for" => DateTime.utc_now() |> DateTime.to_iso8601()
      })

    Enum.with_index(texts, fn text, i ->
      {:ok, _} =
        Intents.publish(%{
          "kind" => Shared.Events.utterance_appended(),
          "id" => "u-#{sid}-#{i}",
          "session_id" => sid,
          "discord_id" => owner,
          "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "text" => text,
          # Issue #376: einheitliches Map-Format (vorher Float 1.0).
          "confidence" => Worker.Recording.Transcribe.to_confidence_map(1.0),
          "status" => "confirmed"
        })
    end)

    %{number: num, session_id: sid, utterance_count: length(texts)}
  end

  # ─── Mess-Logik pro Session ──────────────────────────────────────

  defp measure_session(session, campaign_id) do
    Logger.info("Probelauf: triggering session #{session.number} (#{session.utterance_count} utts)")

    # Flush stale messages aus früheren Sessions
    flush_pipeline_messages()

    # Direkter Pipeline-Call statt RegenerateRequested-Event-Roundtrip.
    :ok = Recording.Pipeline.run_for_session(session.session_id)

    stage_metrics = collect_stages(campaign_id, %{})

    %{
      number: session.number,
      session_id: session.session_id,
      utterance_count: session.utterance_count,
      stages: stage_metrics
    }
  end

  # Empfängt {:pipeline_stage, payload}-Messages aus dem Worker.PubSub
  # bis Stage 4 mit Status "ended" oder "failed" durchgegangen ist.
  # Pro Stage: timestamp-pair (started, ended), Outcome.
  defp collect_stages(campaign_id, acc) do
    receive do
      {:pipeline_stage,
       %{"campaign_id" => ^campaign_id, "stage" => stage, "status" => status, "ts" => ts_iso}} ->
        ts = parse_ts(ts_iso) || DateTime.utc_now()
        acc = record(acc, stage, status, ts)

        if stage == "stage4" and status in ["ended", "failed"] do
          finalize(acc, campaign_id)
        else
          collect_stages(campaign_id, acc)
        end

      {:pipeline_stage, _} ->
        # andere Campaign — ignorieren
        collect_stages(campaign_id, acc)
    after
      @stage_timeout_ms ->
        finalize(Map.put(acc, :__timeout__, true), campaign_id)
    end
  end

  defp record(acc, stage, "started", ts), do: Map.put(acc, {stage, :start}, ts)

  defp record(acc, stage, status, ts) when status in ["ended", "failed"] do
    acc
    |> Map.put({stage, :stop}, ts)
    |> Map.put({stage, :outcome_raw}, status)
  end

  defp record(acc, _stage, _status, _ts), do: acc

  defp finalize(acc, campaign_id) do
    timeout? = Map.get(acc, :__timeout__, false)

    Enum.into(["stage2", "stage3", "stage4"], %{}, fn stage ->
      {stage, stage_metric(acc, stage, timeout?, campaign_id)}
    end)
  end

  defp stage_metric(acc, stage, timeout?, campaign_id) do
    start = Map.get(acc, {stage, :start})
    stop = Map.get(acc, {stage, :stop})
    outcome_raw = Map.get(acc, {stage, :outcome_raw})

    duration_ms =
      if start && stop, do: DateTime.diff(stop, start, :millisecond), else: nil

    outcome = classify_outcome(stage, outcome_raw, timeout?, campaign_id)
    output_bytes = output_size(stage, campaign_id)

    %{
      duration_ms: duration_ms,
      outcome: Atom.to_string(outcome),
      output_bytes: output_bytes
    }
  end

  defp classify_outcome(_stage, nil, true, _cid), do: :timeout
  defp classify_outcome(_stage, nil, false, _cid), do: :other_error
  defp classify_outcome(_stage, "ended", _, _cid), do: :ok

  defp classify_outcome("stage4", "failed", _, cid) do
    # Stage 4 hat eigene Failure-Codes — wenn Chronik leer ist, ist es
    # :empty_output (siehe Pipeline.stage4_publish/2 für [] → :empty_chronik).
    if Repo.list_chronik_entries(cid) == [], do: :empty_output, else: :other_error
  end

  defp classify_outcome(_stage, "failed", _, _cid), do: :other_error

  defp output_size("stage2", cid) do
    cid
    |> Repo.list_session_summaries()
    |> Enum.map(&byte_size(&1.content_md || ""))
    |> Enum.sum()
  end

  defp output_size("stage3", cid) do
    case Repo.get_epos_entry(cid) do
      nil -> 0
      e -> byte_size(e.content_md || "")
    end
  end

  defp output_size("stage4", cid), do: Repo.list_chronik_entries(cid) |> length()

  # ─── Helpers ─────────────────────────────────────────────────────

  defp settings_snapshot do
    keys = ~w(model_stage2 model_stage3 model_stage4
              ctx_stage2 ctx_stage3 ctx_stage4
              http_timeout_ms local_endpoint)a

    Enum.into(keys, %{}, fn k -> {Atom.to_string(k), Settings.get(k)} end)
  end

  defp parse_ts(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_ts(_), do: nil

  defp flush_pipeline_messages do
    receive do
      {:pipeline_stage, _} -> flush_pipeline_messages()
    after
      0 -> :ok
    end
  end

  # ─── Seed-Texte (hartkodiert, fiktive deutsche RPG-Szenen) ───────

  defp short_utterances do
    [
      "Wir betreten die verlassene Schenke. Der Wirt sieht uns misstrauisch an.",
      "Ich frage ihn nach dem verschwundenen Karawanenboten.",
      "Er nuschelt etwas von Banditen im Schwarzen Wald.",
      "Mein Halbork zückt die Streitaxt und legt eine Goldmünze auf den Tresen.",
      "Der Wirt wird redseliger. Er nennt einen Namen: Gardal der Krummbein.",
      "Wir bedanken uns und ziehen nordwärts.",
      "Auf dem Weg sehe ich Hufabdrücke — vier Reiter, zwei Tage alt.",
      "Die Elfin schleicht voraus, kundschaftet die nächste Lichtung aus.",
      "Sie kommt zurück: drei Banditen am Lagerfeuer, schlafend.",
      "Wir schleichen uns an. Stille, dann ein scharfer Pfiff — die Elfin gibt das Zeichen."
    ]
  end

  defp medium_utterances do
    Enum.flat_map(1..3, fn ep -> Enum.map(short_utterances(), &"[Episode #{ep}] #{&1}") end)
  end

  defp long_utterances do
    Enum.flat_map(1..10, fn ep -> Enum.map(short_utterances(), &"[Tag #{ep}] #{&1}") end)
  end

  # Issue #286: 4. Eval-Session-Größe „real" — lädt die Corbett-House-Story aus
  # priv/probelauf-eval/session-4-utterances.jsonl (~800 Whisper-anmutende Utts
  # einer kompletten CoC-Investigation, gebaut aus echtem CoC-Session-1/2-Material).
  # Anders als short/medium/long-Utterances nicht hardcoded, sondern aus dem
  # committed JSONL-Asset. JSONL-Format pro Zeile: %{"text", "discord_id"} —
  # discord_id wird hier ignoriert (für Eval-Stages reicht der Text), wird aber
  # vom `lore.seed.coc_demo`-Mix-Task übernommen damit die Test-Stage-Kampagne
  # mehrere Sprecher zeigt.
  defp real_utterances do
    Application.app_dir(:worker, ["priv", "probelauf-eval"])
    |> Path.join("session-4-utterances.jsonl")
    |> File.stream!()
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == ""))
    |> Stream.map(&Jason.decode!/1)
    |> Enum.map(& &1["text"])
  end

  # ─── Issue #262: Stage-isolierter Sweep-Loop ───────────────────────

  defp run_sweep_isolated_loop(
         sweep_id,
         started_by,
         stage,
         models,
         session_set,
         started_at,
         parent
       ) do
    session_set = normalize_session_set(session_set)

    Logger.info(
      "Probelauf-Sweep-Isolated starting sweep_id=#{sweep_id} stage=#{stage} models=#{inspect(models)} session_set=#{inspect(session_set)}"
    )

    Phoenix.PubSub.subscribe(Worker.PubSub, "pipeline_status")

    setting_key = String.to_atom("model_stage#{stage}")
    default_model = Settings.get(setting_key)

    # Goldstandard-Eval-Kampagne idempotent seeden
    {:ok, %{campaign_id: cid, sessions: all_sessions}} = seed_eval_campaign()

    # Issue #284: nur die im session_set ausgewählten Sessions messen.
    sessions = filter_eval_sessions(all_sessions, session_set)

    {:ok, _} =
      Intents.publish(%{
        "kind" => Shared.Events.probelauf_sweep_started(),
        "sweep_id" => sweep_id,
        "stage" => stage,
        "models" => models,
        "default_model" => default_model,
        "session_set" => session_set,
        "isolated" => true,
        "campaign_id" => cid,
        "started_by" => started_by,
        "started_at" => DateTime.to_iso8601(started_at)
      })

    variants =
      try do
        Enum.map(models, fn model ->
          Logger.info("Probelauf-Sweep-Isolated #{sweep_id}: variant stage#{stage}=#{model}")
          :ok = Settings.put(setting_key, model)
          _ = GenServer.call(__MODULE__, {:sweep_progress, sweep_id, model})

          per_session = Enum.map(sessions, fn s -> measure_isolated_stage(s, cid, stage) end)

          variant = %{"model" => model, "sessions" => per_session}

          # Issue #281b: Live-Push der fertig gemessenen Variante, damit das
          # /admin/probelauf LV die Sweep-Tabelle schon während des Laufs
          # zeilenweise aufbauen kann statt erst nach SweepFinished.
          Worker.HubClient.publish_status(%{
            "kind" => "probelauf_sweep_variant_done",
            "sweep_id" => sweep_id,
            "stage" => stage,
            "variant" => variant,
            "ts" => DateTime.utc_now() |> DateTime.to_iso8601()
          })

          variant
        end)
      after
        # Always restore the user's default model — even if an iteration crashed.
        Settings.put(setting_key, default_model)
      end

    {:ok, _} =
      Intents.publish(%{
        "kind" => Shared.Events.probelauf_sweep_finished(),
        "sweep_id" => sweep_id,
        "isolated" => true,
        "stage" => stage,
        "session_set" => session_set,
        "variants" => variants,
        "finished_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      })

    Logger.info(
      "Probelauf-Sweep-Isolated #{sweep_id} done — default model #{default_model} restored"
    )

    send(parent, {:run_done, sweep_id})
  end

  # Issue #289 Phase 4: Param-Sweep-Loop. Iteriert temperatures statt
  # Modelle. Setzt `temperature_stageN` pro Variante, restored am Ende.
  defp run_sweep_isolated_param_loop(
         sweep_id,
         started_by,
         stage,
         temperatures,
         session_set,
         started_at,
         parent
       ) do
    session_set = normalize_session_set(session_set)

    Logger.info(
      "Probelauf-Sweep-Isolated-Param starting sweep_id=#{sweep_id} stage=#{stage} " <>
        "temperatures=#{inspect(temperatures)} session_set=#{inspect(session_set)}"
    )

    Phoenix.PubSub.subscribe(Worker.PubSub, "pipeline_status")

    temp_key = String.to_atom("temperature_stage#{stage}")
    default_temp = Settings.get(temp_key)

    # Fixed model = aktuelles Default-Modell für die Stage. Im UI ist
    # dieser Wert sichtbar (Modell-Pille pro Variante).
    model_key = String.to_atom("model_stage#{stage}")
    fixed_model = Settings.get(model_key)

    {:ok, %{campaign_id: cid, sessions: all_sessions}} = seed_eval_campaign()
    sessions = filter_eval_sessions(all_sessions, session_set)

    pseudo_models = Enum.map(temperatures, &temperature_label/1)

    {:ok, _} =
      Intents.publish(%{
        "kind" => Shared.Events.probelauf_sweep_started(),
        "sweep_id" => sweep_id,
        "stage" => stage,
        "models" => pseudo_models,
        "default_model" => fixed_model,
        "session_set" => session_set,
        "isolated" => true,
        "param" => "temperature",
        "param_values" => temperatures,
        "campaign_id" => cid,
        "started_by" => started_by,
        "started_at" => DateTime.to_iso8601(started_at)
      })

    variants =
      try do
        Enum.map(temperatures, fn temp ->
          label = temperature_label(temp)

          Logger.info(
            "Probelauf-Sweep-Isolated-Param #{sweep_id}: variant stage#{stage} #{temp_key}=#{temp}"
          )

          :ok = Settings.put(temp_key, temp)
          _ = GenServer.call(__MODULE__, {:sweep_progress, sweep_id, label})

          per_session = Enum.map(sessions, fn s -> measure_isolated_stage(s, cid, stage) end)

          variant = %{
            "model" => label,
            "sessions" => per_session,
            "param" => "temperature",
            "value" => temp
          }

          Worker.HubClient.publish_status(%{
            "kind" => "probelauf_sweep_variant_done",
            "sweep_id" => sweep_id,
            "stage" => stage,
            "variant" => variant,
            "ts" => DateTime.utc_now() |> DateTime.to_iso8601()
          })

          variant
        end)
      after
        Settings.put(temp_key, default_temp)
      end

    {:ok, _} =
      Intents.publish(%{
        "kind" => Shared.Events.probelauf_sweep_finished(),
        "sweep_id" => sweep_id,
        "isolated" => true,
        "stage" => stage,
        "session_set" => session_set,
        "variants" => variants,
        "param" => "temperature",
        "finished_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      })

    Logger.info(
      "Probelauf-Sweep-Isolated-Param #{sweep_id} done — #{temp_key} #{default_temp} restored"
    )

    send(parent, {:run_done, sweep_id})
  end

  defp measure_isolated_stage(session, campaign_id, stage) do
    Logger.info(
      "Probelauf-Isolated: triggering stage#{stage} on session #{session.number} (#{session.utterance_count} utts)"
    )

    flush_pipeline_messages()
    :ok = Recording.Pipeline.run_for_session(session.session_id, only_stages: [stage])

    stage_str = "stage#{stage}"
    stage_metric = collect_single_stage(campaign_id, stage_str)
    faithfulness = compute_faithfulness(stage, session.session_id, campaign_id)

    %{
      "number" => session.number,
      "session_id" => session.session_id,
      "utterance_count" => session.utterance_count,
      "stage" => stage_str,
      "duration_ms" => stage_metric.duration_ms,
      "outcome" => stage_metric.outcome,
      "output_bytes" => stage_metric.output_bytes,
      "faithfulness_score" => faithfulness,
      # Issue #288: Format-Notes pro Session ins Sweep-Result. Hub-Side-
      # Aggregator (sweep_aggregator.ex) leitet daraus pro Variante das
      # format_issue-Feld ab.
      "format_notes" => stage_metric.format_notes
    }
  end

  # Wartet nur auf den Ziel-Stage (started + ended/failed) statt auf alle 3.
  defp collect_single_stage(campaign_id, target_stage, acc \\ %{}) do
    receive do
      {:pipeline_stage,
       %{
         "campaign_id" => ^campaign_id,
         "stage" => ^target_stage,
         "status" => status,
         "ts" => ts_iso
       } = ev} ->
        ts = parse_ts(ts_iso) || DateTime.utc_now()
        acc = record(acc, target_stage, status, ts)
        # Issue #288: format_notes aus dem Stage-Event in den Akkumulator
        # mitnehmen, damit stage_metric_isolated es ins Result-Map packen
        # kann. Wert kommt nur bei "ended"/"failed".
        acc =
          case Map.get(ev, "format_notes") do
            notes when is_binary(notes) -> Map.put(acc, {target_stage, :format_notes}, notes)
            _ -> acc
          end

        if status in ["ended", "failed"] do
          stage_metric_isolated(acc, target_stage, false, campaign_id)
        else
          collect_single_stage(campaign_id, target_stage, acc)
        end

      {:pipeline_stage, _} ->
        # andere Campaign oder andere Stage — ignorieren
        collect_single_stage(campaign_id, target_stage, acc)
    after
      @stage_timeout_ms ->
        stage_metric_isolated(acc, target_stage, true, campaign_id)
    end
  end

  defp stage_metric_isolated(acc, stage, timeout?, campaign_id) do
    start = Map.get(acc, {stage, :start})
    stop = Map.get(acc, {stage, :stop})
    outcome_raw = Map.get(acc, {stage, :outcome_raw})

    duration_ms = if start && stop, do: DateTime.diff(stop, start, :millisecond), else: nil
    outcome = classify_outcome(stage, outcome_raw, timeout?, campaign_id)
    # Issue #288: bei Timeout (kein Stage-Event durchgekommen) hat der
    # Worker auch keine format_notes geliefert — explizit als "timeout"
    # markieren damit die UI das vom "ok" unterscheiden kann.
    format_notes =
      cond do
        timeout? -> "timeout"
        true -> Map.get(acc, {stage, :format_notes}, "ok")
      end

    %{
      duration_ms: duration_ms,
      outcome: Atom.to_string(outcome),
      output_bytes: output_size(stage, campaign_id),
      format_notes: format_notes
    }
  end

  # Faithfulness-Score gegen Original-Utterances. Stage-Output kommt aus dem
  # Repo (frisch nach dem isolierten Stage-Run); Utterance-Set ist stage-
  # spezifisch: Stage 2 + 4 vergleichen gegen die Utterances der gemessenen
  # Session, Stage 3 (Epos) ist campaign-weit und muss gegen ALLE
  # Utterances der Kampagne vergleichen (sonst NLI-Score systematisch zu
  # niedrig — die Quelle ist nur ein Teilset). Issue #290.
  defp compute_faithfulness(2, session_id, _campaign_id) do
    utterances = session_utterances(session_id)
    run_faithfulness(read_stage_output(2, session_id), utterances)
  end

  defp compute_faithfulness(3, _session_id, campaign_id) do
    utterances =
      campaign_id
      |> Repo.list_sessions()
      |> Enum.flat_map(fn s -> Repo.list_utterances(s.session_id) end)
      |> Enum.map(&%{"text" => &1.text})

    run_faithfulness(read_stage_output(3, campaign_id), utterances)
  end

  defp compute_faithfulness(4, session_id, campaign_id) do
    utterances = session_utterances(session_id)
    run_faithfulness(read_stage_output(4, session_id, campaign_id), utterances)
  end

  defp session_utterances(session_id) do
    session_id
    |> Repo.list_utterances()
    |> Enum.map(&%{"text" => &1.text})
  end

  defp run_faithfulness(generated_md, utterances) do
    generated_md = generated_md || ""

    case Worker.LLM.Faithfulness.score(generated_md, utterances) do
      {:ok, %{score: score}} ->
        score

      {:error, :sidecar_offline} ->
        # Issue #281b: lokaler Probelauf hat oft keinen NLI-Sidecar — wir
        # fallen auf den Trigram-Coverage-Score zurück, damit die Qualitäts-
        # Spalte nicht überall „—" zeigt. Der Proxy ist gut genug um
        # Token-Collapse / Wortsalat von brauchbarem Output zu trennen.
        Worker.LLM.Faithfulness.coverage_score(generated_md, utterances)

      {:error, _reason} ->
        nil
    end
  end

  defp read_stage_output(2, session_id) do
    case Repo.get_session_summary(session_id) do
      %{content_md: md} -> md
      _ -> nil
    end
  end

  defp read_stage_output(3, campaign_id) do
    # Epos ist campaign-weit, nicht session-spezifisch. Issue #290: nutzt
    # den übergebenen campaign_id, nicht hardcoded eval_campaign_id().
    case Repo.get_epos_entry(campaign_id) do
      %{content_md: md} -> md
      _ -> nil
    end
  end

  defp read_stage_output(4, session_id, campaign_id) do
    # Chronik-Einträge der Session als ein zusammengefügtes Markdown-Pseudo.
    # Issue #290: nutzt den übergebenen campaign_id, nicht hardcoded
    # eval_campaign_id().
    campaign_id
    |> Repo.list_chronik_entries()
    |> Enum.filter(&(&1.session_id == session_id))
    |> Enum.map_join("\n\n", fn e -> "## #{e.in_game_date} — #{e.label}\n\n#{e.summary}" end)
  end

  # ─── Issue #201: Goldstandard-Pre-Seed für isolierte Stage-Sweeps ──

  @eval_campaign_id "probelauf-eval-goldstandard"
  @eval_session_ids %{
    1 => "probelauf-eval-session-1",
    2 => "probelauf-eval-session-2",
    3 => "probelauf-eval-session-3",
    4 => "probelauf-eval-session-4"
  }

  @doc """
  Issue #201: lädt den committed Goldstandard-Asset aus
  `apps/worker/priv/probelauf-eval/` und seedet eine vorbereitete Eval-
  Kampagne mit allen 4 Stage-Outputs (utterances + summary + epos +
  chronik). Idempotent — Materializer überschreibt existing Outputs via
  LWW.

  Returns `{:ok, %{campaign_id, sessions: [%{number, session_id, utterance_count}]}}`.
  """
  @spec seed_eval_campaign() :: {:ok, map()}
  def seed_eval_campaign do
    {:ok, _} =
      Intents.publish(%{
        "kind" => Shared.Events.campaign_created(),
        "id" => @eval_campaign_id,
        "name" => "Probelauf-Eval Goldstandard",
        "icon_url" => nil,
        "theme_blurb" =>
          "Goldstandard-Pre-Seed für isolierte Stage-Sweeps (Issue #201). " <>
            "Wird nicht automatisch gelöscht — Asset lebt in priv/probelauf-eval/.",
        "owner_discord_id" => Repo.get_state(:admin_discord_id) || "probelauf-eval-system",
        "owner_display_name" => "Probelauf-Eval",
        "probelauf" => true
      })

    sessions =
      [
        {1, short_utterances()},
        {2, medium_utterances()},
        {3, long_utterances()},
        {4, real_utterances()}
      ]
      |> Enum.map(fn {num, utterances} -> seed_eval_session(num, utterances) end)

    {:ok, %{campaign_id: @eval_campaign_id, sessions: sessions}}
  end

  @doc "Liefert die fixe Eval-Campaign-ID."
  @spec eval_campaign_id() :: String.t()
  def eval_campaign_id, do: @eval_campaign_id

  @doc "Liefert die fixe Eval-Session-ID für Session-Nummer 1/2/3."
  @spec eval_session_id(1 | 2 | 3) :: String.t()
  def eval_session_id(num) when num in [1, 2, 3, 4], do: Map.fetch!(@eval_session_ids, num)

  defp seed_eval_session(num, utterances) do
    sid = Map.fetch!(@eval_session_ids, num)
    asset_dir = Application.app_dir(:worker, ["priv", "probelauf-eval"])

    {:ok, _} =
      Intents.publish(%{
        "kind" => Shared.Events.session_scheduled(),
        "id" => sid,
        "campaign_id" => @eval_campaign_id,
        "number" => num,
        "name" => "Eval Session #{num} (#{length(utterances)} Utterances)",
        "scheduled_for" => DateTime.utc_now() |> DateTime.to_iso8601()
      })

    # Stage-1-Equivalent: Utterances als bereits-transkribiert publishen
    Enum.with_index(utterances, fn text, i ->
      {:ok, _} =
        Intents.publish(%{
          "kind" => Shared.Events.utterance_appended(),
          "id" => "u-#{sid}-#{i}",
          "session_id" => sid,
          "discord_id" => "probelauf-eval-system",
          "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "text" => text,
          # Issue #376: einheitliches Map-Format (vorher Float 1.0).
          "confidence" => Worker.Recording.Transcribe.to_confidence_map(1.0),
          "status" => "confirmed"
        })
    end)

    # Stage-2 Goldstandard
    summary_md = File.read!(Path.join(asset_dir, "session-#{num}-summary.md"))

    {:ok, _} =
      Intents.publish(%{
        "kind" => Shared.Events.session_summary_generated(),
        "session_id" => sid,
        "campaign_id" => @eval_campaign_id,
        "content_md" => String.trim(summary_md),
        "source" => "goldstandard"
      })

    # Stage-3 Goldstandard (epos pro campaign — wird vom letzten Session-Seed gewinnen
    # weil LWW auf updated_at; das ist OK weil Session 3 die längste/finalste ist).
    epos_md = File.read!(Path.join(asset_dir, "session-#{num}-epos.md"))

    {:ok, _} =
      Intents.publish(%{
        "kind" => Shared.Events.epos_entry_edited(),
        "entry_id" => @eval_campaign_id,
        "campaign_id" => @eval_campaign_id,
        "new_md" => String.trim(epos_md),
        "edited_by" => "goldstandard",
        "source" => "goldstandard"
      })

    # Stage-4 Goldstandard
    chronik =
      asset_dir
      |> Path.join("session-#{num}-chronik.json")
      |> File.read!()
      |> Jason.decode!()

    Enum.each(chronik, fn entry ->
      {:ok, _} =
        Intents.publish(%{
          "kind" => Shared.Events.chronik_entry_changed(),
          "id" => "chronik-eval-#{sid}-#{:erlang.phash2(entry)}",
          "campaign_id" => @eval_campaign_id,
          "session_id" => sid,
          "in_game_date" => entry["in_game_date"],
          "label" => entry["label"],
          "summary" => entry["summary"]
        })
    end)

    %{number: num, session_id: sid, utterance_count: length(utterances)}
  end
end
