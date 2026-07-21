defmodule Mix.Tasks.Lore.Eval.Threads do
  @moduledoc """
  Handlungsbogen-Treue-Eval der Wahrheitsbild-Extraktion gegen die
  `threads`/`must_not_merge_threads`/`must_not_resolve`-Blöcke eines
  Fidelity-Fact-Keys (Issue #830, Slice A des Epic #829).

  Das Gegenstück zu `mix lore.eval.summary`, nur für die **Erzählstruktur**:
  materialisiert ein geseedetes Fixture (JSONL unter
  `apps/hub/priv/seeds/<campaign>/`) in eine frische Worker-Mnesia, treibt die
  **echte** Extraktion (`Stages.extract_facts`) pro Session, gruppiert die
  produzierten Fakten campaign-weit nach ihrem rohen `thread`-Label und scort
  gegen den Fact-Key (`Worker.ThreadEval`):

    * **thread_recall** — Anteil der Soll-Stränge mit ≥1 passendem produzierten
      Strang.
    * **fragmentation** — distinkte produzierte Labels je Soll-Strang (1.0 =
      perfekt). Das Kern-Signal fürs Extraktions-Prompt-Tuning (Slice B) + die
      ThreadRegistry (Slice C).
    * **false_merge** — verletzt ein produzierter Strang ein `must_not_merge`-
      Paar? (Deterministisch nur label-/entity-sichtbar — siehe
      `Worker.ThreadEval`-Grenze.)
    * **false_resolve** — trägt der produzierte Gegenpart eines
      `must_not_resolve`-Strangs ein Auflösungs-Flag?

  ## Gate (Issue #837, Slice E — analog `mix lore.eval.summary`)

  Gemessen werden die **Roh-Extraktions-Labels** (vor Registry-Clustering) —
  der Measure-First-Anker (#557). Weil der LLM-Output run-zu-run streut,
  mittelt `--samples N` über N volle Extraktions-Läufe und gatet den **Median**
  gegen `baselines.json`:

    * **thread_recall** — harter Gate (exit 1) auf den Median, relativ-tolerant
      (`--max-rel-degradation`, Default 0.20).
    * **false_merge / false_resolve** — Soll 0; binär pro Paar/Strang → einzeln
      flaky. Bei `--samples ≥ 3` wird der Median HART gegatet, darunter nur
      Warnung (das `noise_leak`-Muster aus #656). `false_resolve` gatet auf
      sauberer Arc-Semantik: die Soll-Stränge des Fact-Keys sind Arcs — für
      Contexte ist die Metrik undefiniert (#885).
    * `fragmentation` wird gemeldet, nicht gegated (Registry-Clustering #832
      heilt Fragmentierung produktiv; das Roh-Signal dient dem Prompt-Tuning).

  `baselines.json` (unter `apps/worker/test/fixtures/thread_eval/`) ist
  **nicht eingecheckt** — modell-/maschinen-spezifisch. Per `--output-baseline`
  lokal erzeugen (am besten `--samples 3+`); ohne Baseline reportet der Eval
  nur (kein Gate, exit 0). Ehrliche Grenze: das Gate schützt vor **Regression
  gegen das Doyle-Fixture**, nicht vor der schwächeren Label-Realität auf
  echtem Tisch-Deutsch (Free-Seattle-Befund: viele leere Labels).

  ## Verwendung

      mix lore.eval.threads                            # default: skandal-boehmen, Gate gegen baselines.json
      mix lore.eval.threads --campaign skandal-boehmen --verbose
      mix lore.eval.threads --model qwen2.5:7b         # explizites Extraktor-Modell
      mix lore.eval.threads --samples 3                # 3 Läufe → Median (LLM-Rauschen)
      mix lore.eval.threads --max-rel-degradation 0.2  # exit 1 bei thread_recall-Drop > 20 %
      mix lore.eval.threads --output-baseline apps/worker/test/fixtures/thread_eval/baselines.json
      mix lore.eval.threads --reset                    # Campaign vorher löschen

  ## Voraussetzungen

    * Ollama läuft + das `--model`-Modell ist gepullt (default-Backend `:local`).
    * Das Fixture ist unter `apps/hub/priv/seeds/<campaign>/` committed (#644)
      und sein `fact-key.json` hat die drei Thread-Blöcke (#830).

  Refuses :prod.
  """

  use Mix.Task

  alias Worker.Recording.Pipeline.Stages
  alias Worker.{EvalBootstrap, Repo, SummaryEval, ThreadEval}

  @shortdoc "Wahrheitsbild-Handlungsbogen-Eval gegen die Thread-Blöcke des Fact-Keys"

  @seeds_root "apps/hub/priv/seeds"
  @default_campaign "skandal-boehmen"
  @baselines_path "apps/worker/test/fixtures/thread_eval/baselines.json"
  @default_max_rel_degradation 0.20

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          campaign: :string,
          model: :string,
          verbose: :boolean,
          reset: :boolean,
          timeout_min: :integer,
          chunk_tokens: :integer,
          ctx: :integer,
          samples: :integer,
          max_rel_degradation: :float,
          output_baseline: :string
        ]
      )

    if Mix.env() == :prod do
      Mix.raise("mix lore.eval.threads ist dev/test-only — kein MIX_ENV=prod.")
    end

    campaign_slug = Keyword.get(opts, :campaign, @default_campaign)
    verbose? = Keyword.get(opts, :verbose, false)

    seed_dir = Path.join(@seeds_root, campaign_slug)
    fact_key = EvalBootstrap.load_fact_key!(seed_dir)
    campaign_id = Map.fetch!(fact_key, "campaign_id")

    unless is_list(fact_key["threads"]) and fact_key["threads"] != [] do
      Mix.raise(
        "Fact-Key #{campaign_slug} hat keinen `threads`-Block — Slice A erweitert nur skandal-boehmen."
      )
    end

    EvalBootstrap.bootstrap_worker!()
    # Nur die Extraktion (Stage 2) treiben — ThreadEval scort die Roh-Labels,
    # Verify/Render ändern das `thread`-Feld nicht.
    {backup, model_label} = EvalBootstrap.apply_stage2_model!(opts[:model])

    timeout_ms = max(Keyword.get(opts, :timeout_min, 30), 1) * 60_000
    Worker.Settings.put(:http_timeout_ms, timeout_ms)
    Mix.shell().info("· http_timeout_ms = #{div(timeout_ms, 60_000)} min/Call")

    # Optionale Extraktions-Knöpfe (Issue #831): kleinere Chunks / größerer
    # Kontext gegen num_ctx-Truncation (:parse_failed) bei verbosen Extraktoren.
    if ct = opts[:chunk_tokens] do
      Worker.Settings.put(:extract_chunk_tokens, ct)
      Mix.shell().info("· extract_chunk_tokens = #{ct}")
    end

    if ctx = opts[:ctx] do
      Worker.Settings.put(:ctx_stage2, ctx)
      Mix.shell().info("· ctx_stage2 = #{ctx}")
    end

    max_rel = Keyword.get(opts, :max_rel_degradation, @default_max_rel_degradation)
    samples = max(Keyword.get(opts, :samples, 1), 1)

    try do
      if Keyword.get(opts, :reset, false), do: EvalBootstrap.reset_campaign(campaign_id)
      count = EvalBootstrap.materialize_fixture!(seed_dir)
      Mix.shell().info("· #{count} Events materialisiert (#{campaign_id})")

      campaign =
        Repo.get_campaign(campaign_id) ||
          Mix.raise("Campaign nicht materialisiert: #{campaign_id}")

      session_ids = fact_key["required_facts"] |> Map.keys() |> Enum.sort()

      Mix.shell().info(
        "=== Thread-Eval: #{campaign_slug} / #{model_label} " <>
          "(#{length(session_ids)} Sessions, #{samples} Sample(s)) ==="
      )

      # #837: N volle Extraktions-Läufe → Median gatet (LLM-Rauschen, #656-Muster).
      # Fakten je Lauf campaign-weit sammeln — Handlungsbögen spannen über Sessions.
      samples_data =
        Enum.map(1..samples, fn i ->
          if samples > 1, do: Mix.shell().info("· Sample #{i}/#{samples} …")
          produced = Enum.flat_map(session_ids, &extract_session_facts(&1, campaign))
          {ThreadEval.score(produced, fact_key), produced}
        end)

      report = build_report(campaign_slug, model_label, samples_data)
      print_report(report, verbose?)

      case opts[:output_baseline] do
        nil -> compare_against_baseline!(report, max_rel)
        path -> write_baseline!(report, path)
      end
    after
      EvalBootstrap.restore_stage2_model!(backup)
    end
  end

  defp extract_session_facts(session_id, campaign) do
    case Repo.list_utterances(session_id, limit: :all) do
      [] ->
        Mix.shell().error("  ⚠ Session #{session_id}: keine Utterances materialisiert")
        []

      utterances ->
        # #864: dieselbe Stage-1.1-Glättung wie die Pipeline — Extraktion läuft
        # auf Blöcken (source_refs = Block-IDs), nicht auf Roh-Utterances.
        blocks = EvalBootstrap.smooth_context(utterances)

        case Stages.extract_facts(blocks, session_id, campaign) do
          {:ok, facts} ->
            facts

          {:error, reason} ->
            Mix.raise("Extraktion für #{session_id} gescheitert: #{inspect(reason)}")
        end
    end
  end

  # ─── Report ─────────────────────────────────────────────────────────────

  # #837: Mediane über die Samples sind die gate-relevanten Zahlen; das LETZTE
  # Sample ist das repräsentative für die Detail-Anzeige (fehlende Stränge,
  # Fragment-Listen, verbose-Labels) — dasselbe Muster wie eval.summary.
  defp build_report(campaign_slug, model_label, samples_data) do
    reports = Enum.map(samples_data, &elem(&1, 0))
    {rep, rep_facts} = List.last(samples_data)

    recalls = Enum.map(reports, & &1.thread_recall.rate)
    merges = Enum.map(reports, & &1.false_merge.violated)
    resolves = Enum.map(reports, & &1.false_resolve.violated)

    %{
      campaign: campaign_slug,
      model: model_label,
      samples: length(samples_data),
      thread_recall_median: SummaryEval.median(recalls),
      thread_recall_range: {Enum.min(recalls), Enum.max(recalls)},
      false_merge_median: round(SummaryEval.median(merges)),
      false_merge_range: {Enum.min(merges), Enum.max(merges)},
      false_resolve_median: round(SummaryEval.median(resolves)),
      false_resolve_range: {Enum.min(resolves), Enum.max(resolves)},
      representative: rep,
      representative_facts: rep_facts
    }
  end

  defp print_report(report, verbose?) do
    r = report.representative
    Mix.shell().info("")

    Mix.shell().info(
      "· #{r.total_fact_count} Fakten extrahiert, #{r.grouped_fact_count} mit thread-Label " <>
        "in #{r.produced_threads} Strängen (repr. Sample)"
    )

    if r.grouped_fact_count == 0 do
      Mix.shell().info("")

      Mix.shell().info(
        "⚠ Kein einziger Fakt trägt ein `thread`-Label → Null-Report " <>
          "(Extraktor labelt nicht — Modellwahl prüfen, #831-Befund)."
      )
    end

    Mix.shell().info("")
    tr = r.thread_recall

    Mix.shell().info(
      "thread_recall   = #{pct(report.thread_recall_median)}" <>
        "#{range_suffix(report.samples, report.thread_recall_range, &pct/1)}"
    )

    if tr.missing != [],
      do: Mix.shell().info("  fehlend (repr. Sample): #{Enum.join(tr.missing, ", ")}")

    fr = r.fragmentation

    Mix.shell().info(
      "fragmentation   = #{Float.round(fr.mean_labels_per_thread, 2)} Labels/Strang " <>
        "(Soll 1.0, nicht gegated), #{fr.fragmented} fragmentiert"
    )

    Enum.each(fr.per_thread, fn {canon, n} ->
      if n > 1, do: Mix.shell().info("  #{canon}: #{n} Labels")
    end)

    fm = r.false_merge

    Mix.shell().info(
      "false_merge     = #{report.false_merge_median}" <>
        "#{range_suffix(report.samples, report.false_merge_range, &to_string/1)} " <>
        "von #{fm.total} Paaren (Soll: 0)"
    )

    Enum.each(fm.details, fn d ->
      if d.violated do
        Mix.shell().info("  #{Enum.join(d.pair, " + ")} ← #{Enum.join(d.offending_labels, ", ")}")
      end
    end)

    frs = r.false_resolve

    Mix.shell().info(
      "false_resolve   = #{report.false_resolve_median}" <>
        "#{range_suffix(report.samples, report.false_resolve_range, &to_string/1)} " <>
        "von #{frs.total} Strängen (Soll: 0)"
    )

    Enum.each(frs.details, fn d ->
      if d.resolved_flagged,
        do: Mix.shell().info("  #{d.thread}: fälschlich als aufgelöst geflaggt")
    end)

    if verbose? do
      Mix.shell().info("")
      Mix.shell().info("Produzierte thread-Labels (roh, repr. Sample):")

      report.representative_facts
      |> Enum.map(&Map.get(&1, "thread"))
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.frequencies()
      |> Enum.sort_by(fn {_l, n} -> -n end)
      |> Enum.each(fn {label, n} -> Mix.shell().info("  #{n}×  #{label}") end)
    end
  end

  defp pct(rate), do: "#{Float.round(rate * 100, 1)} %"

  defp range_suffix(samples, _range, _fmt) when samples <= 1, do: ""

  defp range_suffix(samples, {min, max}, fmt),
    do: "  [#{fmt.(min)}–#{fmt.(max)} über #{samples} Samples]"

  # ─── Baseline-Gate (#837 — Muster von eval.summary/#656) ─────────────────

  defp compare_against_baseline!(report, max_rel) do
    base = get_in(EvalBootstrap.read_baselines(@baselines_path), [report.model, report.campaign])

    cond do
      is_nil(base) ->
        Mix.shell().info("")
        Mix.shell().info("⚠ Keine Baseline für #{report.model}/#{report.campaign}.")
        Mix.shell().info("  Schreibe mit --output-baseline #{@baselines_path}.")

      true ->
        check_thread_recall!(report, base, max_rel)
        check_zero_metric!(report, base, :false_merge_median, "false_merge")
        check_zero_metric!(report, base, :false_resolve_median, "false_resolve")
        Mix.shell().info("")
        Mix.shell().info("✓ innerhalb Toleranz gegen Baseline.")
    end
  end

  # Harter Gate auf den thread_recall-Median, relativ-tolerant (wenige
  # Soll-Stränge → ein verpasster Strang ist ein großer relativer Sprung;
  # die Toleranz fängt das, der Median über N das LLM-Rauschen).
  defp check_thread_recall!(report, base, max_rel) do
    base_tr = base["thread_recall"] || 0.0
    current = report.thread_recall_median

    if current < base_tr * (1.0 - max_rel) do
      Mix.raise(
        "thread_recall-Regression: Median=#{pct(current)} < " <>
          "Baseline=#{pct(base_tr)} × (1 - #{max_rel})"
      )
    end
  end

  # false_merge/false_resolve sind binär pro Paar/Strang → einzeln flaky
  # (#656-Klasse). Median über N≥3 ist robust → HART gaten; darunter warnen.
  defp check_zero_metric!(report, base, key, label) do
    base_val = base[label] || 0
    current = Map.fetch!(report, key)

    cond do
      current <= base_val ->
        :ok

      report.samples >= 3 ->
        Mix.raise(
          "#{label}-Regression: Median=#{current} > Baseline=#{base_val} " <>
            "(#{report.samples} Samples → robust)"
        )

      true ->
        Mix.shell().info("")

        Mix.shell().error(
          "⚠ #{label} gestiegen: Median=#{current} > Baseline=#{base_val} " <>
            "(kein harter Fail bei <3 Samples — mit --samples 3+ bestätigen)"
        )
    end
  end

  defp write_baseline!(report, path) do
    entry = %{
      "thread_recall" => Float.round(report.thread_recall_median, 4),
      "false_merge" => report.false_merge_median,
      "false_resolve" => report.false_resolve_median,
      "samples" => report.samples,
      "recorded_at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    EvalBootstrap.write_baseline!(path, [report.model, report.campaign], entry)
    Mix.shell().info("Baseline geschrieben: #{path}")
  end
end
