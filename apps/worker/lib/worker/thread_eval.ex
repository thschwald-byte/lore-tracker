defmodule Worker.ThreadEval do
  @moduledoc """
  Handlungsbogen-Treue-Scoring gegen einen Ground-Truth-Fact-Key (Issue #830,
  Slice A des Epic #829). Das Gegenstück zu `Worker.SummaryEval`, nur für die
  **Erzählstruktur** statt der Resümee-Faktentreue.

  Konsumiert die neuen `threads` / `must_not_merge_threads` / `must_not_resolve`
  Blöcke eines Fidelity-Fact-Keys (z.B.
  `apps/hub/priv/seeds/skandal-boehmen/fact-key.json`) und misst eine
  **produzierte Fakten-Gruppierung** — eine Liste extrahierter Fakten mit
  (rohem) `thread`-Label + optionalem `fact_type` — gegen die kanonischen
  Soll-Stränge. Vier deterministische lexikalische Metriken:

    * `thread_recall` — Anteil der Soll-Stränge, für die es mindestens einen
      passenden produzierten Strang gibt.
    * `fragmentation` — wie viele DISTINKTE produzierte Labels denselben
      Soll-Strang abdecken (1.0 = perfekt; >1 = das Extraktor-Label-Inkonsistenz-
      Risiko). Das Kern-Signal, gegen das der Extraktions-Prompt (Slice B) und
      die ThreadRegistry (Slice C) getunt werden.
    * `false_merge` — verletzt ein einzelner produzierter Strang ein
      `must_not_merge`-Paar (matcht BEIDE Soll-Stränge)?
    * `false_resolve` — trägt der produzierte Gegenpart eines `must_not_resolve`-
      Strangs ein Auflösungs-Flag (`fact_type == "auflösung"`)?

  ## Matching-Semantik (label-primär, unterscheidende-Entität-sekundär)

  Ein produzierter Strang matcht einen Soll-Strang, wenn ENTWEDER sein
  normalisiertes Label mit `canonical`/`label_variants` überlappt (Substring in
  beide Richtungen) ODER seine Entitäten eine **unterscheidende** Entität des
  Soll-Strangs treffen (eine Entität, die in genau EINEM Soll-Strang
  `core_entities` steht). Produzierte Entitäten werden über die
  `required_entities`-Varianten-Map (dieselbe wie `SummaryEval.entity_recall`)
  auf ihre kanonische Form gezogen — gescannt wird der `claim`-Text + der
  `character_alias` (der Sprecher allein ist zu dünn).

  Der Entity-Sekundär-Pfad zählt bewusst nur **unterscheidende** Entitäten:
  ubiquitäre Kern-Figuren (Holmes/Irene tauchen in fast jedem Strang auf) würden
  sonst jeden Strang mit jedem matchen. Ein Soll-Strang OHNE unterscheidende
  Entität (z.B. „Irenes Gegenspiel" — Irene+Holmes stehen auch in „Erpressung")
  kann folglich NUR über sein Label erkannt werden — was korrekt ist: fehlt das
  Label, ist es ein echter Recall-Miss.

  ## Ehrliche Grenze (deterministisch vs. semantisch)

  `false_merge` ist für ein **entity-untrennbares** Paar (wie Erpressung ↔
  Gegenspiel im Skandal-Set) deterministisch nur eingeschränkt detektierbar: ein
  realer Ein-Label-Merge trägt EIN Label und absorbiert die Fakten des zweiten
  Strangs, ohne dass Label oder unterscheidende Entität das sichtbar machen —
  das braucht eine semantische Fakt-Zuordnung (Judge, spätere Arbeit, Muster
  `SummaryEval.judge/3`). Der deterministische `false_merge` hier fängt die
  **label-/entity-sichtbaren** Merges (ein Strang matcht beide Paar-Glieder);
  den subtilen Fall meldet er NICHT. Wie bei `SummaryEval` gilt: die
  lexikalischen Zahlen sind reproduzierbar gescort, der gemessene WERT variiert
  run-to-run mit dem LLM-Output → die Gate-Entscheidung (Slice E) mittelt über
  `--samples` und gatet nur die robusten Metriken.
  """

  alias Worker.MultiSourceEval.Normalize

  @doc """
  Volles Thread-Scoring einer produzierten Fakten-Liste gegen den Fact-Key.

  `produced_facts` — Liste von Fakt-Maps mit (mindestens) `"claim"`; optional
  `"character_alias"`, `"thread"` (rohes Label), `"fact_type"`. Fakten ohne
  nicht-leeres `thread`-Label werden für die Thread-Metriken ignoriert (aber in
  `total_fact_count` gezählt) — vor Slice B (kein `thread`-Feld) liefert das
  einen ehrlichen Null-Report.
  """
  @spec score([map()], map()) :: map()
  def score(produced_facts, fact_key) when is_list(produced_facts) and is_map(fact_key) do
    entities = fact_key["required_entities"] || []
    gt_threads = fact_key["threads"] || []
    must_not_merge = fact_key["must_not_merge_threads"] || []
    must_not_resolve = fact_key["must_not_resolve"] || []

    distinguishing = distinguishing_entities(gt_threads)
    produced = group_threads(produced_facts, entities)
    matches = build_match_index(produced, gt_threads, distinguishing)

    grouped = produced |> Enum.map(& &1.fact_count) |> Enum.sum()

    %{
      thread_recall: thread_recall(gt_threads, matches),
      fragmentation: fragmentation(gt_threads, matches),
      false_merge: false_merge(must_not_merge, produced, gt_threads, distinguishing),
      false_resolve: false_resolve(must_not_resolve, gt_threads, matches),
      produced_threads: length(produced),
      grouped_fact_count: grouped,
      total_fact_count: length(produced_facts)
    }
  end

  # ─── Produzierte Gruppierung ────────────────────────────────────────────

  @doc """
  Gruppiert produzierte Fakten nach ihrem rohen (getrimmten, nicht-leeren)
  `thread`-Label. Public für den Unit-Test der Gruppierung ohne Pipeline.
  """
  @spec group_threads([map()], [map()]) :: [map()]
  def group_threads(facts, entities) when is_list(facts) and is_list(entities) do
    facts
    |> Enum.group_by(&thread_label/1)
    |> Enum.reject(fn {label, _} -> label == "" end)
    |> Enum.map(fn {label, group} ->
      ents =
        group
        |> Enum.flat_map(fn f -> entities_in(fact_text(f), entities) end)
        |> MapSet.new()

      %{
        label: label,
        entities: ents,
        resolved: Enum.any?(group, &(fact_type(&1) == "auflösung")),
        fact_count: length(group)
      }
    end)
  end

  defp thread_label(f), do: f |> Map.get("thread") |> trim_or_empty()
  defp fact_type(f), do: f |> Map.get("fact_type") |> trim_or_empty() |> String.downcase()

  defp fact_text(f) do
    "#{Map.get(f, "claim", "")} #{Map.get(f, "character_alias", "")}"
  end

  # Kanonische Entitäten, deren `canonical` ODER eine Variante im Text steht.
  defp entities_in(text, entities) do
    norm = Normalize.for_wer(text)

    for ent <- entities,
        forms = [ent["canonical"] | List.wrap(ent["variants"])],
        Enum.any?(forms, &present?(norm, &1)),
        do: ent["canonical"]
  end

  # ─── Matching ───────────────────────────────────────────────────────────

  @doc """
  Pro Soll-Strang die Menge der unterscheidenden Entitäten: `core_entities`, die
  in genau EINEM Soll-Strang stehen. Public für den Unit-Test.
  """
  @spec distinguishing_entities([map()]) :: %{optional(String.t()) => MapSet.t()}
  def distinguishing_entities(gt_threads) when is_list(gt_threads) do
    counts =
      Enum.reduce(gt_threads, %{}, fn t, acc ->
        Enum.reduce(core_entities(t), acc, fn e, a -> Map.update(a, e, 1, &(&1 + 1)) end)
      end)

    Map.new(gt_threads, fn t ->
      dist = t |> core_entities() |> Enum.filter(&(counts[&1] == 1)) |> MapSet.new()
      {t["canonical"], dist}
    end)
  end

  defp core_entities(t), do: t["core_entities"] || []

  @doc """
  Matcht ein produzierter Strang einen Soll-Strang? `dist` ist die
  unterscheidende-Entität-Menge des Soll-Strangs. Public für den Unit-Test.
  """
  @spec match?(map(), map(), MapSet.t()) :: boolean()
  def match?(produced, gt_thread, %MapSet{} = dist) do
    label_match?(produced.label, gt_thread) or
      not MapSet.disjoint?(produced.entities, dist)
  end

  defp label_match?(label, gt_thread) do
    l = Normalize.for_wer(label)

    if l == "" do
      false
    else
      variants = [gt_thread["canonical"] | List.wrap(gt_thread["label_variants"])]

      Enum.any?(variants, fn v ->
        nv = Normalize.for_wer(v)
        nv != "" and (String.contains?(l, nv) or String.contains?(nv, l))
      end)
    end
  end

  defp build_match_index(produced, gt_threads, distinguishing) do
    Map.new(gt_threads, fn gt ->
      canon = gt["canonical"]
      dist = Map.get(distinguishing, canon, MapSet.new())
      {canon, Enum.filter(produced, &match?(&1, gt, dist))}
    end)
  end

  # ─── Metriken ───────────────────────────────────────────────────────────

  defp thread_recall(gt_threads, matches) do
    total = length(gt_threads)
    recalled = Enum.count(gt_threads, fn gt -> matches[gt["canonical"]] != [] end)

    %{
      recalled: recalled,
      total: total,
      rate: ratio(recalled, total),
      missing: for(gt <- gt_threads, matches[gt["canonical"]] == [], do: gt["canonical"])
    }
  end

  # Fragmentierung: distinkte produzierte Labels je (erkanntem) Soll-Strang.
  # mean_labels_per_thread = 1.0 ideal; fragmented_rate = Anteil der erkannten
  # Stränge mit >1 Label (0.0 ideal).
  defp fragmentation(gt_threads, matches) do
    per =
      for gt <- gt_threads, matched = matches[gt["canonical"]], matched != [] do
        n = matched |> Enum.map(& &1.label) |> Enum.uniq() |> length()
        {gt["canonical"], n}
      end

    ns = Enum.map(per, &elem(&1, 1))
    recalled = length(per)

    %{
      mean_labels_per_thread: mean(ns),
      fragmented: Enum.count(ns, &(&1 > 1)),
      fragmented_rate: ratio(Enum.count(ns, &(&1 > 1)), recalled),
      recalled: recalled,
      per_thread: per
    }
  end

  # false_merge: ein einzelner produzierter Strang matcht BEIDE Glieder eines
  # must_not_merge-Paars. Siehe Modul-Grenze — fängt label-/entity-sichtbare
  # Merges, nicht den subtilen Ein-Label-Merge eines entity-untrennbaren Paars.
  defp false_merge(pairs, produced, gt_threads, distinguishing) do
    gt_by_canon = Map.new(gt_threads, &{&1["canonical"], &1})

    results =
      for pair <- pairs,
          [a, b] = pair_members(pair),
          gt_a = gt_by_canon[a],
          gt_b = gt_by_canon[b] do
        dist_a = Map.get(distinguishing, a, MapSet.new())
        dist_b = Map.get(distinguishing, b, MapSet.new())

        offenders =
          for p <- produced,
              match?(p, gt_a, dist_a) and match?(p, gt_b, dist_b),
              do: p.label

        %{pair: [a, b], violated: offenders != [], offending_labels: Enum.uniq(offenders)}
      end

    violated = Enum.count(results, & &1.violated)

    %{
      violated: violated,
      total: length(results),
      rate: ratio(violated, length(results)),
      details: results
    }
  end

  # false_resolve: der produzierte Gegenpart eines must_not_resolve-Strangs trägt
  # ein Auflösungs-Flag (irgendein Fakt fact_type=="auflösung").
  defp false_resolve(entries, gt_threads, matches) do
    valid_canons = MapSet.new(gt_threads, & &1["canonical"])

    results =
      for e <- entries, canon = mnr_thread(e), MapSet.member?(valid_canons, canon) do
        resolved? = matches[canon] |> List.wrap() |> Enum.any?(& &1.resolved)
        %{thread: canon, resolved_flagged: resolved?}
      end

    violated = Enum.count(results, & &1.resolved_flagged)

    %{
      violated: violated,
      total: length(results),
      rate: ratio(violated, length(results)),
      details: results
    }
  end

  # ─── Fact-Key-Shape-Toleranz ────────────────────────────────────────────

  # must_not_merge: {"pair" => [a, b]} ODER blank [a, b].
  defp pair_members(%{"pair" => [a, b]}), do: [a, b]
  defp pair_members([a, b]), do: [a, b]
  defp pair_members(_), do: []

  # must_not_resolve: {"thread" => canon} ODER blanker String.
  defp mnr_thread(%{"thread" => canon}) when is_binary(canon), do: canon
  defp mnr_thread(canon) when is_binary(canon), do: canon
  defp mnr_thread(_), do: nil

  # ─── Helfer ─────────────────────────────────────────────────────────────

  defp present?(norm_text, form) when is_binary(form) do
    nf = Normalize.for_wer(form)
    nf != "" and String.contains?(norm_text, nf)
  end

  defp present?(_norm_text, _form), do: false

  defp trim_or_empty(s) when is_binary(s), do: String.trim(s)
  defp trim_or_empty(_), do: ""

  defp ratio(_num, 0), do: 0.0
  defp ratio(num, denom), do: num / denom

  defp mean([]), do: 0.0
  defp mean(values), do: Enum.sum(values) / length(values)
end
