defmodule Worker.Probelauf do
  @moduledoc """
  LLM-Smoke-Test (Issue #74; seit #786 Wahrheitsbild-nativ). Bei UI-Trigger
  seedet eine dedizierte Probelauf-Kampagne (Sessions à 10/30/100/~800
  Utterances — short/medium/long/real), fährt sie sequentiell durch die
  normale `Worker.Recording.Pipeline` (Wahrheitsbild-Pfad) und misst pro
  Schritt (`extract`/`verify`/`render`/`timeline`/`render_epos`)
  Wall-Clock-Dauer + Outcome + #716-Fehlerklasse, dazu pro Session den
  **Verify-Trichter** (`n_facts → n_grounded → n_verified`) und die
  Output-Größen (Resümee/Kapitel/Timeline).

  Am Ende publisht der GenServer ein `ProbelaufFinished`-Event mit dem
  gesamten Mess-Payload + Settings-Snapshot, danach `CampaignDeleted` für
  die Probelauf-Kampagne (Cleanup via Materializer-Cascade).

  ## Locking-Modell (post-#292 / #354)

  Zwei orthogonale Locks, beide notwendig:

  - **Probelauf-Lock** (`state.running != nil`, hier im Modul): „nur ein
    Probelauf-Auftrag gleichzeitig". UI-Schutz gegen Doppel-Klicks auf
    „Probelauf starten" / „Sweep starten" — beide reservieren denselben
    `running`-Slot.
  - **GpuQueue-Lock** (`Worker.GpuQueue`, Issue #292): „nur ein
    GPU-schwerer Job gleichzeitig". Hardware-Schutz. Jeder Pipeline-Schritt
    den dieser Probelauf triggert läuft automatisch durch die Queue —
    dieses Modul interagiert nicht direkt mit der GpuQueue.

  Per-Schritt-Timings kommen aus `Worker.Recording.Pipeline.notify_status/3`
  über den Worker.PubSub-Topic `"pipeline_status"`.
  """

  use GenServer
  require Logger

  alias Worker.{Intents, Recording, Repo, Settings}

  # Wie lange max. auf den nächsten Pipeline-Schritt warten (Gap-Timeout,
  # resettet pro Frame), bevor die Probelauf-Engine die Session als
  # `:timeout` markiert und weitermacht. Großzügig, weil die Extraktion
  # mit 30B-Modellen auch >5min dauern kann.
  @stage_timeout_ms 15 * 60_000

  # Die Wahrheitsbild-Schritte, die `run_wahrheitsbild` via `with_status`/
  # `best_effort_artifact` als `pipeline_stage`-Frames meldet (der Registry-
  # Schritt ist best-effort ohne Status — bewusst nicht messbar).
  @steps ~w(extract verify render timeline render_epos)

  @doc "Die gemessenen Wahrheitsbild-Schritte in Pipeline-Reihenfolge."
  @spec steps() :: [String.t()]
  def steps, do: @steps

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
  Startet einen Extraktor-Modell-Sweep (Issue #88 Phase 2a; seit #786
  Wahrheitsbild-nativ). Variiert das Extraktor-/Render-Modell
  (`model_stage2_<backend>` des aktiven `backend_stage2`) durch eine Liste
  von Modellen. Pro Modell ein voller Wahrheitsbild-Probelauf-Run, alle mit
  gemeinsamer `sweep_id`. `session_set` (Issue #284) wählt welche der
  Eval-Sessions gemessen werden — `nil` oder `[]` = short/medium/long.

  Returns:
  - `{:ok, sweep_id}` wenn losgelegt
  - `{:error, {:already_running, run_or_sweep_id}}` wenn schon ein Lauf da ist
  - `{:error, :no_models}` bei leerer Modell-Liste
  """
  @spec start_sweep(String.t(), [String.t()], [String.t()] | nil) ::
          {:ok, String.t()}
          | {:error, {:already_running, String.t()} | :no_models}
  def start_sweep(started_by, models, session_set \\ nil)

  def start_sweep(started_by, models, session_set)
      when is_binary(started_by) and is_list(models) do
    cond do
      models == [] ->
        {:error, :no_models}

      true ->
        GenServer.call(__MODULE__, {:start_sweep, started_by, models, session_set}, 60_000)
    end
  end

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
    # Issue #571: supervidiert (Crash-Visibility im Supervisor-Log). Caveat:
    # state-Cleanup bei Task-Crash via Process.monitor ist eigener Folge-Cut.
    Task.Supervisor.start_child(Worker.TaskSupervisor, fn ->
      run_loop(run_id, started_by, settings, started_at, pid)
    end)

    {:reply, {:ok, run_id},
     %{state | running: %{run_id: run_id, started_by: started_by, started_at: started_at}}}
  end

  def handle_call({:start, _}, _from, %{running: run} = state) do
    {:reply, {:error, {:already_running, run_or_sweep_id(run)}}, state}
  end

  def handle_call(
        {:start_sweep, started_by, models, session_set},
        _from,
        %{running: nil} = state
      ) do
    sweep_id = UUIDv7.generate()
    started_at = DateTime.utc_now()

    pid = self()

    # Issue #571: supervidiert (siehe :start oben — Folge-Cut für DOWN-Cleanup).
    Task.Supervisor.start_child(Worker.TaskSupervisor, fn ->
      run_sweep_loop(sweep_id, started_by, models, session_set, started_at, pid)
    end)

    {:reply, {:ok, sweep_id},
     %{
       state
       | running: %{
           type: :sweep,
           sweep_id: sweep_id,
           started_by: started_by,
           started_at: started_at,
           # Historische Payload-/State-Konvention: der Extraktor-Slot heißt 2.
           stage: 2,
           models: models,
           session_set: normalize_session_set(session_set),
           current_model: nil
         }
     }}
  end

  def handle_call({:start_sweep, _, _, _}, _from, %{running: run} = state) do
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

  # ─── Sweep-Loop (Phase 2a, Issue #88; seit #786 fix auf den ─────────
  # Extraktor-/Render-Slot — der einzige LLM-Slot des Wahrheitsbild-Pfads)

  defp run_sweep_loop(sweep_id, started_by, models, session_set, started_at, parent) do
    session_set = normalize_session_set(session_set)

    Logger.info(
      "Probelauf-Sweep starting sweep_id=#{sweep_id} models=#{inspect(models)} session_set=#{inspect(session_set)}"
    )

    Phoenix.PubSub.subscribe(Worker.PubSub, "pipeline_status")

    # #451 Track C: auf den GEWINNENDEN Key des aktiven Backends schreiben —
    # ein Write auf den Legacy-Key würde von einem persistierten
    # pro-Backend-Key verdeckt (Settings.model_for-Kette).
    active_backend = Settings.get(:backend_stage2)
    setting_key = Settings.model_key(2, active_backend)
    default_model = Settings.model_for(2, active_backend)

    {:ok, _} =
      Intents.publish(%{
        "kind" => Shared.Events.probelauf_sweep_started(),
        "sweep_id" => sweep_id,
        # Historische Payload-Konvention (Mnesia-Spalte probelauf_sweeps.stage):
        # der Extraktor-Slot heißt 2. Neu-additiv: swept_key benennt den
        # tatsächlich variierten Settings-Key.
        "stage" => 2,
        "swept_key" => Atom.to_string(setting_key),
        "models" => models,
        "default_model" => default_model,
        "session_set" => session_set,
        "started_by" => started_by,
        "started_at" => DateTime.to_iso8601(started_at)
      })

    try do
      Enum.each(models, fn model ->
        Logger.info("Probelauf-Sweep #{sweep_id}: variant #{setting_key}=#{model}")
        :ok = Settings.put(setting_key, model)
        _ = GenServer.call(__MODULE__, {:sweep_progress, sweep_id, model})

        do_single_run(
          UUIDv7.generate(),
          started_by,
          settings_snapshot(),
          DateTime.utc_now(),
          sweep_id: sweep_id,
          sweep_variant: %{stage: 2, model: model},
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
  def normalize_session_set(nil), do: ["short", "medium", "long"]
  def normalize_session_set([]), do: ["short", "medium", "long"]

  def normalize_session_set(list) when is_list(list) do
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

    # Issue #702: gebatchter Publish statt ein Frame pro Utterance
    # (gleiche Flood-Klasse wie der Transkriptions-Backlog).
    {:ok, _} =
      texts
      |> Enum.with_index(fn text, i ->
        %{
          "kind" => Shared.Events.utterance_appended(),
          "id" => "u-#{sid}-#{i}",
          "session_id" => sid,
          "discord_id" => owner,
          "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "text" => text,
          # Issue #376: einheitliches Map-Format (vorher Float 1.0).
          "confidence" => Worker.Recording.Transcribe.to_confidence_map(1.0),
          "status" => "confirmed"
        }
      end)
      |> Intents.publish_batch()

    %{number: num, session_id: sid, utterance_count: length(texts)}
  end

  # ─── Mess-Logik pro Session ──────────────────────────────────────

  defp measure_session(session, campaign_id) do
    Logger.info(
      "Probelauf: triggering session #{session.number} (#{session.utterance_count} utts)"
    )

    # Flush stale messages aus früheren Sessions
    flush_pipeline_messages()

    # Direkter Pipeline-Call statt RegenerateRequested-Event-Roundtrip;
    # läuft den normalen Wahrheitsbild-Pfad.
    :ok = Recording.Pipeline.run_for_session(session.session_id)

    acc = collect_stages(campaign_id, %{})

    stage_metrics =
      acc
      |> finalize()
      |> attach_error_types(session.session_id)

    %{
      number: session.number,
      session_id: session.session_id,
      utterance_count: session.utterance_count,
      stages: stage_metrics,
      facts: facts_funnel(session.session_id),
      outputs: outputs(campaign_id, session.session_id)
    }
  end

  # Empfängt {:pipeline_stage, payload}-Messages aus dem Worker.PubSub bis
  # ein terminaler Frame kommt (siehe terminal?/2) oder das Gap-Timeout
  # zuschlägt. Pro Schritt: timestamp-pair (started, ended), Outcome-Rohwert.
  defp collect_stages(campaign_id, acc) do
    receive do
      {:pipeline_stage,
       %{"campaign_id" => ^campaign_id, "stage" => stage, "status" => status, "ts" => ts_iso}} ->
        ts = parse_ts(ts_iso) || DateTime.utc_now()
        acc = record(acc, stage, status, ts)

        if terminal?(stage, status) do
          acc
        else
          collect_stages(campaign_id, acc)
        end

      {:pipeline_stage, _} ->
        # andere Campaign — ignorieren
        collect_stages(campaign_id, acc)
    after
      @stage_timeout_ms ->
        Map.put(acc, :__timeout__, true)
    end
  end

  @doc """
  Terminal-Logik des Wahrheitsbild-Collectors (#786):

  - `render_epos` ended|failed → terminal (letzter Schritt der Geschwister-Kette)
  - `failed` bei `extract`/`verify`/`render` → terminal (bricht die `with`-Kette
    in `run_wahrheitsbild` — danach kommen KEINE weiteren Frames)
  - `timeline`-failed → NICHT terminal (best-effort-Geschwister, `render_epos`
    läuft danach trotzdem)
  """
  @spec terminal?(String.t(), String.t()) :: boolean()
  def terminal?("render_epos", status) when status in ["ended", "failed"], do: true
  def terminal?(stage, "failed") when stage in ["extract", "verify", "render"], do: true
  def terminal?(_stage, _status), do: false

  def record(acc, stage, "started", ts), do: Map.put(acc, {stage, :start}, ts)

  def record(acc, stage, status, ts) when status in ["ended", "failed"] do
    acc
    |> Map.put({stage, :stop}, ts)
    |> Map.put({stage, :outcome_raw}, status)
  end

  def record(acc, _stage, _status, _ts), do: acc

  @doc """
  Baut aus dem Collector-Acc die Schritt-Metriken (PURE — Repo-Lookups für
  `error_type` passieren separat in `attach_error_types/2`).
  """
  @spec finalize(map()) :: %{String.t() => map()}
  def finalize(acc) do
    timeout? = Map.get(acc, :__timeout__, false)

    Enum.into(@steps, %{}, fn step ->
      {step, step_metric(acc, step, timeout?)}
    end)
  end

  defp step_metric(acc, step, timeout?) do
    start = Map.get(acc, {step, :start})
    stop = Map.get(acc, {step, :stop})
    outcome_raw = Map.get(acc, {step, :outcome_raw})

    duration_ms =
      if start && stop, do: DateTime.diff(stop, start, :millisecond), else: nil

    %{
      duration_ms: duration_ms,
      outcome: Atom.to_string(classify_outcome(outcome_raw, timeout?)),
      error_type: nil
    }
  end

  @doc """
  Outcome pro Schritt: `ended` → ok, `failed` → failed (Fehlerklasse kommt
  separat aus dem persistierten #716-Error-Log), kein Frame + Timeout →
  timeout, kein Frame ohne Timeout → skipped (Upstream-Schritt hat die
  Kette terminal gebrochen).
  """
  @spec classify_outcome(String.t() | nil, boolean()) :: :ok | :failed | :timeout | :skipped
  def classify_outcome("ended", _timeout?), do: :ok
  def classify_outcome("failed", _timeout?), do: :failed
  def classify_outcome(nil, true), do: :timeout
  def classify_outcome(nil, false), do: :skipped

  # Für failed-Schritte die #716-Fehlerklasse aus dem persistierten Error-Log
  # ziehen (classify_pipeline_error hat die Wahrheit schon geschrieben —
  # KEINE Neu-Klassifikation im Probelauf).
  defp attach_error_types(stage_metrics, session_id) do
    failed_steps =
      for {step, %{outcome: "failed"}} <- stage_metrics, do: step

    if failed_steps == [] do
      stage_metrics
    else
      errors = Repo.last_n_pipeline_errors(100)

      Enum.into(stage_metrics, %{}, fn {step, metric} ->
        if metric.outcome == "failed" do
          error =
            Enum.find(errors, fn e -> e.session_id == session_id and e.stage == step end)

          {step, %{metric | error_type: error && error.error_type}}
        else
          {step, metric}
        end
      end)
    end
  end

  # Verify-Trichter (das interessanteste Signal des Probelaufs): wie viele
  # Fakten extrahiert, wie viele davon quellen-geerdet, wie viele voll
  # verifiziert (grounded AND attributed). Flags kommen aus verify_session
  # (Flag-statt-Drop, persistiert via SessionFactsExtracted-Re-Publish).
  defp facts_funnel(session_id) do
    facts =
      case Repo.get_session_facts(session_id) do
        %{facts: facts} when is_list(facts) -> facts
        _ -> []
      end

    %{
      n_facts: length(facts),
      n_grounded: Enum.count(facts, & &1["grounded?"]),
      n_verified: Enum.count(facts, & &1["verified?"])
    }
  end

  defp outputs(campaign_id, session_id) do
    summary = Repo.get_session_summary(session_id)
    kapitel = Repo.get_epos_entry(session_id)

    timeline_entries =
      campaign_id
      |> Repo.list_chronik_entries()
      |> Enum.count(&(&1.session_id == session_id))

    %{
      summary_bytes: byte_size((summary && summary.content_md) || ""),
      flagged_claims: length((summary && summary.flagged_claims) || []),
      timeline_entries: timeline_entries,
      kapitel_bytes: byte_size((kapitel && kapitel.content_md) || "")
    }
  end

  # ─── Helpers ─────────────────────────────────────────────────────

  defp settings_snapshot do
    keys = ~w(backend_stage2 ctx_stage2 temperature_stage2
              extract_chunk_tokens extract_num_predict_cap
              judge_model grounding_method
              http_timeout_ms local_endpoint)a

    scalar = Enum.into(keys, %{}, fn k -> {Atom.to_string(k), Settings.get(k)} end)

    # Issue #784: Legacy-`model_stage{n}` entfernt — das aktive Modell über
    # model_for/2 des gewählten Backends auflösen (reine Diagnose-Metadaten).
    backend = Settings.get(:backend_stage2)

    scalar
    |> Map.put("model_stage2", Settings.model_for(2, backend))
    |> Map.put(
      "faithfulness_sidecar_url",
      if(Settings.get(:faithfulness_sidecar_url), do: "set", else: nil)
    )
  end

  def parse_ts(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  def parse_ts(_), do: nil

  def flush_pipeline_messages do
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
end
