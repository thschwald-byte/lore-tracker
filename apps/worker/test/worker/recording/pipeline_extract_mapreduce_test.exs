defmodule Worker.Recording.Pipeline.ExtractMapReduceTest do
  @moduledoc """
  Issue #683: der PURE Merge-Schritt der Map-Reduce-Extraktion
  (`Stages.merge_chunk_facts/1`) — Boundary-Overlap-Dedup + globale Neu-
  Indizierung der per-Chunk-Fakt-IDs. Der LLM-Call (Map-Chunk) ist die
  I/O-Grenze und hier nicht getestet.
  """

  use ExUnit.Case, async: true

  alias Worker.Recording.Pipeline.Stages

  defp fact(id, claim, refs \\ ["u1"]) do
    %{"id" => id, "claim" => claim, "source_refs" => refs, "verified?" => false}
  end

  test "dedupt Boundary-Overlap-Duplikate (gleicher normalisierter Claim)" do
    facts = [
      fact("f1", "Der König bittet Holmes um Hilfe."),
      # zweiter Chunk hat denselben Fakt durch den Overlap (andere Groß/Klein +
      # Whitespace) → muss raus
      fact("f2", "der  könig bittet holmes um hilfe"),
      fact("f3", "Irene Adler heiratet Norton.")
    ]

    merged = Stages.merge_chunk_facts(facts)

    assert length(merged) == 2

    assert Enum.map(merged, & &1["claim"]) == [
             "Der König bittet Holmes um Hilfe.",
             "Irene Adler heiratet Norton."
           ]
  end

  test "indiziert die per-Chunk-kollidierenden IDs global neu (f1..fN)" do
    # Beide Chunks lieferten 'f1' — nach dem Merge müssen die IDs eindeutig sein.
    facts = [fact("f1", "Fakt A"), fact("f1", "Fakt B"), fact("f2", "Fakt C")]
    assert Enum.map(Stages.merge_chunk_facts(facts), & &1["id"]) == ["f1", "f2", "f3"]
  end

  test "behält die erste Variante + die Reihenfolge" do
    facts = [fact("f1", "Zuerst", ["u1"]), fact("f2", "zuerst", ["u9"]), fact("f3", "Danach")]
    merged = Stages.merge_chunk_facts(facts)
    # erste Variante (mit u1) gewinnt, Reihenfolge bleibt
    assert [%{"claim" => "Zuerst", "source_refs" => ["u1"]}, %{"claim" => "Danach"}] = merged
  end

  test "leere Claims fallen raus" do
    assert Stages.merge_chunk_facts([fact("f1", "  "), fact("f2", "Echt")]) == [
             fact("f1", "Echt") |> Map.put("id", "f1")
           ]
  end

  test "leere Liste → leer" do
    assert Stages.merge_chunk_facts([]) == []
  end

  # #763: Halbierungs-Retry für degenerierte Chunks — der Split ist PURE.
  describe "split_chunk_for_retry/1" do
    test "teilt in zwei Hälften, Reihenfolge + alle Elemente erhalten" do
      chunk = [%{id: "u1"}, %{id: "u2"}, %{id: "u3"}, %{id: "u4"}, %{id: "u5"}]
      [a, b] = Stages.split_chunk_for_retry(chunk)
      assert a ++ b == chunk
      assert length(a) == 2 and length(b) == 3
    end

    test "Zwei-Element-Chunk → zwei Ein-Element-Hälften" do
      assert Stages.split_chunk_for_retry([%{id: "u1"}, %{id: "u2"}]) == [
               [%{id: "u1"}],
               [%{id: "u2"}]
             ]
    end

    test "Ein-Element-Chunk → kein Retry (identischer Input scheitert identisch, temp 0)" do
      assert Stages.split_chunk_for_retry([%{id: "u1"}]) == []
    end

    test "leerer Chunk → kein Retry" do
      assert Stages.split_chunk_for_retry([]) == []
    end
  end
end
