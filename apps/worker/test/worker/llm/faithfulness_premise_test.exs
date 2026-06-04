defmodule Worker.LLM.FaithfulnessPremiseTest do
  @moduledoc """
  Issue #508: best_premise/2 baut die NLI-Premise aus den Top-K (Trigram-Overlap)
  Utterances statt nur der einzelnen besten — ein aggregierender Resümee-Claim
  bekommt so genug Kontext, um entailt zu werden (statt fälschlich `neutral`).
  """
  use ExUnit.Case, async: true

  alias Worker.LLM.Faithfulness

  test "aggregiert mehrere überlappende Utterances (nicht nur die beste)" do
    utts = [
      %{text: "a b c d e"},
      %{text: "x y z nichts gemeinsam"},
      %{text: "e f g h"}
    ]

    claim = "a b c d e f g h"

    premise = Faithfulness.best_premise(claim, utts)

    # Beide überlappenden Utterances (idx 0 + 2) sind drin …
    assert premise =~ "a b c d e"
    assert premise =~ "e f g h"
    # … die nicht-überlappende (idx 1) NICHT.
    refute premise =~ "x y z"

    # best_span/2 (Top-1) liefert dagegen nur die eine beste.
    assert Faithfulness.best_span(claim, utts) == "a b c d e"
  end

  test "ordnet relevanteste Utterance (höchster Overlap) zuerst" do
    utts = [%{text: "e f g h"}, %{text: "a b c d e"}]
    claim = "a b c d e f g h"
    # idx1 ("a b c d e", Overlap 5) VOR idx0 ("e f g h", Overlap 4) — desc, stärkste
    # Evidenz vorne (NLI gewichtet den Anfang).
    assert Faithfulness.best_premise(claim, utts) == "a b c d e e f g h"
  end

  test "Fallback auf einzelne beste Utterance, wenn gar kein Overlap" do
    utts = [%{text: "völlig anderer text eins"}, %{text: "noch was anderes zwei"}]
    premise = Faithfulness.best_premise("p q r s", utts)
    # genau eine der Utterances (best_span-Fallback), nicht beide zusammengefügt
    assert premise in [List.first(utts).text, List.last(utts).text]
  end

  test "leere Utterance-Liste crasht nicht" do
    assert Faithfulness.best_premise("irgendein claim", []) == ""
  end
end
