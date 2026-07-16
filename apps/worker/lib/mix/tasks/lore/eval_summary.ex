defmodule Mix.Tasks.Lore.Eval.Summary do
  @moduledoc """
  Treue-Eval der Wahrheitsbild-Pipeline gegen ein Fidelity-Testset + Fact-Key
  (Issue #647, Folge #644; seit #786 Wahrheitsbild-only — der Chain-Treiber
  ist mit der Chain-Pipeline entfernt).

  Materialisiert ein geseedetes Fixture (JSONL unter
  `apps/hub/priv/seeds/<campaign>/`) in eine frische Worker-Mnesia, treibt die
  **echten** Pipeline-Bausteine (`extract_facts → Verify.verify_session →
  Render.render_summary` + `render_epos`) pro Session — kein Audio, kein
  Hub-Roundtrip — und scort den Output gegen `fact-key.json`:

    * **entity_recall** (deterministisch) — Anteil der Pflicht-Entities im Resümee.
    * **noise_leak** (deterministisch) — Würfel-/OOC-/Proben-Strings, die nicht
      ins Resümee gehören. Soll 0 sein.
    * **fact_recall / fabrication / attribution_accuracy** (Judge-Pass, nur mit
      `--judge`) — LLM-Grader, NICHT-deterministisch, nur Diagnostik.

  Weil der Eval die echten Pipeline-Bausteine treibt, bewegt sich der Score,
  sobald Extraktions-Prompt/Judge/Render verbessert wird — der
  Measure-First-Loop (#557).

  ## Verwendung

      mix lore.eval.summary                                   # default: skandal-boehmen, Gate gegen baselines.json
      mix lore.eval.summary --campaign skandal-boehmen --verbose
      mix lore.eval.summary --model qwen2.5:7b                # explizites Extraktor-/Render-Modell
      mix lore.eval.summary --judge                           # + LLM-Judge für fact_recall/attribution
      mix lore.eval.summary --samples 3                        # 3 Durchläufe → Median (LLM-Rauschen)
      mix lore.eval.summary --model command-r:35b-08-2024-q4_K_M --timeout-min 45   # langsames Modell: Per-Call-Timeout hoch
      mix lore.eval.summary --max-rel-degradation 0.2         # exit 1 bei entity_recall-Drop > 20 %
      mix lore.eval.summary --output-baseline apps/worker/test/fixtures/summary_eval/baselines.json

  ## Baseline-Label (Historie #685/#786)

  Der `model`-Label im Report und in der Baseline trägt weiterhin das Suffix
  `" (wahrheitsbild)"` (z.B. `qwen2.5:7b (wahrheitsbild)`): so bleiben
  bestehende Wahrheitsbild-Baselines gültig, und alte Chain-Baselines (ohne
  Suffix, aus der A/B-Phase #685) können nie fälschlich gaten.

  ## Determinismus + Gate-Logik (wichtig)

  Die **Scoring-Funktionen** sind deterministisch — der **LLM-Output und damit
  der Score variiert aber run-to-run** (Temperatur). „Deterministisch" heißt hier
  also reproduzierbares *Scoren*, nicht ein reproduzierbarer *Wert*.

  Deshalb mittelt `--samples N` (Issue #656) über N Stage-2-Durchläufe und
  meldet den **Median** (+ min–max-Spanne). Daraus folgt die Gate-Logik:
    * **Harter Gate** (exit 1) auf den `entity_recall`-**Median** — über 10
      Entities + Median-über-N relativ stabil; Toleranz `--max-rel-degradation`
      (default 0.20) gegen die Baseline.
    * `noise_leak` (binär pro Marker, einzeln flaky): bei `--samples ≥ 3` wird
      der **Median** hart gegatet (robust genug), darunter nur gemeldet + Warnung.
    * Judge-Zahlen sind grundsätzlich NICHT gate-fähig (#557-Disziplin).

  `baselines.json` ist **nicht eingecheckt** — modell-/maschinen-/run-spezifisch.
  Per `--output-baseline` lokal erzeugen (am besten mit `--samples 3+` für einen
  stabilen Median); ohne Baseline reportet der Eval nur (kein Gate, exit 0).

  ## Voraussetzungen

    * Ollama läuft + das `--model`-Modell ist gepullt (default-Backend `:local`).
    * Issue #783 Phase 2 (+ Nachtrag): Stage 3 (Verify) + Stage 4 (Render-
      Resümee) + Stage 5 (Render-Epos) werden für die Dauer des Evals auf
      `:local` + dasselbe `--model` gepinnt (Reproduzierbarkeit) — kein
      separates Judge-/Render-/Epos-Modell-Flag hier.
    * Das Fixture ist unter `apps/hub/priv/seeds/<campaign>/` committed (#644).

  Refuses :prod.
  """

  use Mix.Task

  alias Worker.Recording.Pipeline.{Render, Stages, Verify}
  alias Worker.{EvalBootstrap, Repo, SummaryEval}

  @shortdoc "Wahrheitsbild-Treue-Eval gegen Fact-Key + Gate auf baselines.json"

  @seeds_root "apps/hub/priv/seeds"
  @baselines_path "apps/worker/test/fixtures/summary_eval/baselines.json"
  @default_campaign "skandal-boehmen"
  @default_max_rel_degradation 0.20

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          campaign: :string,
          model: :string,
          judge: :boolean,
          verbose: :boolean,
          reset: :boolean,
          samples: :integer,
          timeout_min: :integer,
          max_rel_degradation: :float,
          output_baseline: :string
        ]
      )

    if Mix.env() == :prod do
      Mix.raise("mix lore.eval.summary ist dev/test-only — kein MIX_ENV=prod.")
    end

    campaign_slug = Keyword.get(opts, :campaign, @default_campaign)
    judge? = Keyword.get(opts, :judge, false)
    verbose? = Keyword.get(opts, :verbose, false)
    max_rel = Keyword.get(opts, :max_rel_degradation, @default_max_rel_degradation)

    seed_dir = Path.join(@seeds_root, campaign_slug)
    fact_key = EvalBootstrap.load_fact_key!(seed_dir)
    campaign_id = Map.fetch!(fact_key, "campaign_id")

    EvalBootstrap.bootstrap_worker!()
    {backup, base_model_label} = EvalBootstrap.apply_stage2_model!(opts[:model])

    # Issue #783 Phase 2 (Design D) + Nachtrag: dieser Eval treibt die ECHTEN
    # Verify.verify_session/2 + Render.render_summary/render_epos-Callsites —
    # die laufen seit der vollen Backend-Trennung auf backend_stage3/4/5,
    # NICHT mehr implizit auf Stage 2. Ohne eigenen Pin liefe der Score auf
    # dem jeweils zufällig persistierten Stage-3/4/5-Backend (nicht
    # reproduzierbar gegen die Baseline) bzw. schlüge auf einem frischen
    # Eval-Boot mit `:no_model_configured` fehl
    # (`model_stage{3,4,5}_local: :no_default`). Kein separates
    # `--judge-model`/`--render-model`/`--epos-model`-Flag hier (anders als
    # `eval_verify.ex`) — Stage 3/4/5 pinnen auf dasselbe `--model` wie der
    # Extraktor, das entspricht dem Vor-#783-Phase-2-Verhalten (ein Modell
    # für alle Schritte).
    {verify_backup, _} = EvalBootstrap.apply_stage_model!(3, opts[:model])
    {render_backup, _} = EvalBootstrap.apply_stage_model!(4, opts[:model])
    {epos_backup, _} = EvalBootstrap.apply_stage_model!(5, opts[:model])

    # Label-Suffix bleibt (#685/#786): bestehende Wahrheitsbild-Baselines
    # gelten weiter, alte Chain-Baselines (ohne Suffix) gaten nie fälschlich.
    model_label = "#{base_model_label} (wahrheitsbild)"

    # Issue #660: der Eval-Worker erbt sonst den 10-min-`http_timeout_ms`-Default.
    # Langsame/große Prod-Modelle (z.B. command-r:35b auf knapper GPU) reißen den
    # pro Map-Reduce-Chunk-Call → all_chunks_failed (spurious, kein Modell-/Prompt-
    # Fehler). Großzügiger Per-Call-Timeout, damit slow-but-correct durchläuft.
    timeout_ms = max(Keyword.get(opts, :timeout_min, 30), 1) * 60_000
    Worker.Settings.put(:http_timeout_ms, timeout_ms)
    Mix.shell().info("· http_timeout_ms = #{div(timeout_ms, 60_000)} min/Call")

    try do
      if Keyword.get(opts, :reset, false), do: EvalBootstrap.reset_campaign(campaign_id)
      count = EvalBootstrap.materialize_fixture!(seed_dir)
      Mix.shell().info("· #{count} Events materialisiert (#{campaign_id})")

      campaign =
        Repo.get_campaign(campaign_id) ||
          Mix.raise("Campaign nicht materialisiert: #{campaign_id}")

      session_ids = Map.keys(fact_key["required_facts"]) |> Enum.sort()
      samples = max(Keyword.get(opts, :samples, 1), 1)
      entities = fact_key["required_entities"] || []
      noise_markers = fact_key["rule_noise_markers"] || []

      Mix.shell().info(
        "=== Summary-Eval: #{campaign_slug} / #{model_label} " <>
          "(#{length(session_ids)} Sessions, #{samples} Sample(s)) ==="
      )

      # Issue #656: N Durchläufe → Median statt Einzel-Zufallswert
      # (LLM-Output ist nicht-deterministisch). Jedes Sample = ein voller
      # Wahrheitsbild-Lauf über alle Sessions.
      samples_data =
        Enum.map(1..samples, fn i ->
          if samples > 1, do: Mix.shell().info("· Sample #{i}/#{samples} …")
          measure_sample(session_ids, campaign, entities, noise_markers)
        end)

      report = build_report(campaign_slug, model_label, fact_key, samples_data, judge?)
      print_report(report, verbose?)

      case opts[:output_baseline] do
        nil -> compare_against_baseline!(report, max_rel)
        path -> write_baseline!(report, path)
      end
    after
      EvalBootstrap.restore_stage2_model!(backup)
      EvalBootstrap.restore_stage_model!(3, verify_backup)
      EvalBootstrap.restore_stage_model!(4, render_backup)
      EvalBootstrap.restore_stage_model!(5, epos_backup)
    end
  end

  # ─── Wahrheitsbild-Treiber (Issue #685) ────────────────────────────────

  # extract_facts → verify_session → render_summary. Nutzt die ECHTEN
  # Pipeline-Bausteine, damit der Score sich bewegt sobald Prompt/Judge/Render
  # verbessert wird (Measure-First). Publisht `SessionFactsExtracted` in die
  # Eval-Mnesia — verworfen beim nächsten Reset oder mit `--reset`.
  defp run_wahrheitsbild!(session_id, campaign) do
    utterances = Repo.list_utterances(session_id, limit: :all)
    # #864: Block-Semantik wie die Pipeline — extrahiert wird auf Blöcken, und
    # verify bekommt DENSELBEN Kontext explizit (Einmal-Resolve; ohne das fiele
    # restrict_to_refs bei Block-IDs still aufs volle Transkript zurück).
    blocks = EvalBootstrap.smooth_context(utterances)

    if utterances == [] do
      Mix.shell().error("  ⚠ Session #{session_id}: keine Utterances materialisiert")
      %{summary: "", epos: nil}
    else
      with {:ok, _facts} <- Stages.extract_facts(blocks, session_id, campaign),
           {:ok, verified} <- Verify.verify_session(session_id, campaign, blocks),
           {:ok, %{md: md}} <- Render.render_summary(verified) do
        # #752: Ep_n (Epos-Kapitel) mit denselben Metriken scoren — Flip-
        # Kriterium 1 (#651-Kommentar). Kapitel-Fehler killt den Eval nicht
        # (best-effort wie in der Pipeline), wird aber sichtbar gemeldet.
        epos =
          case Render.render_epos(verified) do
            {:ok, %{md: epos_md}} ->
              epos_md

            {:error, reason} ->
              Mix.shell().error("  ⚠ Ep_n für #{session_id} gescheitert: #{inspect(reason)}")
              nil
          end

        %{summary: md, epos: epos}
      else
        {:error, reason} ->
          Mix.raise("Wahrheitsbild für #{session_id} gescheitert: #{inspect(reason)}")
      end
    end
  end

  # ─── Report ─────────────────────────────────────────────────────────────

  # Ein Sample = ein voller Wahrheitsbild-Durchlauf über alle Sessions +
  # lexikalisches Scoring. Reine Listen/Floats, damit run/1 N davon sammeln
  # + aggregieren kann.
  defp measure_sample(session_ids, campaign, entities, noise_markers) do
    outputs = Enum.map(session_ids, fn sid -> {sid, run_wahrheitsbild!(sid, campaign)} end)
    summaries = Enum.map(outputs, fn {sid, out} -> {sid, out.summary} end)
    full = summaries |> Enum.map(&elem(&1, 1)) |> Enum.join("\n\n")

    per_session_noise =
      Enum.map(summaries, fn {sid, md} -> {sid, SummaryEval.noise_leak(md, noise_markers)} end)

    # #752: Ep_n-Metriken (Kapitel aus Render.render_epos; nil bei Render-Fehler).
    epos_chapters = for {sid, %{epos: md}} <- outputs, is_binary(md), do: {sid, md}
    epos_full = epos_chapters |> Enum.map(&elem(&1, 1)) |> Enum.join("\n\n")

    epos_metrics =
      if epos_chapters == [] do
        nil
      else
        %{
          entity_recall: SummaryEval.entity_recall(epos_full, entities),
          noise_total:
            epos_chapters
            |> Enum.map(fn {_s, md} -> SummaryEval.noise_leak(md, noise_markers).hits end)
            |> Enum.sum(),
          full: epos_full,
          chapters: epos_chapters
        }
      end

    %{
      summaries: summaries,
      full_summary: full,
      entity_recall: SummaryEval.entity_recall(full, entities),
      noise_total: per_session_noise |> Enum.map(fn {_s, n} -> n.hits end) |> Enum.sum(),
      per_session_noise: per_session_noise,
      epos: epos_metrics
    }
  end

  defp build_report(campaign_slug, model_label, fact_key, samples_data, judge?) do
    ers = Enum.map(samples_data, & &1.entity_recall.rate)
    noises = Enum.map(samples_data, & &1.noise_total)
    # Repräsentatives Sample (letztes) für Detail-Anzeige (fehlende Entities),
    # Judge + verbose. Median ist die gate-relevante Zahl.
    rep = List.last(samples_data)

    judge =
      if judge? do
        flat_facts = fact_key["required_facts"] |> Map.values() |> List.flatten()

        case SummaryEval.judge(rep.full_summary, flat_facts, fact_key) do
          {:ok, j} -> j
          {:error, reason} -> %{error: reason}
        end
      end

    # #752: Ep_n-Aggregat (nur wenn der Mode Kapitel liefert).
    epos_report =
      case Enum.filter(samples_data, & &1.epos) do
        [] ->
          nil

        with_epos ->
          e_ers = Enum.map(with_epos, & &1.epos.entity_recall.rate)
          e_noises = Enum.map(with_epos, & &1.epos.noise_total)
          rep_epos = List.last(with_epos).epos

          epos_judge =
            if judge? do
              flat_facts = fact_key["required_facts"] |> Map.values() |> List.flatten()

              case SummaryEval.judge(rep_epos.full, flat_facts, fact_key) do
                {:ok, j} -> j
                {:error, reason} -> %{error: reason}
              end
            end

          %{
            entity_recall_median: SummaryEval.median(e_ers),
            entity_recall_range: {Enum.min(e_ers), Enum.max(e_ers)},
            noise_median: round(SummaryEval.median(e_noises)),
            noise_range: {Enum.min(e_noises), Enum.max(e_noises)},
            representative_entity_recall: rep_epos.entity_recall,
            chapters: rep_epos.chapters,
            judge: epos_judge
          }
      end

    %{
      campaign: campaign_slug,
      model: model_label,
      samples: length(samples_data),
      entity_recall_median: SummaryEval.median(ers),
      entity_recall_range: {Enum.min(ers), Enum.max(ers)},
      noise_median: round(SummaryEval.median(noises)),
      noise_range: {Enum.min(noises), Enum.max(noises)},
      representative_entity_recall: rep.entity_recall,
      per_session_noise: rep.per_session_noise,
      summaries: rep.summaries,
      judge: judge,
      epos: epos_report
    }
  end

  defp print_report(report, verbose?) do
    rep_er = report.representative_entity_recall
    Mix.shell().info("")

    Mix.shell().info(
      "entity_recall = #{pct(report.entity_recall_median)}#{range_suffix(report.samples, report.entity_recall_range, &pct/1)}"
    )

    if rep_er.missing != [],
      do: Mix.shell().info("  fehlend (repr. Sample): #{Enum.join(rep_er.missing, ", ")}")

    Mix.shell().info(
      "noise_leak    = #{report.noise_median}#{range_suffix(report.samples, report.noise_range, &to_string/1)} (Soll: 0)"
    )

    Enum.each(report.per_session_noise, fn {sid, n} ->
      if n.hits > 0, do: Mix.shell().info("  #{sid}: #{Enum.join(n.markers, ", ")}")
    end)

    print_judge(report.judge)
    print_epos(report.epos, report.samples)

    if verbose? do
      Mix.shell().info("")
      Mix.shell().info("Resümees:")

      Enum.each(report.summaries, fn {sid, md} ->
        Mix.shell().info("── #{sid} ──")
        Mix.shell().info(md)
      end)
    end
  end

  # #752: Ep_n-Block — gleiche Metriken, NICHT gegated (Flip-Kriterium wird
  # manuell gegen Chain verglichen, #651-Kommentar).
  defp print_epos(nil, _samples), do: :ok

  defp print_epos(e, samples) do
    Mix.shell().info("")
    Mix.shell().info("── Ep_n (Epos-Kapitel, #752 — nicht gegated) ──")

    Mix.shell().info(
      "entity_recall = #{pct(e.entity_recall_median)}#{range_suffix(samples, e.entity_recall_range, &pct/1)}"
    )

    if e.representative_entity_recall.missing != [],
      do:
        Mix.shell().info(
          "  fehlend (repr. Sample): #{Enum.join(e.representative_entity_recall.missing, ", ")}"
        )

    Mix.shell().info(
      "noise_leak    = #{e.noise_median}#{range_suffix(samples, e.noise_range, &to_string/1)} (Soll: 0)"
    )

    print_judge(e.judge)
  end

  defp print_judge(nil), do: :ok

  defp print_judge(%{error: reason}) do
    Mix.shell().info("")
    Mix.shell().error("Judge fehlgeschlagen: #{inspect(reason)}")
  end

  defp print_judge(j) do
    Mix.shell().info("")
    Mix.shell().info("── Judge-Pass (LLM, nicht-deterministisch — nur Diagnostik) ──")

    Mix.shell().info(
      "fact_recall          = #{pct(j.fact_recall.rate)} (#{j.fact_recall.covered}/#{j.fact_recall.total})"
    )

    Mix.shell().info(
      "fabrication (Decoys) = #{j.fabrication.asserted}/#{j.fabrication.total} behauptet (Soll: 0)"
    )

    Mix.shell().info(
      "attribution_accuracy = #{pct(j.attribution_accuracy.rate)} (#{j.attribution_accuracy.correct}/#{j.attribution_accuracy.total})"
    )

    if j.fact_recall.missing != [] do
      Mix.shell().info("  fehlende Fakten:")
      Enum.each(j.fact_recall.missing, fn f -> Mix.shell().info("    - #{f}") end)
    end

    if j.fabrication.asserted_decoys != [] do
      Mix.shell().info("  behauptete Decoys (Halluzination!):")
      Enum.each(j.fabrication.asserted_decoys, fn d -> Mix.shell().info("    - #{d}") end)
    end
  end

  defp pct(rate), do: "#{Float.round(rate * 100, 1)} %"

  # Spanne min–max nur anzeigen, wenn mehr als ein Sample lief.
  defp range_suffix(samples, _range, _fmt) when samples <= 1, do: ""

  defp range_suffix(samples, {min, max}, fmt),
    do: "  [#{fmt.(min)}–#{fmt.(max)} über #{samples} Samples]"

  # ─── Baseline-Gate ──────────────────────────────────────────────────────

  defp compare_against_baseline!(report, max_rel) do
    base = get_in(EvalBootstrap.read_baselines(@baselines_path), [report.model, report.campaign])

    cond do
      is_nil(base) ->
        Mix.shell().info("")
        Mix.shell().info("⚠ Keine Baseline für #{report.model}/#{report.campaign}.")
        Mix.shell().info("  Schreibe mit --output-baseline #{@baselines_path}.")

      true ->
        check_entity_recall!(report, base, max_rel)
        check_noise_leak!(report, base)
        Mix.shell().info("")
        Mix.shell().info("✓ innerhalb Toleranz gegen Baseline.")
    end
  end

  # Harter Gate auf den entity_recall-Median (über 10 Entities + Median-über-N
  # relativ stabil), relativ-tolerant.
  defp check_entity_recall!(report, base, max_rel) do
    base_er = base["entity_recall"] || 0.0
    current = report.entity_recall_median

    if current < base_er * (1.0 - max_rel) do
      Mix.raise(
        "entity_recall-Regression: Median=#{pct(current)} < " <>
          "Baseline=#{pct(base_er)} × (1 - #{max_rel})"
      )
    end
  end

  # Issue #656: noise_leak ist binär pro Marker → bei einem einzelnen Sample zu
  # flaky für einen harten Gate (ein geleakter Skill-Name würde röten). Mit dem
  # Median über N≥3 ist er stabil genug → dann HART gaten; darunter nur warnen.
  defp check_noise_leak!(report, base) do
    base_noise = base["noise_leak"] || 0

    cond do
      report.noise_median <= base_noise ->
        :ok

      report.samples >= 3 ->
        Mix.raise(
          "noise_leak-Regression: Median=#{report.noise_median} > Baseline=#{base_noise} " <>
            "(#{report.samples} Samples → robust)"
        )

      true ->
        Mix.shell().info("")

        Mix.shell().error(
          "⚠ noise_leak gestiegen: Median=#{report.noise_median} > Baseline=#{base_noise} " <>
            "(kein harter Fail bei <3 Samples — mit --samples 3+ bestätigen)"
        )
    end
  end

  defp write_baseline!(report, path) do
    entry = %{
      "entity_recall" => Float.round(report.entity_recall_median, 4),
      "noise_leak" => report.noise_median,
      "samples" => report.samples,
      "recorded_at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    EvalBootstrap.write_baseline!(path, [report.model, report.campaign], entry)
    Mix.shell().info("Baseline geschrieben: #{path}")
  end
end
