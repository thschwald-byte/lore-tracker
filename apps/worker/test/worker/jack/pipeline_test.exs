defmodule Worker.Jack.PipelineTest do
  # J4 (#1207): Jacks Eingabe aus der Kontextliste der Pipeline und die
  # Übersetzung seines Bestands in Fakten, wie die Extraktion sie liefert.
  use ExUnit.Case, async: true

  alias Worker.Jack.Pipeline
  alias Worker.Recording.Pipeline.{Parsing, Smoothing}

  # Kontextliste wie `Smoothing.to_context/3`: atom-Schlüssel, wirksamer Text.
  @kontext [
    %{
      id: "b_a",
      discord_id: "111",
      text: "Ich klopfe an die Tür.",
      quell_utterance_ids: ["u1", "u2"]
    },
    %{id: "b_b", discord_id: "999", text: "Die Tür öffnet sich.", quell_utterance_ids: ["u3"]},
    %{id: "b_c", discord_id: "111", text: "Ich trete ein.", quell_utterance_ids: ["u4"]}
  ]

  @sprecher %{"111" => "Mira", "999" => "Spielleiter"}

  test "eingabe: Blöcke in derselben Reihenfolge, mit Namen und Block-ID" do
    assert {:ok, e} = Pipeline.eingabe(@kontext, @sprecher, ["Mira", "", "Mira"], ["Die Tür"])

    assert e.bloecke == [
             %{text: "Ich klopfe an die Tür.", sprecher: "Mira", block_id: "b_a"},
             %{text: "Die Tür öffnet sich.", sprecher: "Spielleiter", block_id: "b_b"},
             %{text: "Ich trete ein.", sprecher: "Mira", block_id: "b_c"}
           ]

    assert {e.cast, e.straenge} == {["Mira"], ["Die Tür"]}
  end

  test "eingabe: ein Sprecher ohne Namen ist ein Fehler, keine Discord-ID bei Jack" do
    assert {:error, {:sprecher_ohne_namen, ["999"]}} =
             Pipeline.eingabe(@kontext, Map.delete(@sprecher, "999"), [], [])
  end

  test "fakten: Blocknummern werden Block-IDs, verworfene Aussagen fallen weg" do
    aussagen = [
      %{
        "nummer" => 1,
        "claim" => "Mira öffnet die Tür.",
        "character" => "Mira",
        "cast_match" => "Mira",
        "narration_time" => "present",
        "time_anchor" => "session",
        "in_game_date" => "",
        "fact_type" => "ereignis",
        "threads" => ["Die Tür"],
        "source_refs" => [0, 1],
        "beleg" => "Ich klopfe an die Tür.",
        "_iter" => 1
      },
      %{"nummer" => 2, "claim" => "Verworfen.", "source_refs" => [2], "_verworfen" => true},
      # Eine Nummer außerhalb der Liste fällt weg, die gültige bleibt.
      %{
        "nummer" => 3,
        "claim" => "Mira tritt ein.",
        "character" => "Mira",
        "source_refs" => [2, 7]
      },
      # Ohne Nummer ist es keine eingetragene Aussage.
      %{"claim" => "Kein Bestand."}
    ]

    assert {:ok, [f1, f3], saw} = Pipeline.fakten(aussagen, @kontext)

    assert f1["source_refs"] == ["b_a", "b_b"]
    assert f1["id"] == Parsing.fact_content_id(["u1", "u2", "u3"], "Mira öffnet die Tür.")
    assert f1["character_alias"] == "Mira"
    assert f1["threads"] == ["Die Tür"]
    refute Map.has_key?(f1, "beleg")

    assert f3["source_refs"] == ["b_c"]
    assert f3["id"] == Parsing.fact_content_id(["u4"], "Mira tritt ein.")

    assert saw == %{
             "b_a" => Smoothing.text_hash("Ich klopfe an die Tür."),
             "b_b" => Smoothing.text_hash("Die Tür öffnet sich."),
             "b_c" => Smoothing.text_hash("Ich trete ein.")
           }
  end

  test "fakten: ohne gültige Aussage ist es eine leere Extraktion" do
    assert {:error, {:extraction, :empty}} = Pipeline.fakten([], @kontext)

    assert {:error, {:extraction, :empty}} =
             Pipeline.fakten([%{"nummer" => 1, "claim" => "x", "_verworfen" => true}], @kontext)
  end
end
