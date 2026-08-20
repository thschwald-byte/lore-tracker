defmodule Worker.Recording.PipelineTruncationSalvageTest do
  @moduledoc """
  Issue #1115: Rettung einer am Kontextfenster abgeschnittenen Extraktion.

  Der Anlass ist ein echter Produktionsabriss (Free Seattle S1, 2026-08-20,
  qwen3.8:27b): der Lauf schrieb 38 vollständige Fakten, geriet dann in eine
  Wiederholungsschleife, füllte `ctx_stage2` und wurde mitten in `"source_refs`
  gekappt (`done_reason: "length"`). `Jason.decode` scheiterte — und mit ihm
  fielen bis #1115 auch die 38 fertigen Fakten weg.

  Das Fixture unten ist **wörtlich aus diesem Lauf** (auf zwei Objekte gekürzt,
  Abriss im Original-Wortlaut). Ein echter Abriss ist als Testgrundlage mehr
  wert als ein nachgebauter: er trägt die Feldreihenfolge, die Umlaute und die
  Abbruchstelle, die das Modell tatsächlich produziert hat.
  """
  use ExUnit.Case, async: true

  alias Worker.Recording.Pipeline.Parsing

  # Zwei vollständige Objekte, dann der Abriss — wörtlich aus dem Realfall.
  @abriss ~s({"facts":[) <>
            ~s({"cast_match":"Kodex","character":"Kodex","claim":"Kodex kann keine Fahrzeuge fahren und fühlt sich in Autos unwohl","fact_type":"zustand","in_game_date":"","narration_time":"present","source_refs":["u1"],"threads":["Kodex als Buchhalter"],"time_anchor":"session"},) <>
            ~s({"cast_match":"Kodex","character":"Kodex","claim":"Kodex ist ein begeisterter Karaoke-Sänger, wenn er genug getrunken hat","fact_type":"zustand","in_game_date":"","narration_time":"present","source_refs":["u2"],"threads":["Kodex als Buchhalter"],"time_anchor":"session"},) <>
            ~s({"cast_match":"Kodex","character":"Kodex","claim":"Kodex hat Formulare am Mann, die man vielleicht mal braucht","fact_type":"zustand","in_game_date":"","narration_time":"present","source_refs)

  defp block(id, text), do: %{id: id, text: text, discord_id: "d", quell_utterance_ids: [id]}

  defp bloecke, do: [block("u1", "Ich fahr nicht Auto."), block("u2", "Karaoke geht immer.")]

  defp fakt(claim, refs) do
    ~s({"claim":"#{claim}","character":"X","fact_type":"ereignis","narration_time":"present",) <>
      ~s("time_anchor":"session","in_game_date":"","threads":[],"source_refs":#{Jason.encode!(refs)}})
  end

  describe "salvage_truncated_facts/1 — die pure Rettung" do
    test "holt die vollständigen Objekte aus dem echten Produktionsabriss" do
      assert {:ok, [a, b]} = Parsing.salvage_truncated_facts(@abriss)
      assert a["claim"] =~ "keine Fahrzeuge fahren"
      assert b["claim"] =~ "Karaoke-Sänger"
    end

    test "das angebrochene letzte Objekt wird verworfen, nicht repariert" do
      {:ok, list} = Parsing.salvage_truncated_facts(@abriss)
      # Drei Objekte standen im Text, das dritte war unvollständig.
      assert length(list) == 2
      refute Enum.any?(list, &(&1["claim"] =~ "Formulare"))
    end

    test "Abriss IM ERSTEN Objekt rettet nichts" do
      raw = ~s({"facts":[{"claim":"halb geschrieben","fact_)
      assert :error = Parsing.salvage_truncated_facts(raw)
    end

    test "leeres Array rettet nichts" do
      assert :error = Parsing.salvage_truncated_facts(~s({"facts":[))
    end

    test "Text ohne facts-Key rettet nichts" do
      assert :error = Parsing.salvage_truncated_facts(~s({"other":[{"a":1}]}))
      assert :error = Parsing.salvage_truncated_facts("Entschuldigung, ich kann das nicht.")
      assert :error = Parsing.salvage_truncated_facts("")
      assert :error = Parsing.salvage_truncated_facts(nil)
    end

    test "geschweifte Klammern IM Claim verschieben die Objektgrenze nicht" do
      raw =
        ~s({"facts":[{"claim":"Er sagt: {kein Objekt} und } auch nicht","x":1},) <>
          ~s({"claim":"zweiter","y":2},{"claim":"abgeschn)

      assert {:ok, [a, b]} = Parsing.salvage_truncated_facts(raw)
      assert a["claim"] =~ "kein Objekt"
      assert b["claim"] == "zweiter"
    end

    test "maskierte Anführungszeichen beenden den String nicht" do
      raw = ~s({"facts":[{"claim":"Er sagte \\"nein\\" und ging","x":1},{"claim":"abgeschn)
      assert {:ok, [a]} = Parsing.salvage_truncated_facts(raw)
      assert a["claim"] == ~s(Er sagte "nein" und ging)
    end

    test "verschachtelte Objekte zählen als EIN Element" do
      raw = ~s({"facts":[{"claim":"a","time_offset":{"value":3,"unit":"Tage"}},{"claim":"abge)
      assert {:ok, [a]} = Parsing.salvage_truncated_facts(raw)
      assert a["time_offset"]["unit"] == "Tage"
    end
  end

  describe "parse_facts_json/2 — der Einhängepunkt" do
    test "vollständiges JSON läuft unverändert über den regulären Weg" do
      raw = ~s({"facts":[#{fakt("etwas geschah", ["u1"])}]})
      assert {:ok, [f]} = Parsing.parse_facts_json(raw, bloecke())
      assert f["claim"] == "etwas geschah"
    end

    test "abgeschnittenes JSON liefert :salvaged statt :parse_failed" do
      raw =
        ~s({"facts":[#{fakt("erster Fakt", ["u1"])},#{fakt("zweiter Fakt", ["u2"])},{"claim":"abge)

      assert {:salvaged, facts} = Parsing.parse_facts_json(raw, bloecke())
      assert length(facts) == 2
      assert Enum.map(facts, & &1["claim"]) == ["erster Fakt", "zweiter Fakt"]
    end

    test "gerettete Fakten sind vollwertig normalisiert" do
      # Der Punkt: dem geretteten Fakt sieht niemand die Rettung an. Der
      # Unterschied gehört in die Fehlerklasse, nicht in die Daten.
      raw = ~s({"facts":[#{fakt("belegt", ["u1"])},{"claim":"abge)

      assert {:salvaged, [f]} = Parsing.parse_facts_json(raw, bloecke())
      assert f["id"]
      assert f["source_refs"] == ["u1"]
      assert f["verified?"] == false
    end

    test "unrettbarer Müll bleibt beim alten :parse_failed" do
      assert {:error, :parse_failed} =
               Parsing.parse_facts_json("kein JSON weit und breit", bloecke())

      assert {:error, :parse_failed} = Parsing.parse_facts_json(~s({"facts":[{"cl), bloecke())
      assert {:error, :parse_failed} = Parsing.parse_facts_json(nil, bloecke())
    end

    test "JSON ohne facts-Key bleibt :no_facts_key (kein Rettungs-Versuch)" do
      assert {:error, :no_facts_key} = Parsing.parse_facts_json(~s({"items":[]}), bloecke())
    end

    test "die Rettung greift auch hinter einem <think>-Block" do
      # strip_and_note/1 läuft VOR der Rettung — sie sieht denselben
      # gesäuberten Text wie der gescheiterte Parse.
      raw =
        "<think>lang und breit</think>" <>
          ~s({"facts":[#{fakt("nach dem Denken", ["u1"])},{"claim":"abge)

      assert {:salvaged, [f]} = Parsing.parse_facts_json(raw, bloecke())
      assert f["claim"] == "nach dem Denken"
    end
  end
end
