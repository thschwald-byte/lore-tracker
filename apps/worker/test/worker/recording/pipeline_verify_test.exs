defmodule Worker.Recording.Pipeline.VerifyTest do
  @moduledoc """
  Issue #651 (Wahrheitsbild, Phase B): das Verify-Gate
  (`Worker.Recording.Pipeline.Verify`). Getestet wird der pure Kern
  (`verify_facts/3` mit injiziertem verify_fn — Flag statt Drop) + die
  deterministischen Guard-Branches von `nli_verify_one/2` (kein Sidecar nötig).
  Der NLI-Pfad selbst + der Orchestrator sind die I/O-Grenze.
  """

  use ExUnit.Case, async: true

  alias Worker.Recording.Pipeline.Verify

  defp fact(claim, opts \\ []) do
    %{
      "id" => opts[:id] || "f",
      "claim" => claim,
      "source_refs" => opts[:refs] || ["u1"],
      "verified?" => false
    }
  end

  describe "verify_facts/3 — Flag statt Drop" do
    test "behält ALLE Fakten, setzt verified? pro Verdikt" do
      facts = [fact("ja-1"), fact("nein"), fact("ja-2")]
      verify_fn = fn f, _utts -> String.starts_with?(f["claim"], "ja") end

      out = Verify.verify_facts(facts, [], verify_fn)

      # Kein Fakt verschwindet (Flag statt Drop).
      assert length(out) == 3
      assert Enum.map(out, & &1["verified?"]) == [true, false, true]
      # auch der unverifizierte bleibt vollständig erhalten
      assert Enum.at(out, 1)["claim"] == "nein"
    end

    test "nicht-boolescher Rückgabewert wird zu strikt true/false normalisiert" do
      facts = [fact("a"), fact("b")]
      # verify_fn liefert truthy/nil statt echtem bool
      verify_fn = fn f, _ -> if f["claim"] == "a", do: :yep, else: nil end

      out = Verify.verify_facts(facts, [], verify_fn)
      # :yep ist nicht == true → false; nil → false. Strikte Bool-Semantik.
      assert Enum.map(out, & &1["verified?"]) == [false, false]
    end

    test "leere Fakt-Liste → leer" do
      assert Verify.verify_facts([], [], fn _, _ -> true end) == []
    end
  end

  describe "nli_verify_one/2 — deterministische Guards" do
    test "Fakt ohne source_refs → false (ungeerdet, kein Raten)" do
      refute Verify.nli_verify_one(fact("belegt?", refs: []), [])
    end

    test "leerer Claim → false" do
      refute Verify.nli_verify_one(fact("   ", refs: ["u1"]), [])
    end
  end
end
