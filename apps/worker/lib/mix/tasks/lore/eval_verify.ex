defmodule Mix.Tasks.Lore.Eval.Verify do
  @moduledoc """
  Verify-Gate-Eval für den Wahrheitsbild-Pfad (Issue #675, Folge #651/#666).

  Misst, wie gut das NLI-Grounding-Gate (`Worker.Recording.Pipeline.Verify.nli_verify_one/2`)
  echte Fakten durchlässt und falsche ablehnt — die Kalibrierungs-Schleife für den
  Verify-Blocker (deutsche Fakten wurden bisher pauschal 0/N abgelehnt).

  Materialisiert das Fixture (JSONL unter `apps/hub/priv/seeds/<campaign>/`) in eine
  frische Worker-Mnesia (geteilter Bootstrap mit `lore.eval.summary` via
  `Worker.EvalBootstrap`), treibt die **echte** Fakt-Extraktion
  (`Stages.extract_facts/3`) pro Session und scort dann das Grounding-Gate:

    * **TPR** (true-positive-rate) — Anteil der extrahierten (nachweislich treuen)
      Fakten, die das Gate als geerdet markiert. Soll HOCH (~Extraktions-Treuerate).
    * **FPR** (false-positive-rate) — Anteil der `fact-key`-`decoys` (falsche Claims
      wie „Holmes erschießt jemanden"), die — mit der Vereinigung aller echten
      source_refs der Session als Quelle (strengster Test) — fälschlich als geerdet
      durchgehen. Soll NIEDRIG (~0).

  Nur **Grounding** wird gemessen (nicht die Attributions-Achse #669) — der
  #675-Befund ist rein NLI/Grounding.

  ## Verwendung

      mix lore.eval.verify --sidecar-url http://127.0.0.1:8765           # aktuelle Settings
      mix lore.eval.verify --sidecar-url http://127.0.0.1:8765 --sweep   # Schwellen-Grid
      mix lore.eval.verify --model qwen3:30b-a3b-instruct-2507-q4_K_M --samples 3
      mix lore.eval.verify --output-baseline apps/worker/test/fixtures/verify_eval/baselines.json

  ## Determinismus + Gate-Logik

  Das NLI selbst ist deterministisch (kein Sampling) — die Nicht-Determinismus-
  Quelle ist die **Extraktion** (Temperatur). Deshalb mittelt `--samples N` über N
  Extraktions-Durchläufe und meldet den **Median**:
    * **Harter Gate** (exit 1) auf den TPR-Median (Toleranz `--max-rel-degradation`,
      default 0.20) gegen die Baseline — ein TPR-Einbruch rotet.
    * FPR: bei `--samples ≥ 3` hart gegatet, darunter nur gemeldet + Warnung
      (analog `lore.eval.summary` noise_leak, #656/#557-Disziplin).

  `baselines.json` ist **nicht eingecheckt** (modell-/sidecar-spezifisch) — per
  `--output-baseline` lokal erzeugen.

  ## Voraussetzungen

    * NLI-Sidecar läuft (`--sidecar-url` oder `:faithfulness_sidecar_url`-Setting) —
      ohne ihn ist jedes Grounding `false` (TPR 0); die Task bricht dann mit Hinweis ab.
    * Ollama läuft + das Extraktions-Modell (`model_stage2`) ist gepullt.

  Refuses :prod.
  """

  use Mix.Task

  alias Worker.Recording.Pipeline.{Stages, Verify}
  alias Worker.{EvalBootstrap, Repo, SummaryEval}

  @shortdoc "Verify-Gate-Eval (TPR/FPR) gegen Fact-Key + Gate auf baselines.json"

  @seeds_root "apps/hub/priv/seeds"
  @baselines_path "apps/worker/test/fixtures/verify_eval/baselines.json"
  @default_campaign "skandal-boehmen"
  @default_max_rel_degradation 0.20

  # Schwellen-Grid für --sweep (entail_min × max_contra).
  @sweep_entail [0.3, 0.4, 0.5, 0.6]
  @sweep_contra [0.4, 0.5, 0.7]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          campaign: :string,
          model: :string,
          samples: :integer,
          timeout_min: :integer,
          max_rel_degradation: :float,
          output_baseline: :string,
          sidecar_url: :string,
          ctx: :integer,
          sweep: :boolean,
          verbose: :boolean,
          reset: :boolean
        ]
      )

    if Mix.env() == :prod do
      Mix.raise("mix lore.eval.verify ist dev/test-only — kein MIX_ENV=prod.")
    end

    campaign_slug = Keyword.get(opts, :campaign, @default_campaign)
    verbose? = Keyword.get(opts, :verbose, false)
    sweep? = Keyword.get(opts, :sweep, false)
    max_rel = Keyword.get(opts, :max_rel_degradation, @default_max_rel_degradation)

    seed_dir = Path.join(@seeds_root, campaign_slug)
    fact_key = EvalBootstrap.load_fact_key!(seed_dir)
    campaign_id = Map.fetch!(fact_key, "campaign_id")

    EvalBootstrap.bootstrap_worker!()
    {backup, model_label} = EvalBootstrap.apply_stage2_model!(opts[:model])

    if url = opts[:sidecar_url], do: Worker.Settings.put(:faithfulness_sidecar_url, url)

    if Worker.Settings.get(:faithfulness_sidecar_url) == nil do
      Mix.raise(
        "Kein NLI-Sidecar konfiguriert — Verify-Eval braucht ihn (sonst ist jedes " <>
          "Grounding false). Setze --sidecar-url http://… oder :faithfulness_sidecar_url."
      )
    end

    timeout_ms = max(Keyword.get(opts, :timeout_min, 30), 1) * 60_000
    Worker.Settings.put(:http_timeout_ms, timeout_ms)

    # extract_facts ist Single-Prompt (kein Map-Reduce, #426) → lange Sessions
    # (z.B. Skandal, 200 Utts) sprengen ctx_stage2=8192 und der Fakt-JSON wird
    # trunkiert (:parse_failed). Hoch genug setzen, damit Prompt + Fakt-Output
    # passen.
    if ctx = opts[:ctx], do: Worker.Settings.put(:ctx_stage2, ctx)

    try do
      if Keyword.get(opts, :reset, false), do: EvalBootstrap.reset_campaign(campaign_id)
      count = EvalBootstrap.materialize_fixture!(seed_dir)
      Mix.shell().info("· #{count} Events materialisiert (#{campaign_id})")

      campaign =
        Repo.get_campaign(campaign_id) ||
          Mix.raise("Campaign nicht materialisiert: #{campaign_id}")

      session_ids = Map.keys(fact_key["required_facts"]) |> Enum.sort()
      samples = max(Keyword.get(opts, :samples, 1), 1)
      decoys = fact_key["decoys"] || []

      Mix.shell().info(
        "=== Verify-Eval: #{campaign_slug} / #{model_label} / NLI=#{nli_model_label()} " <>
          "(#{length(session_ids)} Sessions, #{length(decoys)} Decoys, #{samples} Sample(s)) ==="
      )

      # Ein Sample = ein voller Extraktions-Durchlauf über alle Sessions; behält
      # facts+utterances je Session, damit der Sweep ohne Re-Extraktion auf
      # denselben Fakten messen kann (nur die Schwelle/das NLI variiert).
      samples_data =
        Enum.map(1..samples, fn i ->
          if samples > 1, do: Mix.shell().info("· Sample #{i}/#{samples} (Extraktion) …")
          measure_sample(session_ids, campaign, decoys)
        end)

      report = build_report(campaign_slug, model_label, samples_data)
      print_report(report, verbose?)

      if sweep?, do: run_sweep(List.last(samples_data))

      case opts[:output_baseline] do
        nil -> compare_against_baseline!(report, max_rel)
        path -> write_baseline!(report, path)
      end
    after
      EvalBootstrap.restore_stage2_model!(backup)
    end
  end

  # ─── Messung ────────────────────────────────────────────────────────────

  # Extrahiert pro Session die Fakten + baut die Decoy-Negativ-Paare; misst TPR/FPR
  # mit den AKTUELLEN Settings-Schwellen via Verify.nli_verify_one/2.
  defp measure_sample(session_ids, campaign, decoys) do
    per_session =
      Enum.map(session_ids, fn sid ->
        utterances = Repo.list_utterances(sid, limit: :all)
        facts = extract_facts!(sid, campaign, utterances)
        {sid, utterances, facts, decoy_facts(decoys, facts)}
      end)

    %{sessions: per_session, tpr: tpr_of(per_session), fpr: fpr_of(per_session)}
  end

  # Micro-Average über alle Sessions: Σ geerdete / Σ gesamt.
  defp tpr_of(per_session) do
    rate(per_session, fn {_s, utt, facts, _d} -> {grounded_count(facts, utt), length(facts)} end)
  end

  defp fpr_of(per_session) do
    rate(per_session, fn {_s, utt, _f, dfacts} ->
      {grounded_count(dfacts, utt), length(dfacts)}
    end)
  end

  defp extract_facts!(session_id, campaign, utterances) do
    cond do
      utterances == [] ->
        Mix.shell().error("  ⚠ Session #{session_id}: keine Utterances materialisiert")
        []

      true ->
        case Stages.extract_facts(utterances, session_id, campaign) do
          {:ok, facts} ->
            facts

          {:error, reason} ->
            Mix.raise("Extraktion für #{session_id} gescheitert: #{inspect(reason)}")
        end
    end
  end

  # Jeder Decoy wird ein synthetischer Fakt mit der VEREINIGUNG aller echten
  # source_refs der Session als Quelle — strengster FPR-Test (maximale Chance,
  # fälschlich verifiziert zu werden).
  defp decoy_facts(decoys, real_facts) do
    refs = real_facts |> Enum.flat_map(&(Map.get(&1, "source_refs") || [])) |> Enum.uniq()
    Enum.map(decoys, fn d -> %{"claim" => d, "source_refs" => refs} end)
  end

  defp grounded_count(facts, utterances) do
    Enum.count(facts, fn f -> Verify.nli_verify_one(f, utterances) == true end)
  end

  # Summiert {Zähler, Nenner} über alle Sessions → globale Rate (Micro-Average).
  defp rate(per_session, pair_fn) do
    {num, den} =
      Enum.reduce(per_session, {0, 0}, fn s, {n, d} ->
        {hits, total} = pair_fn.(s)
        {n + hits, d + total}
      end)

    if den > 0, do: num / den, else: 0.0
  end

  # ─── Report ─────────────────────────────────────────────────────────────

  defp build_report(campaign_slug, model_label, samples_data) do
    tprs = Enum.map(samples_data, & &1.tpr)
    fprs = Enum.map(samples_data, & &1.fpr)
    rep = List.last(samples_data)

    %{
      campaign: campaign_slug,
      model: model_label,
      nli_model: nli_model_label(),
      samples: length(samples_data),
      entail_min: Worker.Settings.get(:faithfulness_verify_entail_min, 0.5),
      max_contra: Worker.Settings.get(:faithfulness_verify_max_contra, 0.5),
      tpr_median: SummaryEval.median(tprs),
      tpr_range: {Enum.min(tprs), Enum.max(tprs)},
      fpr_median: SummaryEval.median(fprs),
      fpr_range: {Enum.min(fprs), Enum.max(fprs)},
      representative: rep
    }
  end

  defp print_report(report, verbose?) do
    Mix.shell().info("")
    Mix.shell().info("Schwelle: entail_min=#{report.entail_min} max_contra=#{report.max_contra}")

    Mix.shell().info(
      "TPR (echte Fakten geerdet) = #{pct(report.tpr_median)}" <>
        range_suffix(report.samples, report.tpr_range) <> "  (Soll: hoch)"
    )

    Mix.shell().info(
      "FPR (Decoys geerdet)       = #{pct(report.fpr_median)}" <>
        range_suffix(report.samples, report.fpr_range) <> "  (Soll: 0)"
    )

    if verbose? do
      Mix.shell().info("")

      Enum.each(report.representative.sessions, fn {sid, utt, facts, dfacts} ->
        g = grounded_count(facts, utt)
        d = grounded_count(dfacts, utt)

        Mix.shell().info(
          "── #{sid}: #{g}/#{length(facts)} Fakten geerdet, #{d}/#{length(dfacts)} Decoys geleakt ──"
        )
      end)
    end
  end

  # ─── Schwellen-Sweep ──────────────────────────────────────────────────────

  # Re-misst TPR/FPR über das Schwellen-Grid auf den BEREITS extrahierten Fakten
  # des repräsentativen Samples (NLI ist deterministisch → kein Re-Extrakt nötig).
  defp run_sweep(rep_sample) do
    backup = {
      Worker.Settings.get(:faithfulness_verify_entail_min, 0.5),
      Worker.Settings.get(:faithfulness_verify_max_contra, 0.5)
    }

    Mix.shell().info("")
    Mix.shell().info("── Schwellen-Sweep (repr. Sample) ──")
    Mix.shell().info("entail_min  max_contra   TPR      FPR")

    try do
      for em <- @sweep_entail, mc <- @sweep_contra do
        Worker.Settings.put(:faithfulness_verify_entail_min, em)
        Worker.Settings.put(:faithfulness_verify_max_contra, mc)

        tpr = tpr_of(rep_sample.sessions)
        fpr = fpr_of(rep_sample.sessions)
        Mix.shell().info("  #{pad(em)}       #{pad(mc)}        #{pct(tpr)}   #{pct(fpr)}")
      end
    after
      {em, mc} = backup
      Worker.Settings.put(:faithfulness_verify_entail_min, em)
      Worker.Settings.put(:faithfulness_verify_max_contra, mc)
    end
  end

  # ─── Baseline-Gate ──────────────────────────────────────────────────────

  defp compare_against_baseline!(report, max_rel) do
    base = get_in(EvalBootstrap.read_baselines(@baselines_path), [report.model, report.campaign])

    cond do
      is_nil(base) ->
        Mix.shell().info("")
        Mix.shell().info("⚠ Keine Baseline für #{report.model}/#{report.campaign}.")
        Mix.shell().info("  Schreibe mit --output-baseline #{@baselines_path}.")

      true ->
        check_tpr!(report, base, max_rel)
        check_fpr!(report, base)
        Mix.shell().info("")
        Mix.shell().info("✓ innerhalb Toleranz gegen Baseline.")
    end
  end

  defp check_tpr!(report, base, max_rel) do
    base_tpr = base["tpr"] || 0.0

    if report.tpr_median < base_tpr * (1.0 - max_rel) do
      Mix.raise(
        "TPR-Regression: Median=#{pct(report.tpr_median)} < " <>
          "Baseline=#{pct(base_tpr)} × (1 - #{max_rel})"
      )
    end
  end

  # FPR (Decoys) ist pro Decoy binär → bei <3 Samples flaky, nur warnen; bei ≥3
  # hart gaten (analog noise_leak #656).
  defp check_fpr!(report, base) do
    base_fpr = base["fpr"] || 0.0

    cond do
      report.fpr_median <= base_fpr ->
        :ok

      report.samples >= 3 ->
        Mix.raise(
          "FPR-Regression: Median=#{pct(report.fpr_median)} > Baseline=#{pct(base_fpr)} " <>
            "(#{report.samples} Samples → robust)"
        )

      true ->
        Mix.shell().info("")

        Mix.shell().error(
          "⚠ FPR gestiegen: Median=#{pct(report.fpr_median)} > Baseline=#{pct(base_fpr)} " <>
            "(kein harter Fail bei <3 Samples — mit --samples 3+ bestätigen)"
        )
    end
  end

  defp write_baseline!(report, path) do
    entry = %{
      "tpr" => Float.round(report.tpr_median, 4),
      "fpr" => Float.round(report.fpr_median, 4),
      "entail_min" => report.entail_min,
      "max_contra" => report.max_contra,
      "nli_model" => report.nli_model,
      "samples" => report.samples,
      "recorded_at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    EvalBootstrap.write_baseline!(path, [report.model, report.campaign], entry)
    Mix.shell().info("Baseline geschrieben: #{path}")
  end

  # ─── Helfer ────────────────────────────────────────────────────────────

  defp nli_model_label, do: Worker.Settings.get(:faithfulness_sidecar_url) || "offline"

  defp pct(rate), do: "#{Float.round(rate * 100, 1)} %"

  defp pad(f), do: :erlang.float_to_binary(f, decimals: 1)

  defp range_suffix(samples, _range) when samples <= 1, do: ""

  defp range_suffix(_samples, {min, max}),
    do: "  [#{pct(min)}–#{pct(max)}]"
end
