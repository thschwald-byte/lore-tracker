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

  Lock: nur ein Probelauf gleichzeitig (`state.running`).

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
  def start_sweep(started_by, stage, models)
      when is_binary(started_by) and stage in [2, 3, 4] and is_list(models) do
    cond do
      models == [] -> {:error, :no_models}
      true -> GenServer.call(__MODULE__, {:start_sweep, started_by, stage, models}, 60_000)
    end
  end

  def start_sweep(_started_by, _stage, _models), do: {:error, :invalid_stage}

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
  def start_sweep_isolated(started_by, stage, models)
      when is_binary(started_by) and stage in [2, 3, 4] and is_list(models) do
    cond do
      models == [] -> {:error, :no_models}
      true -> GenServer.call(__MODULE__, {:start_sweep_isolated, started_by, stage, models}, 60_000)
    end
  end

  def start_sweep_isolated(_started_by, _stage, _models), do: {:error, :invalid_stage}

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

  def handle_call({:start_sweep, started_by, stage, models}, _from, %{running: nil} = state) do
    sweep_id = UUIDv7.generate()
    started_at = DateTime.utc_now()

    pid = self()

    Task.start(fn ->
      run_sweep_loop(sweep_id, started_by, stage, models, started_at, pid)
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
           current_model: nil
         }
     }}
  end

  def handle_call({:start_sweep, _started_by, _stage, _models}, _from, %{running: run} = state) do
    {:reply, {:error, {:already_running, run_or_sweep_id(run)}}, state}
  end

  # Issue #262: Stage-isolierter Sweep
  def handle_call(
        {:start_sweep_isolated, started_by, stage, models},
        _from,
        %{running: nil} = state
      ) do
    sweep_id = UUIDv7.generate()
    started_at = DateTime.utc_now()

    pid = self()

    Task.start(fn ->
      run_sweep_isolated_loop(sweep_id, started_by, stage, models, started_at, pid)
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
           current_model: nil
         }
     }}
  end

  def handle_call({:start_sweep_isolated, _, _, _}, _from, %{running: run} = state) do
    {:reply, {:error, {:already_running, run_or_sweep_id(run)}}, state}
  end

  def handle_call(:running, _from, state), do: {:reply, state.running, state}

  def handle_call({:sweep_progress, sweep_id, model}, _from, state) do
    case state.running do
      %{sweep_id: ^sweep_id} = run ->
        {:reply, :ok, %{state | running: %{run | current_model: model}}}

      _ ->
        {:reply, :ignored, state}
    end
  end

  defp run_or_sweep_id(%{type: :sweep, sweep_id: sid}), do: sid
  defp run_or_sweep_id(%{type: :sweep_isolated, sweep_id: sid}), do: sid
  defp run_or_sweep_id(%{run_id: rid}), do: rid

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

    sessions = seed(campaign_id, owner)

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

  defp run_sweep_loop(sweep_id, started_by, stage, models, started_at, parent) do
    Logger.info(
      "Probelauf-Sweep starting sweep_id=#{sweep_id} stage=#{stage} models=#{inspect(models)}"
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
          sweep_variant: %{stage: stage, model: model}
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
        "finished_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      })

    Logger.info("Probelauf-Sweep #{sweep_id} done — default model #{default_model} restored")
    send(parent, {:run_done, sweep_id})
  end

  # ─── Seed (3 Sessions, short/medium/long Prompts) ────────────────

  defp seed(campaign_id, owner) do
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

    [
      seed_session(campaign_id, owner, 1, short_utterances()),
      seed_session(campaign_id, owner, 2, medium_utterances()),
      seed_session(campaign_id, owner, 3, long_utterances())
    ]
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
          "confidence" => 1.0,
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

  # ─── Issue #262: Stage-isolierter Sweep-Loop ───────────────────────

  defp run_sweep_isolated_loop(sweep_id, started_by, stage, models, started_at, parent) do
    Logger.info(
      "Probelauf-Sweep-Isolated starting sweep_id=#{sweep_id} stage=#{stage} models=#{inspect(models)}"
    )

    Phoenix.PubSub.subscribe(Worker.PubSub, "pipeline_status")

    setting_key = String.to_atom("model_stage#{stage}")
    default_model = Settings.get(setting_key)

    # Goldstandard-Eval-Kampagne idempotent seeden
    {:ok, %{campaign_id: cid, sessions: sessions}} = seed_eval_campaign()

    {:ok, _} =
      Intents.publish(%{
        "kind" => Shared.Events.probelauf_sweep_started(),
        "sweep_id" => sweep_id,
        "stage" => stage,
        "models" => models,
        "default_model" => default_model,
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

          %{"model" => model, "sessions" => per_session}
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
        "variants" => variants,
        "finished_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      })

    Logger.info(
      "Probelauf-Sweep-Isolated #{sweep_id} done — default model #{default_model} restored"
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
      "faithfulness_score" => faithfulness
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
       }} ->
        ts = parse_ts(ts_iso) || DateTime.utc_now()
        acc = record(acc, target_stage, status, ts)

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

    %{
      duration_ms: duration_ms,
      outcome: Atom.to_string(outcome),
      output_bytes: output_size(stage, campaign_id)
    }
  end

  # Faithfulness-Score gegen Original-Utterances. Stage-Output kommt aus dem
  # Repo (frisch nach dem isolierten Stage-Run); Utterances aus dem Eval-
  # Asset (= das was die Stage als Input gesehen hat).
  defp compute_faithfulness(stage, session_id, _campaign_id) do
    generated_md = read_stage_output(stage, session_id)
    utterances = Repo.list_utterances(session_id) |> Enum.map(&%{"text" => &1.text})

    case Worker.LLM.Faithfulness.score(generated_md || "", utterances) do
      {:ok, %{score: score}} -> score
      {:error, _reason} -> nil
    end
  end

  defp read_stage_output(2, session_id) do
    case Repo.get_session_summary(session_id) do
      %{content_md: md} -> md
      _ -> nil
    end
  end

  defp read_stage_output(3, _session_id) do
    # Epos ist campaign-weit, nicht session-spezifisch
    case Repo.get_epos_entry(eval_campaign_id()) do
      %{content_md: md} -> md
      _ -> nil
    end
  end

  defp read_stage_output(4, session_id) do
    # Chronik-Einträge der Session als ein zusammengefügtes Markdown-Pseudo
    eval_campaign_id()
    |> Repo.list_chronik_entries()
    |> Enum.filter(&(&1.session_id == session_id))
    |> Enum.map_join("\n\n", fn e -> "## #{e.in_game_date} — #{e.label}\n\n#{e.summary}" end)
  end

  # ─── Issue #201: Goldstandard-Pre-Seed für isolierte Stage-Sweeps ──

  @eval_campaign_id "probelauf-eval-goldstandard"
  @eval_session_ids %{
    1 => "probelauf-eval-session-1",
    2 => "probelauf-eval-session-2",
    3 => "probelauf-eval-session-3"
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
        {3, long_utterances()}
      ]
      |> Enum.map(fn {num, utterances} -> seed_eval_session(num, utterances) end)

    {:ok, %{campaign_id: @eval_campaign_id, sessions: sessions}}
  end

  @doc "Liefert die fixe Eval-Campaign-ID."
  @spec eval_campaign_id() :: String.t()
  def eval_campaign_id, do: @eval_campaign_id

  @doc "Liefert die fixe Eval-Session-ID für Session-Nummer 1/2/3."
  @spec eval_session_id(1 | 2 | 3) :: String.t()
  def eval_session_id(num) when num in [1, 2, 3], do: Map.fetch!(@eval_session_ids, num)

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
          "confidence" => 1.0,
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
