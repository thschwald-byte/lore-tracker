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

  ## Wichtig: nur messen, kein Gate (Slice A)

  Diese Task **gatet nicht** — sie reportet. Sie misst die
  **Roh-Extraktions-Labels** (was der Extraktor pro Fakt als `thread` ausgibt),
  BEVOR die ThreadRegistry (Slice C) sie clustert und der Reader (Slice D1) sie
  produktiv gruppiert. Das ist der Measure-First-Anker (#557): der Wert bewegt
  sich, sobald der Extraktions-Prompt (Slice B) verbessert wird. Das harte Gate
  (thread_recall-Floor, false_merge/false_resolve = 0) kommt in Slice E, sobald
  reale Zahlen die robusten Metriken zeigen.

  **Vor Slice B** trägt die Extraktion noch KEIN `thread`-Feld → jeder Fakt
  landet ungruppiert → ehrlicher Null-Report (thread_recall 0 %). Das ist
  erwartet und bestätigt, dass die Task korrekt verdrahtet ist; sie „leuchtet",
  sobald Slice B das Feld liefert.

  ## Verwendung

      mix lore.eval.threads                            # default: skandal-boehmen
      mix lore.eval.threads --campaign skandal-boehmen --verbose
      mix lore.eval.threads --model qwen2.5:7b         # explizites Extraktor-Modell
      mix lore.eval.threads --reset                    # Campaign vorher löschen

  ## Voraussetzungen

    * Ollama läuft + das `--model`-Modell ist gepullt (default-Backend `:local`).
    * Das Fixture ist unter `apps/hub/priv/seeds/<campaign>/` committed (#644)
      und sein `fact-key.json` hat die drei Thread-Blöcke (#830).

  Refuses :prod.
  """

  use Mix.Task

  alias Worker.Recording.Pipeline.Stages
  alias Worker.{EvalBootstrap, Repo, ThreadEval}

  @shortdoc "Wahrheitsbild-Handlungsbogen-Eval gegen die Thread-Blöcke des Fact-Keys"

  @seeds_root "apps/hub/priv/seeds"
  @default_campaign "skandal-boehmen"

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
          ctx: :integer
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

    try do
      if Keyword.get(opts, :reset, false), do: EvalBootstrap.reset_campaign(campaign_id)
      count = EvalBootstrap.materialize_fixture!(seed_dir)
      Mix.shell().info("· #{count} Events materialisiert (#{campaign_id})")

      campaign =
        Repo.get_campaign(campaign_id) ||
          Mix.raise("Campaign nicht materialisiert: #{campaign_id}")

      session_ids = fact_key["required_facts"] |> Map.keys() |> Enum.sort()

      Mix.shell().info(
        "=== Thread-Eval: #{campaign_slug} / #{model_label} (#{length(session_ids)} Sessions) ==="
      )

      # Fakten campaign-weit sammeln — Handlungsbögen spannen über Sessions.
      produced_facts = Enum.flat_map(session_ids, &extract_session_facts(&1, campaign))
      report = ThreadEval.score(produced_facts, fact_key)
      print_report(report, produced_facts, verbose?)
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

  defp print_report(r, produced_facts, verbose?) do
    Mix.shell().info("")

    Mix.shell().info(
      "· #{r.total_fact_count} Fakten extrahiert, #{r.grouped_fact_count} mit thread-Label " <>
        "in #{r.produced_threads} Strängen"
    )

    if r.grouped_fact_count == 0 do
      Mix.shell().info("")

      Mix.shell().info(
        "⚠ Kein einziger Fakt trägt ein `thread`-Label → Null-Report. " <>
          "Erwartet vor Slice B (Extraktion emittiert `thread` noch nicht)."
      )
    end

    Mix.shell().info("")
    tr = r.thread_recall
    Mix.shell().info("thread_recall   = #{pct(tr.rate)} (#{tr.recalled}/#{tr.total})")
    if tr.missing != [], do: Mix.shell().info("  fehlend: #{Enum.join(tr.missing, ", ")}")

    fr = r.fragmentation

    Mix.shell().info(
      "fragmentation   = #{Float.round(fr.mean_labels_per_thread, 2)} Labels/Strang " <>
        "(Soll 1.0), #{fr.fragmented} fragmentiert"
    )

    Enum.each(fr.per_thread, fn {canon, n} ->
      if n > 1, do: Mix.shell().info("  #{canon}: #{n} Labels")
    end)

    fm = r.false_merge
    Mix.shell().info("false_merge     = #{pct(fm.rate)} (#{fm.violated}/#{fm.total} Paare)")

    Enum.each(fm.details, fn d ->
      if d.violated do
        Mix.shell().info("  #{Enum.join(d.pair, " + ")} ← #{Enum.join(d.offending_labels, ", ")}")
      end
    end)

    frs = r.false_resolve
    Mix.shell().info("false_resolve   = #{pct(frs.rate)} (#{frs.violated}/#{frs.total} Stränge)")

    Enum.each(frs.details, fn d ->
      if d.resolved_flagged,
        do: Mix.shell().info("  #{d.thread}: fälschlich als aufgelöst geflaggt")
    end)

    if verbose? do
      Mix.shell().info("")
      Mix.shell().info("Produzierte thread-Labels (roh):")

      produced_facts
      |> Enum.map(&Map.get(&1, "thread"))
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.frequencies()
      |> Enum.sort_by(fn {_l, n} -> -n end)
      |> Enum.each(fn {label, n} -> Mix.shell().info("  #{n}×  #{label}") end)
    end
  end

  defp pct(rate), do: "#{Float.round(rate * 100, 1)} %"
end
