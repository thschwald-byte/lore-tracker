defmodule Mix.Tasks.Lore.Seed.SourceRefsTest do
  @moduledoc """
  Issue #350: deterministischer lexical-overlap Ref-Selektor für die Demo-Seeds.
  """

  use ExUnit.Case, async: true

  alias Mix.Tasks.Lore.Seed.SourceRefs

  defp utts do
    [
      %{"id" => "u1", "text" => "Verona im Morgengrauen, die Wachen ziehen auf."},
      %{"id" => "u2", "text" => "Tybalt zieht den Degen und fordert Mercutio zum Duell."},
      %{"id" => "u3", "text" => "Ein Krämer verkauft Feigen am Marktstand."},
      %{"id" => "u4", "text" => "Mercutio fällt im Duell, Tybalt flieht über die Piazza."},
      %{"id" => "u5", "text" => "Die Sonne brennt heiß über den Dächern."}
    ]
  end

  describe "compute_refs/3 — Selektivität (Kern-Akzeptanz)" do
    test "liefert eine echte nicht-leere Teilmenge — NICHT alle Utterances" do
      entry = "Tybalt fordert Mercutio zum Duell und ersticht ihn auf der Piazza."
      refs = SourceRefs.compute_refs(entry, utts())

      assert refs != [], "erwartet matchende Refs, kein All-Utts-Fallback"
      assert length(refs) < length(utts()), "darf nicht alle Utterances zurückgeben"
      # Die Duell-Utterances matchen (Tybalt/Mercutio/Duell/Piazza), nicht die Feigen/Sonne.
      assert "u2" in refs
      assert "u4" in refs
      refute "u3" in refs
      refute "u5" in refs
    end
  end

  describe "compute_refs/3 — Determinismus + Reihenfolge" do
    test "gleiche Eingabe → gleiche Ausgabe" do
      entry = "Tybalt und Mercutio im Duell auf der Piazza."
      assert SourceRefs.compute_refs(entry, utts()) == SourceRefs.compute_refs(entry, utts())
    end

    test "Ergebnis in Utterance-Reihenfolge, nicht Score-Reihenfolge" do
      # u4 teilt mehr Tokens (Duell, Tybalt, Piazza) als u2, käme bei Score-Sort zuerst.
      # Erwartet trotzdem u2 vor u4 (Original-Reihenfolge).
      entry = "Tybalt flieht über die Piazza nach dem Duell, Mercutio fällt."
      refs = SourceRefs.compute_refs(entry, utts())
      assert refs == Enum.filter(["u1", "u2", "u3", "u4", "u5"], &(&1 in refs))
    end
  end

  describe "compute_refs/3 — Schwelle + Edge-Cases" do
    test "kein/zu geringer Overlap → []" do
      entry = "Völlig unabhängiger Text über Quantenphysik und Halbleiter."
      assert SourceRefs.compute_refs(entry, utts()) == []
    end

    test "ein einzelnes geteiltes Token reicht nicht (min_overlap 2)" do
      # Nur 'verona' geteilt mit u1 → unter Schwelle.
      assert SourceRefs.compute_refs("Verona Quantenphysik Halbleiter Mikrochip", utts()) == []
    end

    test "leerer/nil entry_text → []" do
      assert SourceRefs.compute_refs("", utts()) == []
      assert SourceRefs.compute_refs(nil, utts()) == []
    end

    test "k begrenzt die Anzahl" do
      # Alle 5 Utts teilen genug Tokens, aber k=2 cappt.
      entry =
        "Verona Morgengrauen Wachen Tybalt Degen Mercutio Duell Krämer Feigen Marktstand fällt flieht Piazza Sonne brennt Dächern"

      refs = SourceRefs.compute_refs(entry, utts(), k: 2, min_overlap: 1)
      assert length(refs) == 2
    end

    test "atom-keyed candidate_utts werden ebenso akzeptiert" do
      atom_utts = [
        %{id: "a1", text: "Tybalt zieht den Degen."},
        %{id: "a2", text: "Feigen am Markt."}
      ]

      refs = SourceRefs.compute_refs("Tybalt zieht den Degen im Duell.", atom_utts)
      assert "a1" in refs
      refute "a2" in refs
    end
  end

  describe "union_refs/1" do
    test "dedupliziert, behält Reihenfolge des ersten Vorkommens" do
      assert SourceRefs.union_refs([["u1", "u2"], ["u2", "u3"], ["u1"]]) == ["u1", "u2", "u3"]
    end

    test "leere Listen → []" do
      assert SourceRefs.union_refs([[], []]) == []
    end
  end
end
