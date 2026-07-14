defmodule Worker.VerifyEval do
  @moduledoc """
  Reines TPR/FPR-Scoring des Verify-Gates (Grounding + Attribution) gegen einen
  **gelabelten** Fakt-Satz — Epic #854 Slice 1 (#856).

  Zwei Konsumenten teilen sich diesen Scorer (die Wiederverwendung, die #854 erst
  ermöglicht, statt den Scorer privat in `mix lore.eval.verify` vergraben zu
  lassen):

    1. **`mix lore.eval.verify`** — extrahiert Fakten aus dem Fixture, baut per
       `decoy_facts/2` Negativ-Paare (Word-Overlap-Matcher `best_match_refs/2`)
       und mittelt via `micro/2` (der klassische Zwei-Phasen-Pfad).
    2. **Der GUI-Judge-Sweep** (`Worker.Probelauf`, Slice 1) — nimmt einen
       **kuratierten, hand-gelabelten** Fakt-Satz (harte Positive + Decoys, jeder
       mit echten `source_refs`) und scort via `score/4` einen Judge-Kandidaten.

  ## `score/4` — kuratierter Satz, beide Achsen

  Positive (sollen `verified?`) + Decoys (sollen NICHT) laufen in **einem**
  `Verify.verify_facts/3`-Pass (damit `alias_groups/1` über den ganzen Satz
  spannt), dann nach Label gesplittet:

    * **TPR** = Anteil Positive mit `verified?` — hoch = der Judge hält echte Fakten.
    * **FPR** = Anteil Decoys mit `verified?` — nahe 0 = der Judge lehnt Fabrikationen ab.
    * `grounded?`/`attributed?` werden pro Seite **getrennt** ausgewiesen (die
      Attributions-Achse ist unterkalibriert; getrennt sieht man's, statt sie im
      `verified?`-Aggregat zu verstecken — #762).

  Das Kandidaten-Modell reitet **scoped** über die injizierten `ground_fn`/`attr_fn`
  in `opts` (Slice 0, #855) — `score/4` schreibt selbst NIE Settings.

  Rein bis auf die LLM-I/O, die IN den übergebenen `ground_fn`/`attr_fn` sitzt →
  mit Stub-Judges (immer-true/immer-false) deterministisch testbar.
  """

  alias Worker.Recording.Pipeline.Verify

  @label_key "__verifyeval_label__"

  @typedoc "Ein gelabelter Fakt trägt zusätzlich claim/character_alias/entity_id/source_refs."
  @type fact :: map()

  @doc """
  Scort einen Judge über einen kuratierten Satz. `opts` fließt 1:1 an
  `Verify.verify_facts/3` (`:ground_fn`, `:attr_fn`, `:speaker_names`) — hier
  injiziert der Sweep den Kandidaten-Judge (`model:`/`endpoint:` via Slice 0).

  Gibt TPR/FPR über `verified?` + getrennte grounded/attributed-Raten + die
  Roh-Verdikte pro Fakt (für die Diagnose-Spalten: Inversions-Decoy, Decoy-
  Zustimmungsquote über Kandidaten).
  """
  @spec score([fact()], [fact()], [map()], keyword()) :: map()
  def score(positives, decoys, utterances, opts \\ [])
      when is_list(positives) and is_list(decoys) and is_list(utterances) do
    tagged =
      Enum.map(positives, &Map.put(&1, @label_key, :positive)) ++
        Enum.map(decoys, &Map.put(&1, @label_key, :decoy))

    verified = Verify.verify_facts(tagged, utterances, opts)
    {vp, vd} = Enum.split_with(verified, &(Map.get(&1, @label_key) == :positive))

    %{
      tpr: rate(vp, "verified?"),
      fpr: rate(vd, "verified?"),
      positives: side_report(vp),
      decoys: side_report(vd)
    }
  end

  defp side_report(verdicts) do
    %{
      n: length(verdicts),
      grounded_rate: rate(verdicts, "grounded?"),
      attributed_rate: rate(verdicts, "attributed?"),
      verified_rate: rate(verdicts, "verified?"),
      verdicts: Enum.map(verdicts, &strip_label/1)
    }
  end

  defp strip_label(fact), do: Map.delete(fact, @label_key)

  defp rate([], _key), do: 0.0

  defp rate(facts, key) do
    Enum.count(facts, &(Map.get(&1, key) == true)) / length(facts)
  end

  # ─── Pure Helfer (1:1 aus eval_verify.ex gehoben, vom Mix-Task geteilt) ────

  @doc """
  Jeder Decoy-Claim bekommt die `source_refs` des inhaltlich ähnlichsten echten
  Fakts (max Wort-Overlap) — der scharfe Präzisions-Test: lehnt der Judge die
  FALSCHE Version im genau dazu passenden Kontext ab? Nur für den extraktions-
  basierten Pfad (`mix lore.eval.verify`); der kuratierte Sweep bringt eigene refs.
  """
  @spec decoy_facts([String.t()], [map()]) :: [map()]
  def decoy_facts(decoys, real_facts) do
    Enum.map(decoys, fn d -> %{"claim" => d, "source_refs" => best_match_refs(d, real_facts)} end)
  end

  @spec best_match_refs(String.t(), [map()]) :: [String.t()]
  def best_match_refs(decoy, real_facts) do
    dw = word_set(decoy)

    real_facts
    |> Enum.map(fn f ->
      {overlap(dw, word_set(f["claim"] || "")), Map.get(f, "source_refs") || []}
    end)
    |> Enum.max_by(fn {ov, _refs} -> ov end, fn -> {0, []} end)
    |> elem(1)
  end

  @spec word_set(String.t()) :: MapSet.t()
  def word_set(text) do
    text |> String.downcase() |> String.split(~r/\W+/u, trim: true) |> MapSet.new()
  end

  @spec overlap(MapSet.t(), MapSet.t()) :: non_neg_integer()
  def overlap(a, b), do: MapSet.intersection(a, b) |> MapSet.size()

  @doc """
  Micro-Average über Session-Verdikt-Listen (`[{fact, grounded?::bool}]`):
  Σ geerdete / Σ gesamt. Für den extraktions-basierten `mix lore.eval.verify`-Pfad.
  """
  @spec micro([map()], atom()) :: float()
  def micro(per_session, key) do
    {num, den} =
      Enum.reduce(per_session, {0, 0}, fn s, {n, d} ->
        v = Map.fetch!(s, key)
        {n + Enum.count(v, fn {_f, g} -> g end), d + length(v)}
      end)

    if den > 0, do: num / den, else: 0.0
  end
end
