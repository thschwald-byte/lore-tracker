defmodule Worker.SummaryEval do
  @moduledoc """
  Stage-2-Treue-Scoring gegen einen Ground-Truth-Fact-Key (Issue #647, Folge #644).

  Konsumiert das `fact-key.json` eines Fidelity-Testsets (z.B.
  `apps/hub/priv/seeds/skandal-boehmen/fact-key.json`) und misst ein generiertes
  Resümee gegen die kanonische Wahrheit. Zwei Klassen von Metriken:

  ## Lexikalisch (reproduzierbar gescort)

    * `entity_recall/2` — Anteil der `required_entities`, deren kanonische Form
      oder eine Variante (normalisiert, Substring) im Resümee auftaucht.
    * `noise_leak/2` — Anzahl der `rule_noise_markers` (Würfel-/OOC-/Probenstrings),
      die fälschlich im Resümee gelandet sind. Soll 0 sein.

  Beide laufen rein lexikalisch über `Worker.MultiSourceEval.Normalize` — kein
  LLM. Die **Scoring-Funktion ist deterministisch**; der **gemessene Wert nicht**,
  weil der LLM-Output (das Resümee) run-to-run variiert. `entity_recall` ist über
  10 Entities relativ stabil und taugt als (relativ-toleranter) Gate; `noise_leak`
  ist binär pro Marker und damit zu flaky für einen harten Single-Run-Gate (siehe
  `Mix.Tasks.Lore.Eval.Summary`).

  ## Semantisch (Judge-Pass, optional, nicht hart gegatet)

    * `judge/3` — ein LLM-Grader entscheidet pro Session: welche `required_facts`
      sind im Resümee belegt (fact_recall), welche `decoys` werden behauptet
      (fabrication), welche `attribution_facts` sind der richtigen Figur
      zugeordnet (attribution_accuracy).

  **Reliabilitäts-Caveat:** Der Judge ist selbst ein LLM und damit fehlbar +
  nicht-deterministisch. Seine Zahlen sind Diagnostik/Trend, KEIN harter Gate —
  ein NLI-False-Negative darf keinen Merge röten. Gegatet wird nur das
  Lexikalische. (Dieselbe Disziplin wie der #651-Plan: messen vor blockieren,
  #557.)
  """

  alias Worker.MultiSourceEval.Normalize

  # ─── Deterministische Metriken ──────────────────────────────────────────

  @doc """
  Entity-Recall: Anteil der `required_entities`, die im `summary` vorkommen.

  Eine Entity gilt als getroffen, wenn ihre `canonical`-Form ODER eine ihrer
  `variants` (jeweils normalisiert) als Substring im normalisierten Resümee
  steht. Multi-Wort-Formen ("könig von böhmen") matchen als zusammenhängender
  Substring — robust gegen Groß/Klein + Interpunktion.
  """
  @spec entity_recall(String.t(), [map()]) :: map()
  def entity_recall(summary, required_entities)
      when is_binary(summary) and is_list(required_entities) do
    norm = Normalize.for_wer(summary)

    {recalled, missing} =
      Enum.split_with(required_entities, fn ent ->
        forms = [ent["canonical"] | List.wrap(ent["variants"])]
        Enum.any?(forms, &present?(norm, &1))
      end)

    total = length(required_entities)

    %{
      recalled: length(recalled),
      total: total,
      rate: ratio(length(recalled), total),
      missing: Enum.map(missing, & &1["canonical"])
    }
  end

  @doc """
  Noise-Leak: welche `rule_noise_markers` (Würfel/OOC/Proben) sind fälschlich
  im Resümee gelandet? Erwartung: keine. `hits` ist die gate-relevante Zahl.
  """
  @spec noise_leak(String.t(), [String.t()]) :: map()
  def noise_leak(summary, markers) when is_binary(summary) and is_list(markers) do
    norm = Normalize.for_wer(summary)

    leaked =
      markers
      |> Enum.filter(&present?(norm, &1))
      |> Enum.uniq()

    %{hits: length(leaked), markers: leaked}
  end

  # Normalisierter Substring-Test. Leere/Whitespace-Form matcht nie (sonst
  # würde "" überall treffen).
  defp present?(norm_text, form) when is_binary(form) do
    nf = Normalize.for_wer(form)
    nf != "" and String.contains?(norm_text, nf)
  end

  defp present?(_norm_text, _form), do: false

  defp ratio(_num, 0), do: 0.0
  defp ratio(num, denom), do: num / denom

  # ─── Judge-Pass (LLM, optional) ─────────────────────────────────────────

  @doc """
  LLM-Judge für die semantischen Metriken einer Session.

  `summary` — das generierte Resümee. `facts` — die `required_facts`-Liste
  dieser Session. `fact_key` — der volle Fact-Key (für `decoys` +
  `attribution_facts`).

  Gibt `{:ok, %{fact_recall, fabrication, attribution_accuracy, raw}}` oder
  `{:error, reason}`. Ein LLM-Call pro Session via dem `:summary`-Backend
  (konfigurierbar in `Worker.Settings`). Index-Listen statt aligned Bool-Arrays,
  weil LLMs darin verlässlicher sind; out-of-range-Indizes werden verworfen.

  NICHT-deterministisch — siehe Modul-Caveat. Nur für Diagnostik/Trend.
  """
  @spec judge(String.t(), [String.t()], map()) :: {:ok, map()} | {:error, term()}
  def judge(summary, facts, fact_key)
      when is_binary(summary) and is_list(facts) and is_map(fact_key) do
    decoys = fact_key["decoys"] || []
    attributions = fact_key["attribution_facts"] || []

    prompt = judge_prompt(summary, facts, decoys, attributions)
    opts = [format: judge_schema(), num_ctx: Worker.Settings.get(:ctx_stage2, 8192)]

    case Worker.LLM.complete(:summary, prompt, opts) do
      {:ok, raw} ->
        case Jason.decode(String.trim(raw)) do
          {:ok, decoded} ->
            {:ok, score_judge(decoded, facts, decoys, attributions)}

          {:error, _} ->
            {:error, {:judge_parse_failed, String.slice(raw, 0, 200)}}
        end

      {:error, reason} ->
        {:error, {:judge_llm_failed, reason}}
    end
  end

  defp score_judge(decoded, facts, decoys, attributions) do
    covered = clamp_indices(decoded["covered_fact_indices"], length(facts))
    asserted = clamp_indices(decoded["asserted_decoy_indices"], length(decoys))
    correct_attr = clamp_indices(decoded["correct_attribution_indices"], length(attributions))

    %{
      fact_recall: %{
        covered: MapSet.size(covered),
        total: length(facts),
        rate: ratio(MapSet.size(covered), length(facts)),
        missing: missing_texts(facts, covered)
      },
      fabrication: %{
        asserted: MapSet.size(asserted),
        total: length(decoys),
        # Niedriger ist besser: jede behauptete Decoy ist eine Halluzination.
        asserted_decoys: select_texts(decoys, asserted)
      },
      attribution_accuracy: %{
        correct: MapSet.size(correct_attr),
        total: length(attributions),
        rate: ratio(MapSet.size(correct_attr), length(attributions))
      },
      raw: decoded
    }
  end

  defp clamp_indices(list, len) when is_list(list) do
    list
    |> Enum.filter(&(is_integer(&1) and &1 >= 0 and &1 < len))
    |> MapSet.new()
  end

  defp clamp_indices(_other, _len), do: MapSet.new()

  defp missing_texts(facts, covered_set) do
    facts
    |> Enum.with_index()
    |> Enum.reject(fn {_f, i} -> MapSet.member?(covered_set, i) end)
    |> Enum.map(fn {f, _i} -> f end)
  end

  defp select_texts(items, set) do
    items
    |> Enum.with_index()
    |> Enum.filter(fn {_x, i} -> MapSet.member?(set, i) end)
    |> Enum.map(fn {x, _i} -> attribution_label(x) end)
  end

  defp attribution_label(%{"character" => c, "claim" => claim}), do: "#{c}: #{claim}"
  defp attribution_label(text) when is_binary(text), do: text
  defp attribution_label(other), do: inspect(other)

  defp judge_prompt(summary, facts, decoys, attributions) do
    fact_lines = numbered(facts)
    decoy_lines = numbered(decoys)
    attr_lines = numbered(Enum.map(attributions, &attribution_label/1))

    """
    Du bewertest die FAKTENTREUE eines Spielsitzungs-Resümees gegen eine
    Wahrheitsliste. Antworte NUR mit JSON gemäß Schema. Sei streng: zähle einen
    Fakt nur als belegt, wenn das Resümee ihn klar aussagt oder eindeutig
    impliziert — nicht bei vager Andeutung.

    RESÜMEE:
    #{summary}

    PFLICHT-FAKTEN (Index → Fakt). Welche sind im Resümee belegt?
    #{fact_lines}

    DECOYS (Index → Falschbehauptung). Welche davon behauptet das Resümee als wahr?
    (Korrektes Resümee behauptet KEINE davon.)
    #{decoy_lines}

    ATTRIBUTIONEN (Index → "Figur: Aussage"). Bei welchen ordnet das Resümee die
    Aussage der GENANNTEN Figur korrekt zu? (Falsche Figur oder gar nicht erwähnt
    zählt NICHT als korrekt.)
    #{attr_lines}

    Gib die Indizes der belegten Fakten, der behaupteten Decoys und der korrekt
    attribuierten Aussagen zurück.
    """
  end

  defp numbered([]), do: "(keine)"

  defp numbered(items) do
    items
    |> Enum.with_index()
    |> Enum.map(fn {item, i} -> "#{i}: #{item}" end)
    |> Enum.join("\n")
  end

  defp judge_schema do
    %{
      "type" => "object",
      "properties" => %{
        "covered_fact_indices" => %{"type" => "array", "items" => %{"type" => "integer"}},
        "asserted_decoy_indices" => %{"type" => "array", "items" => %{"type" => "integer"}},
        "correct_attribution_indices" => %{"type" => "array", "items" => %{"type" => "integer"}}
      },
      "required" => [
        "covered_fact_indices",
        "asserted_decoy_indices",
        "correct_attribution_indices"
      ]
    }
  end
end
