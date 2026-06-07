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
end
