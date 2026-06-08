defmodule Worker.LLM.FaithfulnessSourceRefsTest do
  @moduledoc """
  Issue #114: score/3 bypass-Pfad — wenn source_refs nicht leer und
  mindestens eine ID im utterances-Set match, schränkt NLI-Premise auf
  diese Utterances ein. Sonst Fallback auf full set (Trigram-Pfad).

  Tests laufen ohne echten Sidecar (Settings.put url=nil → {:error,
  :sidecar_offline}), aber restrict_utterances/2 ist private — wir testen
  über das öffentliche score/3 mit gemocktem Settings-Wert.
  """

  use ExUnit.Case, async: false

  alias Worker.LLM.Faithfulness

  @utts [
    %{id: "u1", text: "Romeo trifft Julia."},
    %{id: "u2", text: "Mercutio fällt."},
    %{id: "u3", text: "Romeo wird verbannt."}
  ]

  setup do
    # Sidecar deaktivieren — wir testen den Restrict-Pfad, der vor dem
    # Sidecar-Call greift. score/3 returnt {:error, :sidecar_offline}
    # bevor wir den Restrict-Output verifizieren können, daher umkonfiguriert:
    # wir patchen den Sidecar nicht — restrict_utterances/2 ist intern.
    :ok
  end

  test "score/3 ist mit /2 backward-kompatibel (Default-Arg)" do
    # Beide Aufruf-Formen kompilieren ohne Error — Smoke-Test.
    assert {:error, :sidecar_offline} = Faithfulness.score("Eine Behauptung.", @utts)

    assert {:error, :sidecar_offline} =
             Faithfulness.score("Eine Behauptung.", @utts, ["u1"])
  end

  test "leere Claims-Liste → score 0.0 unabhängig von source_refs" do
    # Issue #290 (Bug 3): leerer LLM-Output (split_claims/1 == [] — Markdown
    # ohne Sätze ≥ 8 chars) ist im Sweep-Kontext immer ein Fehler und bekommt
    # NICHT Bestnote 1.0, sondern 0.0. (Früherer #114-Vertrag war 1.0.)
    Worker.Settings.put(:faithfulness_sidecar_url, "http://fake:9999")

    # +0.0 statt 0.0 im Pattern — OTP 27+ warnt sonst (signed-zero-Match).
    assert {:ok, %{score: +0.0, claims: []}} = Faithfulness.score("a.", @utts, ["u1"])
    assert {:ok, %{score: +0.0, claims: []}} = Faithfulness.score("a.", @utts, [])

    Worker.Settings.put(:faithfulness_sidecar_url, nil)
  end

  describe "split_claims/1 (Sanity)" do
    test "trennt Mehrsatz-Text in Claims" do
      assert ["Romeo trifft Julia.", "Mercutio fällt."] =
               Faithfulness.split_claims("Romeo trifft Julia. Mercutio fällt.")
    end
  end

  describe "best_span/2 (Trigram-Fallback bleibt funktional)" do
    test "returnt eine der Utterance-Texte als Span" do
      span = Faithfulness.best_span("Romeo wird verbannt aus Verona.", @utts)
      # Trigram-Match ist heuristisch — wir prüfen nur dass etwas non-empty
      # rauskommt aus dem Pool. Welche genau matched ist Implementierungs-
      # Detail.
      assert is_binary(span)
      assert span != ""
    end
  end

  # Issue #675: build_score_result/2 reicht die Softmax-`scores` pro Claim durch,
  # OHNE den `score`-Aggregatwert (Badge/Render-Gating) zu verändern.
  describe "build_score_result/2 (scores-Passthrough, stabiler Badge-score)" do
    test "scores werden pro Claim durchgereicht UND score-Badge bleibt entailment-Anteil" do
      results = [
        %{
          "label" => "entailment",
          "scores" => %{"entailment" => 0.8, "contradiction" => 0.1, "neutral" => 0.1}
        },
        %{
          "label" => "neutral",
          "scores" => %{"entailment" => 0.3, "contradiction" => 0.2, "neutral" => 0.5}
        }
      ]

      pairs = [{"Claim eins.", "Premise A"}, {"Claim zwei.", "Premise B"}]

      %{score: score, claims: claims} = Faithfulness.build_score_result(results, pairs)

      # Badge unverändert: 1 von 2 Claims hat Argmax "entailment" → 0.5.
      assert score == 0.5
      # scores durchgereicht (der #675-Zusatz):
      assert [%{scores: s1}, %{scores: s2}] = claims
      assert s1["entailment"] == 0.8
      assert s2["neutral"] == 0.5
      assert [%{text: "Claim eins.", label: "entailment"}, %{label: "neutral"}] = claims
    end

    test "fehlende scores im Sidecar-Result → leere Map (kein Crash, Fallback-tauglich)" do
      results = [%{"label" => "entailment"}]
      %{claims: [claim]} = Faithfulness.build_score_result(results, [{"c.", "p"}])
      assert claim.scores == %{}
    end
  end
end
