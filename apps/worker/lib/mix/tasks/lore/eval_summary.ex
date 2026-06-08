defmodule Mix.Tasks.Lore.Eval.Summary do
  @moduledoc """
  Stage-2-Treue-Eval gegen ein Fidelity-Testset + Fact-Key (Issue #647, Folge #644).

  Materialisiert ein geseedetes Fixture (JSONL unter
  `apps/hub/priv/seeds/<campaign>/`) in eine frische Worker-Mnesia, treibt die
  **echte** Stage 2 (`Worker.Recording.Pipeline.Stages.stage2/3`, inkl.
  Map-Reduce #417) pro Session — kein Audio, kein Hub-Roundtrip — und scort den
  Output gegen `fact-key.json`:

    * **entity_recall** (deterministisch) — Anteil der Pflicht-Entities im Resümee.
    * **noise_leak** (deterministisch) — Würfel-/OOC-/Proben-Strings, die nicht
      ins Resümee gehören. Soll 0 sein.
    * **fact_recall / fabrication / attribution_accuracy** (Judge-Pass, nur mit
      `--judge`) — LLM-Grader, NICHT-deterministisch, nur Diagnostik.

  Weil der Eval die echte Pipeline-Stage-2 treibt, bewegt sich der Score, sobald
  der Stage-2-Prompt verbessert wird — genau der Measure-First-Loop für die
  #651-Phase-0-Baseline.

  ## Verwendung

      mix lore.eval.summary                                   # default: skandal-boehmen, Gate gegen baselines.json
      mix lore.eval.summary --campaign skandal-boehmen --verbose
      mix lore.eval.summary --model qwen2.5:7b                # explizites Stage-2-Modell
      mix lore.eval.summary --judge                           # + LLM-Judge für fact_recall/attribution
      mix lore.eval.summary --samples 3                        # 3 Stage-2-Durchläufe → Median (LLM-Rauschen)
      mix lore.eval.summary --model command-r:35b-08-2024-q4_K_M --timeout-min 45   # langsames Modell: Per-Call-Timeout hoch
      mix lore.eval.summary --max-rel-degradation 0.2         # exit 1 bei entity_recall-Drop > 20 %
      mix lore.eval.summary --output-baseline apps/worker/test/fixtures/summary_eval/baselines.json

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

    * Ollama läuft + das Stage-2-Modell ist gepullt (default-Backend `:local`).
    * Das Fixture ist unter `apps/hub/priv/seeds/<campaign>/` committed (#644).

  Refuses :prod.
  """

  use Mix.Task

  alias Worker.Recording.Pipeline.Stages
  alias Worker.{Repo, Settings, SummaryEval}

  @shortdoc "Stage-2-Treue-Eval gegen Fact-Key + Gate auf baselines.json"

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
    fact_key = load_fact_key(seed_dir)
    campaign_id = Map.fetch!(fact_key, "campaign_id")

    bootstrap_worker!()
    {backup, model_label} = apply_model!(opts[:model])

    # Issue #660: der Eval-Worker erbt sonst den 10-min-`http_timeout_ms`-Default.
    # Langsame/große Prod-Modelle (z.B. command-r:35b auf knapper GPU) reißen den
    # pro Map-Reduce-Chunk-Call → all_chunks_failed (spurious, kein Modell-/Prompt-
    # Fehler). Großzügiger Per-Call-Timeout, damit slow-but-correct durchläuft.
    timeout_ms = max(Keyword.get(opts, :timeout_min, 30), 1) * 60_000
    Worker.Settings.put(:http_timeout_ms, timeout_ms)
    Mix.shell().info("· http_timeout_ms = #{div(timeout_ms, 60_000)} min/Call")

    try do
      if Keyword.get(opts, :reset, false), do: reset_campaign(campaign_id)
      materialize_fixture!(seed_dir, campaign_id)

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

      # Issue #656: N Stage-2-Durchläufe → Median statt Einzel-Zufallswert
      # (LLM-Output ist nicht-deterministisch). Jedes Sample = ein voller
      # Lauf über alle Sessions.
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
      restore_model!(backup)
    end
  end

  # ─── Bootstrap (gespiegelt von lore.eval.multisource) ───────────────────

  defp bootstrap_worker! do
    :ok = Shared.Mnesia.ensure_started!()
    :ok = Worker.Schema.Mnesia.bootstrap!()

    # paired? muss true sein, damit Worker.Application Materializer/Pipeline
    # startet. Fake-Token; HubClient-WS scheitert in der Reconnect-Loop — egal,
    # Intents.publish hat den Local-Apply-Fallback.
    if Repo.get_state(:hub_token) == nil,
      do: Repo.put_state(:hub_token, "eval-fake-token-#{System.unique_integer([:positive])}")

    if Repo.get_state(:worker_id) == nil,
      do: Repo.put_state(:worker_id, "eval-worker-#{System.unique_integer([:positive])}")

    if Repo.get_state(:hub_base_url) == nil,
      do: Repo.put_state(:hub_base_url, "http://127.0.0.1:1")

    Application.put_env(:worker, :no_browser, true)
    {:ok, _} = Application.ensure_all_started(:worker)
    :ok
  end

  defp apply_model!(model_override) do
    backup = %{
      backend_stage2: Settings.get(:backend_stage2, :local),
      model_stage2: Settings.get(:model_stage2)
    }

    Settings.put(:backend_stage2, :local)

    model_label =
      case model_override do
        nil ->
          Settings.get(:model_stage2) || "default"

        m ->
          Settings.put(:model_stage2, m)
          m
      end

    {backup, model_label}
  end

  defp restore_model!(backup) do
    Settings.put(:backend_stage2, backup.backend_stage2)
    if backup.model_stage2, do: Settings.put(:model_stage2, backup.model_stage2)
  end

  # ─── Fixture-Materialisierung ───────────────────────────────────────────

  defp load_fact_key(seed_dir) do
    path = Path.join(seed_dir, "fact-key.json")

    case File.read(path) do
      {:ok, raw} -> Jason.decode!(raw)
      {:error, _} -> Mix.raise("Fact-Key nicht gefunden: #{path}")
    end
  end

  defp materialize_fixture!(seed_dir, campaign_id) do
    files =
      seed_dir
      |> Path.join("*.jsonl")
      |> Path.wildcard()
      |> Enum.sort()

    if files == [], do: Mix.raise("Keine *.jsonl im Fixture: #{seed_dir}")

    count =
      files
      |> Enum.flat_map(&read_jsonl/1)
      |> Enum.reduce(0, fn payload, acc ->
        apply_local!(payload)
        acc + 1
      end)

    Mix.shell().info("· #{count} Events materialisiert (#{campaign_id})")
  end

  defp read_jsonl(path) do
    path
    |> File.stream!()
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&Jason.decode!/1)
  end

  defp apply_local!(payload) when is_map(payload) do
    ts =
      payload["timestamp"] || payload["started_at"] || payload["ended_at"] ||
        payload["scheduled_for"] || DateTime.to_iso8601(DateTime.utc_now())

    :ok =
      Worker.Materializer.apply_local(%{
        "event_id" => UUIDv7.generate(),
        "payload" => payload,
        "ts" => ts,
        "author_worker_id" => nil
      })
  end

  defp reset_campaign(campaign_id) do
    apply_local!(%{
      "kind" => Shared.Events.campaign_deleted(),
      "id" => campaign_id,
      "campaign_id" => campaign_id
    })
  end

  # ─── Stage-2-Treiber ────────────────────────────────────────────────────

  defp run_stage2!(session_id, campaign) do
    utterances = Repo.list_utterances(session_id, limit: :all)

    if utterances == [] do
      Mix.shell().error("  ⚠ Session #{session_id}: keine Utterances materialisiert")
      ""
    else
      case Stages.stage2(utterances, session_id, campaign) do
        {:ok, %{content_md: md}} -> md
        {:error, reason} -> Mix.raise("Stage 2 für #{session_id} gescheitert: #{inspect(reason)}")
      end
    end
  end

  # ─── Report ─────────────────────────────────────────────────────────────

  # Ein Sample = ein voller Stage-2-Durchlauf über alle Sessions + lexikalisches
  # Scoring. Reine Listen/Floats, damit run/1 N davon sammeln + aggregieren kann.
  defp measure_sample(session_ids, campaign, entities, noise_markers) do
    summaries = Enum.map(session_ids, fn sid -> {sid, run_stage2!(sid, campaign)} end)
    full = summaries |> Enum.map(&elem(&1, 1)) |> Enum.join("\n\n")

    per_session_noise =
      Enum.map(summaries, fn {sid, md} -> {sid, SummaryEval.noise_leak(md, noise_markers)} end)

    %{
      summaries: summaries,
      full_summary: full,
      entity_recall: SummaryEval.entity_recall(full, entities),
      noise_total: per_session_noise |> Enum.map(fn {_s, n} -> n.hits end) |> Enum.sum(),
      per_session_noise: per_session_noise
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
      judge: judge
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

    if verbose? do
      Mix.shell().info("")
      Mix.shell().info("Resümees:")

      Enum.each(report.summaries, fn {sid, md} ->
        Mix.shell().info("── #{sid} ──")
        Mix.shell().info(md)
      end)
    end
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
    base = get_in(read_baselines(@baselines_path), [report.model, report.campaign])

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
    existing = read_baselines(path)

    entry = %{
      "entity_recall" => Float.round(report.entity_recall_median, 4),
      "noise_leak" => report.noise_median,
      "samples" => report.samples,
      "recorded_at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    updated = put_in_safe(existing, [report.model, report.campaign], entry)

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(updated, pretty: true) <> "\n")
    Mix.shell().info("Baseline geschrieben: #{path}")
  end

  defp read_baselines(path) do
    case File.read(path) do
      {:ok, raw} -> Jason.decode!(raw)
      {:error, :enoent} -> %{}
    end
  end

  defp put_in_safe(map, [k], v), do: Map.put(map, k, v)

  defp put_in_safe(map, [k | rest], v) do
    Map.put(map, k, put_in_safe(Map.get(map, k, %{}), rest, v))
  end
end
