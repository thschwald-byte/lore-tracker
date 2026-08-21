defmodule Worker.Recording.Pipeline.VerifyTest do
  @moduledoc """
  Issue #651 (Wahrheitsbild, Phase B): das Verify-Gate
  (`Worker.Recording.Pipeline.Verify`). Getestet wird der pure Kern:

  - `verify_facts/3` mit injizierten `ground_fn` + `attr_fn` — die beiden
    orthogonalen Achsen (#666 Grounding + #669 Attribution), Flag statt Drop,
    Short-Circuit (Attribution nur wenn grounded).
  - `alias_groups/1` — Koreferenz-Gruppen aus den Fakten (#667/#669).
    `attribution_verify_one/3` (kein Sidecar/LLM nötig).

  Die NLI-/LLM-Pfade selbst + der Orchestrator sind die I/O-Grenze.
  """

  # Issue #962: async: false — diese Suite schreibt den globalen Worker.Settings-
  # Singleton (z.B. :ctx_stage4); async ließe konkurrierende Reader anderer
  # Suiten flaky werden (CI-Race auf master-Pipeline 721).
  use ExUnit.Case, async: false

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
  describe "llm_grounding_one/2 — deterministische Guards" do
    test "Fakt ohne source_refs → false (ungeerdet)" do
      refute Verify.llm_grounding_one(fact("belegt?", refs: []), [])
    end

    test "leerer Claim → false" do
      refute Verify.llm_grounding_one(fact("   ", refs: ["u1"]), [])
    end
  end

  describe "restrict_to_refs/2 — Nachbar-Kontextfenster (#815)" do
    defp utt(id), do: %{"id" => id, "text" => "Text #{id}"}
    defp ids(utts), do: Enum.map(utts, & &1["id"])

    setup do
      on_exit(fn -> Worker.Settings.put(:grounding_context_window, 1) end)
      :ok
    end

    test "Default-Fenster (1): nimmt ±1 Nachbar-Utterance um den Treffer mit" do
      utts = Enum.map(1..5, &utt("u#{&1}"))

      result = Verify.restrict_to_refs(utts, ["u3"])

      assert ids(result) == ["u2", "u3", "u4"]
    end

    test "Treffer am Rand: keine out-of-range-Nachbarn, kein Crash" do
      utts = Enum.map(1..5, &utt("u#{&1}"))

      assert ids(Verify.restrict_to_refs(utts, ["u1"])) == ["u1", "u2"]
      assert ids(Verify.restrict_to_refs(utts, ["u5"])) == ["u4", "u5"]
    end

    test "mehrere Refs: Vereinigung der Fenster, dedupliziert, Original-Reihenfolge" do
      utts = Enum.map(1..8, &utt("u#{&1}"))

      # Fenster um u2 (u1-u3) und u6 (u5-u7) überschneiden sich nicht -> Lücke bei u4.
      result = Verify.restrict_to_refs(utts, ["u2", "u6"])
      assert ids(result) == ["u1", "u2", "u3", "u5", "u6", "u7"]

      # Überlappende Fenster (u3, u4 -> beide ±1) verschmelzen ohne Duplikate.
      overlapping = Verify.restrict_to_refs(utts, ["u3", "u4"])
      assert ids(overlapping) == ["u2", "u3", "u4", "u5"]
    end

    test "window=0 (explizit): exakt altes Verhalten, keine Nachbarn" do
      Worker.Settings.put(:grounding_context_window, 0)
      utts = Enum.map(1..5, &utt("u#{&1}"))

      assert ids(Verify.restrict_to_refs(utts, ["u3"])) == ["u3"]
    end

    test "dangling ref (z.B. gelöschte Utterance) -> Fallback auf volle Liste" do
      utts = Enum.map(1..3, &utt("u#{&1}"))

      assert Verify.restrict_to_refs(utts, ["u-deleted"]) == utts
    end

    test "leere Refs -> Fallback auf volle Liste (Guards davor greifen in der Praxis früher)" do
      utts = Enum.map(1..3, &utt("u#{&1}"))

      assert Verify.restrict_to_refs(utts, []) == utts
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

  # Issue #996: der Dirty-:reextract-Pfad (#866) verifiziert NUR die neu
  # adoptierten Fakten (die carried behalten ihre Verdikte) — die Koreferenz-
  # Gruppen kamen dadurch bislang aus dieser Teilmenge allein. Oberflächenformen,
  # die nur in den carried-Fakten vorkommen, waren für die Attributions-Prüfung
  # der adoptierten Fakten unsichtbar → Guise-Fälle kippen in falsche Negative.
  # `:coref_facts` entkoppelt „welche Fakten werden verifiziert" von „welcher
  # Korpus bildet die Koreferenz-Gruppen".
  describe "verify_facts/3 — :coref_facts (Issue #996)" do
    defp capturing_attr_fn do
      parent = self()

      fn f, _utts, aliases ->
        send(parent, {:aliases_for, f["id"], Enum.sort(aliases)})
        true
      end
    end

    test "Default (ohne :coref_facts): Gruppen kommen aus den verifizierten Fakten selbst" do
      adopted = [fact("neu", id: "f-neu", entity_id: "koenig", alias: "Graf von Kramm")]

      Verify.verify_facts(adopted, [],
        ground_fn: fn _, _ -> true end,
        attr_fn: capturing_attr_fn()
      )

      # Nur die eigene Oberflächenform — unverändertes Verhalten für alle
      # bestehenden Aufrufer.
      assert_received {:aliases_for, "f-neu", ["Graf von Kramm"]}
    end

    test "mit :coref_facts: Oberflächenform aus einem NICHT verifizierten Fakt reist mit" do
      carried = [fact("alt", id: "f-alt", entity_id: "koenig", alias: "der König")]
      adopted = [fact("neu", id: "f-neu", entity_id: "koenig", alias: "Graf von Kramm")]

      out =
        Verify.verify_facts(adopted, [],
          ground_fn: fn _, _ -> true end,
          attr_fn: capturing_attr_fn(),
          coref_facts: carried ++ adopted
        )

      # Die Guise-Gruppe ist vollständig, obwohl "der König" nur im carried-Fakt steht.
      assert_received {:aliases_for, "f-neu", ["Graf von Kramm", "der König"]}

      # Und NUR die adoptierten Fakten kommen zurück (carried werden nicht mit-verifiziert).
      assert Enum.map(out, & &1["id"]) == ["f-neu"]
      refute_received {:aliases_for, "f-alt", _}
    end
  end
end
