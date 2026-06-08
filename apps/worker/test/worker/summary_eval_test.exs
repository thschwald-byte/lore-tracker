defmodule Worker.SummaryEvalTest do
  use ExUnit.Case, async: true

  alias Worker.SummaryEval

  @entities [
    %{"canonical" => "Sherlock Holmes", "variants" => ["Holmes"]},
    %{"canonical" => "König von Böhmen", "variants" => ["Wilhelm von Ormstein", "der König"]},
    %{"canonical" => "Briony Lodge", "variants" => ["Serpentine Avenue", "St. John's Wood"]},
    %{"canonical" => "die Fotografie", "variants" => ["das Foto", "das Bild"]}
  ]

  @noise_markers ["Spot Hidden", "ich würfle", "macht mir bitte eine Probe", "W100", "Glück"]

  describe "entity_recall/2" do
    test "kanonische Form matcht (normalisiert, case-insensitiv)" do
      summary = "Sherlock HOLMES untersucht den Fall in der Briony Lodge."
      r = SummaryEval.entity_recall(summary, @entities)

      # Holmes + Briony Lodge getroffen, König + Fotografie fehlen.
      assert r.recalled == 2
      assert r.total == 4
      assert r.rate == 0.5
      assert "König von Böhmen" in r.missing
      assert "die Fotografie" in r.missing
    end

    test "Variante matcht, wenn die kanonische Form fehlt" do
      summary = "Der König beauftragt den Detektiv, das Foto aus St. John's Wood zu holen."
      r = SummaryEval.entity_recall(summary, @entities)

      # "der König" (Variante), "St. John's Wood" (Variante), "das Foto" (Variante).
      assert "König von Böhmen" not in r.missing
      assert "Briony Lodge" not in r.missing
      assert "die Fotografie" not in r.missing
      assert r.recalled == 3
    end

    test "Interpunktion + Apostroph stören das Matching nicht" do
      r = SummaryEval.entity_recall("Sie wohnt in St. John's Wood.", @entities)
      assert "Briony Lodge" not in r.missing
    end

    test "gesprochene Form mit Bindestrich matcht die Variante (#661)" do
      # Resümee sagt 'Sankt-Monika-Kirche', Fact-Key-Variante ist 'Sankt Monika' —
      # normalisiert beides 'sankt monika …', Substring trifft.
      entities = [%{"canonical" => "Kirche St. Monika", "variants" => ["Sankt Monika"]}]
      r = SummaryEval.entity_recall("Die Trauung war in der Sankt-Monika-Kirche.", entities)
      assert r.recalled == 1
      assert r.missing == []
    end

    test "leere Zusammenfassung → recall 0" do
      r = SummaryEval.entity_recall("", @entities)
      assert r.recalled == 0
      assert r.rate == 0.0
    end
  end

  describe "noise_leak/2" do
    test "erkennt durchgesickerte Regel-/Würfel-Strings" do
      summary = "Holmes macht eine Probe auf Spot Hidden und ich würfle eine 80."
      n = SummaryEval.noise_leak(summary, @noise_markers)

      # "Spot Hidden" + "ich würfle" — der Volltext-Marker "macht mir bitte eine
      # Probe" matcht NICHT (die Summary sagt nur "macht eine Probe").
      assert n.hits == 2
      assert "Spot Hidden" in n.markers
      assert "ich würfle" in n.markers
      assert "macht mir bitte eine Probe" not in n.markers
    end

    test "sauberes Resümee leakt nichts" do
      summary = "Holmes deduziert aus Beobachtung Watsons Alltag und nimmt den Fall an."
      n = SummaryEval.noise_leak(summary, @noise_markers)
      assert n.hits == 0
    end

    test "case-insensitiv" do
      n = SummaryEval.noise_leak("Wir machen einen SPOT HIDDEN check", @noise_markers)
      assert n.hits == 1
    end
  end

  describe "score_judge/4 (Aggregation der Judge-Index-Listen, ohne LLM)" do
    @facts ["Holmes nimmt den Fall an.", "Irene heiratet Norton.", "Irene flieht ins Ausland."]
    @decoys ["Holmes erschießt jemanden.", "Die Fotografie wird verbrannt."]
    @attributions [
      %{"character" => "König", "claim" => "beauftragt Holmes"},
      %{"character" => "Irene", "claim" => "flieht ins Ausland"}
    ]

    test "zählt belegte Fakten / Decoys / Attributionen korrekt" do
      decoded = %{
        "covered_fact_indices" => [0, 2],
        "asserted_decoy_indices" => [],
        "correct_attribution_indices" => [1]
      }

      r = SummaryEval.score_judge(decoded, @facts, @decoys, @attributions)

      assert r.fact_recall.covered == 2
      assert r.fact_recall.total == 3
      assert_in_delta r.fact_recall.rate, 2 / 3, 0.001
      assert r.fact_recall.missing == ["Irene heiratet Norton."]

      assert r.fabrication.asserted == 0
      assert r.fabrication.total == 2
      assert r.fabrication.asserted_decoys == []

      assert r.attribution_accuracy.correct == 1
      assert r.attribution_accuracy.rate == 0.5
    end

    test "behauptete Decoys werden als Halluzination gelistet" do
      decoded = %{
        "covered_fact_indices" => [],
        "asserted_decoy_indices" => [0],
        "correct_attribution_indices" => []
      }

      r = SummaryEval.score_judge(decoded, @facts, @decoys, @attributions)
      assert r.fabrication.asserted == 1
      assert r.fabrication.asserted_decoys == ["Holmes erschießt jemanden."]
    end

    test "Out-of-Range- + Duplikat-Indizes werden verworfen" do
      decoded = %{
        # 3 Fakten → gültig nur 0..2; 5/-1 raus, 0 dedupliziert
        "covered_fact_indices" => [0, 0, 5, -1, 2],
        "asserted_decoy_indices" => [99],
        "correct_attribution_indices" => []
      }

      r = SummaryEval.score_judge(decoded, @facts, @decoys, @attributions)
      assert r.fact_recall.covered == 2
      assert r.fabrication.asserted == 0
    end

    test "fehlende/nicht-Listen-Felder → 0 (kein Crash)" do
      r = SummaryEval.score_judge(%{}, @facts, @decoys, @attributions)
      assert r.fact_recall.covered == 0
      assert r.fact_recall.rate == 0.0
      assert r.fabrication.asserted == 0
      assert r.attribution_accuracy.correct == 0
    end
  end

  describe "median/1 (Multi-Sample-Aggregation #656)" do
    test "ungerade Anzahl → mittlerer Wert" do
      assert SummaryEval.median([0.5, 0.9, 0.7]) == 0.7
      assert SummaryEval.median([3, 1, 2]) == 2.0
    end

    test "gerade Anzahl → Mittel der beiden mittleren" do
      assert SummaryEval.median([0.6, 0.8]) == 0.7
      assert SummaryEval.median([1, 2, 3, 4]) == 2.5
    end

    test "robust gegen einen Ausreißer (das Motiv von #656)" do
      assert SummaryEval.median([0.7, 0.7, 0.7, 0.1]) == 0.7
    end

    test "Einzelwert + leere Liste" do
      assert SummaryEval.median([0.42]) == 0.42
      assert SummaryEval.median([]) == 0.0
    end
  end
end
