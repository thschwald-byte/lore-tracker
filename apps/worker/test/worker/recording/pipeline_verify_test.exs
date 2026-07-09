defmodule Worker.Recording.Pipeline.VerifyTest do
  @moduledoc """
  Issue #651 (Wahrheitsbild, Phase B): das Verify-Gate
  (`Worker.Recording.Pipeline.Verify`). Getestet wird der pure Kern:

  - `verify_facts/3` mit injizierten `ground_fn` + `attr_fn` — die beiden
    orthogonalen Achsen (#666 Grounding + #669 Attribution), Flag statt Drop,
    Short-Circuit (Attribution nur wenn grounded).
  - `alias_groups/1` — Koreferenz-Gruppen aus den Fakten (#667/#669).
  - die deterministischen Guard-Branches von `nli_verify_one/2` +
    `attribution_verify_one/3` (kein Sidecar/LLM nötig).

  Die NLI-/LLM-Pfade selbst + der Orchestrator sind die I/O-Grenze.
  """

  use ExUnit.Case, async: true

  alias Worker.Recording.Pipeline.Verify

  defp fact(claim, opts \\ []) do
    %{
      "id" => opts[:id] || "f",
      "claim" => claim,
      "entity_id" => opts[:entity_id] || "e",
      "character_alias" => opts[:alias] || "Figur",
      "source_refs" => opts[:refs] || ["u1"],
      "verified?" => false
    }
  end

  # attr_fn, das mitloggt ob es aufgerufen wurde (Short-Circuit-Beweis).
  defp tracking_attr_fn(verdict) do
    parent = self()

    fn f, _utts, _aliases ->
      send(parent, {:attr_called, f["claim"]})
      verdict
    end
  end

  describe "verify_facts/3 — zwei Achsen, Flag statt Drop" do
    test "grounded UND attributed → verified? = true" do
      [out] =
        Verify.verify_facts([fact("ok")], [],
          ground_fn: fn _, _ -> true end,
          attr_fn: fn _, _, _ -> true end
        )

      assert out["grounded?"] == true
      assert out["attributed?"] == true
      assert out["verified?"] == true
    end

    test "grounded ABER nicht attributed → verified? = false (die #669-Fehlerklasse)" do
      # quell-geerdet, aber falsch attribuiert (König vs. Irene, gleiche Quelle)
      [out] =
        Verify.verify_facts([fact("falsch zugeordnet")], [],
          ground_fn: fn _, _ -> true end,
          attr_fn: fn _, _, _ -> false end
        )

      assert out["grounded?"] == true
      assert out["attributed?"] == false
      assert out["verified?"] == false
    end

    test "nicht grounded → verified? = false UND attr_fn wird NICHT aufgerufen (Short-Circuit)" do
      out =
        Verify.verify_facts([fact("ungeerdet")], [],
          ground_fn: fn _, _ -> false end,
          attr_fn: tracking_attr_fn(true)
        )

      assert [%{"grounded?" => false, "attributed?" => false, "verified?" => false}] = out
      # Short-Circuit: bei ungeerdetem Fakt darf der (teure) Attributions-Call nicht laufen.
      refute_received {:attr_called, _}
    end

    test "behält ALLE Fakten + setzt alle drei Flags pro Fakt (Flag statt Drop)" do
      facts = [fact("a", id: "f1"), fact("b", id: "f2"), fact("c", id: "f3")]

      out =
        Verify.verify_facts(facts, [],
          ground_fn: fn f, _ -> f["claim"] != "b" end,
          attr_fn: fn f, _, _ -> f["claim"] == "a" end
        )

      assert length(out) == 3
      assert Enum.map(out, & &1["verified?"]) == [true, false, false]
      # b: nicht grounded → attributed? false (Short-Circuit). c: grounded, aber attr false.
      assert Enum.map(out, & &1["grounded?"]) == [true, false, true]
      assert Enum.map(out, & &1["attributed?"]) == [true, false, false]
      assert Enum.at(out, 1)["claim"] == "b"
    end

    test "nicht-boolescher Rückgabewert wird strikt zu true/false normalisiert" do
      [out] =
        Verify.verify_facts([fact("a")], [],
          ground_fn: fn _, _ -> :yep end,
          attr_fn: fn _, _, _ -> :nope end
        )

      # :yep ist nicht == true → grounded? false → Short-Circuit → alles false.
      assert out["grounded?"] == false
      assert out["verified?"] == false
    end

    test "leere Fakt-Liste → leer" do
      assert Verify.verify_facts([], [], ground_fn: fn _, _ -> true end) == []
    end

    test "default-attr_fn bekommt die Koreferenz-Aliase der entity_id durchgereicht" do
      parent = self()
      # Zwei Fakten teilen entity_id "koenig" unter verschiedenen Oberflächenformen.
      facts = [
        fact("a", id: "f1", entity_id: "koenig", alias: "der König"),
        fact("b", id: "f2", entity_id: "koenig", alias: "Graf von Kramm")
      ]

      Verify.verify_facts(facts, [],
        ground_fn: fn _, _ -> true end,
        attr_fn: fn _f, _u, aliases ->
          send(parent, {:aliases, Enum.sort(aliases)})
          true
        end
      )

      # Beide Fakten sehen die volle Guise-Gruppe (Koreferenz).
      assert_received {:aliases, ["Graf von Kramm", "der König"]}
      assert_received {:aliases, ["Graf von Kramm", "der König"]}
    end
  end

  describe "alias_groups/1 — Koreferenz-Gruppen" do
    test "gruppiert Oberflächenformen pro entity_id; Koreferenz landet in einer Gruppe" do
      facts = [
        fact("a", entity_id: "koenig", alias: "der König"),
        fact("b", entity_id: "koenig", alias: "Graf von Kramm"),
        fact("c", entity_id: "irene", alias: "Irene Adler")
      ]

      groups = Verify.alias_groups(facts)

      assert Enum.sort(groups["koenig"]) == ["Graf von Kramm", "der König"]
      assert groups["irene"] == ["Irene Adler"]
    end

    test "dedupt identische Oberflächenformen + ignoriert leere entity_id/alias" do
      facts = [
        fact("a", entity_id: "koenig", alias: "der König"),
        fact("b", entity_id: "koenig", alias: "der König"),
        fact("c", entity_id: "", alias: "Niemand"),
        %{"claim" => "x", "entity_id" => "leer", "character_alias" => "  "}
      ]

      groups = Verify.alias_groups(facts)

      assert groups["koenig"] == ["der König"]
      refute Map.has_key?(groups, "")
      # entity_id "leer" existiert, aber ohne nicht-leere Oberflächenform → leere Liste.
      assert groups["leer"] == []
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

  describe "attribution_verify_one/4 — deterministische Guards" do
    test "keine Aliase → true (#762: keine Zuordnung, die falsch sein könnte — Achse n/a, Grounding gated)" do
      assert Verify.attribution_verify_one(fact("x"), [], [])
      assert Verify.attribution_verify_one(fact("x"), [], ["", "  "])
    end

    test "keine source_refs → false (ungeerdet)" do
      refute Verify.attribution_verify_one(fact("x", refs: []), [], ["König"])
    end

    test "leerer Claim → false" do
      refute Verify.attribution_verify_one(fact("   ", refs: ["u1"]), [], ["König"])
    end
  end

  # #762: Sprecher-Labels im Attributions-Prompt — ohne sie sind Sprecher-
  # Attributionen (Figur SAGT den Inhalt, steht nicht im Text) unentscheidbar.
  describe "attribution_prompt/4 — Sprecher-Labels" do
    test "labelt Quelltext-Zeilen mit aufgelöstem Sprecher-Namen" do
      utts = [
        %{id: "u1", discord_id: "111", text: "Die Drachen erwachten am Fuji."},
        %{id: "u2", discord_id: "222", text: "Würfel mal Edge."}
      ]

      prompt =
        Verify.attribution_prompt("Skrapnik erklärte die Drachen.", utts, ["Skrapnik"], %{
          "111" => "Skrapnik",
          "222" => "Kodex"
        })

      assert prompt =~ "- Skrapnik: Die Drachen erwachten am Fuji."
      assert prompt =~ "- Kodex: Würfel mal Edge."
      assert prompt =~ "SPRICHT"
    end

    test "unbekannter Sprecher → Zeile ohne Label (wie vorher)" do
      utts = [%{id: "u1", discord_id: "999", text: "Irgendwer sagt was."}]
      prompt = Verify.attribution_prompt("x", utts, ["Skrapnik"], %{"111" => "Skrapnik"})
      assert prompt =~ "- Irgendwer sagt was."
    end

    test "ohne speaker_names-Map (Default) bleiben alle Zeilen ungelabelt" do
      utts = [%{id: "u1", discord_id: "111", text: "Text ohne Label."}]
      prompt = Verify.attribution_prompt("x", utts, ["Skrapnik"])
      assert prompt =~ "- Text ohne Label."
      refute prompt =~ "Skrapnik: Text"
    end
  end

  # Issue #675: die tunbare Grounding-Schwelle. PURE, kein Sidecar nötig.
  describe "grounded_by_scores?/3 — Schwellen-Entscheidung" do
    test "entailment hoch + contradiction niedrig → geerdet" do
      scores = %{"entailment" => 0.8, "neutral" => 0.15, "contradiction" => 0.05}
      assert Verify.grounded_by_scores?(scores, 0.5, 0.5)
    end

    test "deutsches Paar mit moderater entailment-Prob → geerdet bei weicher Schwelle (Kern-Fix)" do
      # Genau die Klasse, die der frühere strikte Argmax-Gate (s >= 1.0) ablehnte:
      # entailment ist nicht Argmax (neutral führt), aber klar belegt.
      scores = %{"entailment" => 0.42, "neutral" => 0.5, "contradiction" => 0.08}
      assert Verify.grounded_by_scores?(scores, 0.4, 0.5)
      refute Verify.grounded_by_scores?(scores, 0.5, 0.5)
    end

    test "hohe contradiction → NICHT geerdet, egal wie hoch entailment (Decoy-Schutz)" do
      scores = %{"entailment" => 0.6, "neutral" => 0.1, "contradiction" => 0.7}
      refute Verify.grounded_by_scores?(scores, 0.5, 0.5)
    end

    test "fehlende Keys → 0.0 → nicht geerdet" do
      refute Verify.grounded_by_scores?(%{}, 0.5, 0.5)
      refute Verify.grounded_by_scores?(%{"neutral" => 1.0}, 0.5, 0.5)
    end

    test "Atom-Keys werden auch akzeptiert" do
      assert Verify.grounded_by_scores?(%{entailment: 0.9, contradiction: 0.0}, 0.5, 0.5)
    end

    test "nicht-Map → false (defensiv)" do
      refute Verify.grounded_by_scores?(nil, 0.5, 0.5)
    end
  end

  # Issue #677: LLM-as-Judge-Grounding. Die deterministischen Guards (kein LLM nötig).
  describe "llm_grounding_one/2 — deterministische Guards" do
    test "Fakt ohne source_refs → false (ungeerdet)" do
      refute Verify.llm_grounding_one(fact("belegt?", refs: []), [])
    end

    test "leerer Claim → false" do
      refute Verify.llm_grounding_one(fact("   ", refs: ["u1"]), [])
    end
  end

  describe "grounding_prompt/2" do
    test "enthält Claim + Quelltext, fragt nach inhaltlicher Stützung" do
      utts = [%{"id" => "u1", "text" => "Der König bittet Holmes um Hilfe."}]
      p = Verify.grounding_prompt("Der König beauftragt Holmes.", utts)

      assert p =~ "Der König beauftragt Holmes."
      assert p =~ "Der König bittet Holmes um Hilfe."
      assert p =~ "grounded"
      # verdichten/paraphrasieren explizit erlaubt (der NLI-Schwachpunkt, #675)
      assert p =~ "verdicht" or p =~ "paraphrasier"
    end
  end
end
