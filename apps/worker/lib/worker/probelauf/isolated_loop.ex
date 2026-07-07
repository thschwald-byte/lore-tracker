defmodule Worker.Probelauf.IsolatedLoop do
  @moduledoc """
  Issue #584 (God-Module-Split aus `Worker.Probelauf`): die stage-isolierten
  Sweep-Loops (#262) + Param-Sweep (#290) + die Goldstandard-Faithfulness-
  Messung (#201). Reine Worker-Funktionen, aufgerufen aus den `handle_call`-
  Klauseln des `Worker.Probelauf`-GenServers (im selben Prozess). Die geteilten
  Run-Helfer (`seed`, `record`, `finalize`, `classify_outcome`, …) bleiben in
  `Worker.Probelauf` (`@doc false`-public) und kommen via `import` rein.
  """
  require Logger

  alias Worker.{Intents, Recording, Repo, Settings}

  import Worker.Probelauf

  # Issue #584: lokale Kopie des Stage-Timeouts (Modul-Attribut, modul-lokal).
  @stage_timeout_ms 15 * 60_000

  # ─── Issue #262: Stage-isolierter Sweep-Loop ───────────────────────

  def run_sweep_isolated_loop(
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

    # #451 Track C: auf den GEWINNENDEN Key des aktiven Backends schreiben —
    # ein Write auf den Legacy-Key würde von einem persistierten
    # pro-Backend-Key verdeckt (Settings.model_for-Kette).
    active_backend = Settings.get(:"backend_stage#{stage}")
    setting_key = Settings.model_key(stage, active_backend)
    default_model = Settings.model_for(stage, active_backend)

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
  def run_sweep_isolated_param_loop(
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

    # Fixed model = aktuelles Modell der Stage (pro-Backend-Auflösung, #451).
    # Im UI ist dieser Wert sichtbar (Modell-Pille pro Variante).
    fixed_model = Settings.model_for(stage, Settings.get(:"backend_stage#{stage}"))

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
end
