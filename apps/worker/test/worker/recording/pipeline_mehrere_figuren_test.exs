defmodule Worker.Recording.PipelineMehrereFigurenTest do
  @moduledoc """
  Issue #1066: eine Aussage kann mehrere Figuren tragen.

  Vorher hielt ein Fakt genau eine fest — bei „Verrin versorgt die Wunde des
  Alten" fiel der Alte heraus, und wer nach ihm suchte, fand die Aussage nicht.
  An der Fable-Referenz gemessen betraf das 42 von 419 Aussagen, bei einer
  Figur jede fünfte.

  Geprüft wird beides: dass die neue Liste ankommt, UND dass Bestandsfakten mit
  den beiden Alt-Skalaren unverändert gelesen werden — die Migration muss ohne
  Regenerate tragen (Muster `thread` → `threads`, #953).
  """

  use ExUnit.Case, async: true

  alias Worker.Recording.Pipeline.Parsing

  # Ein Fakt, wie ihn Jack heute liefert.
  defp neu(figuren) do
    %{
      "claim" => "Verrin versorgt die Wunde des Alten.",
      "characters" => figuren,
      "narration_time" => "present",
      "time_anchor" => "session",
      "fact_type" => "ereignis",
      "threads" => ["die Werkstatt"],
      "source_refs" => ["u1"],
      "beleg" => "Verrin kniet neben dem Alten"
    }
  end

  defp parse(fakt) do
    {:ok, [f]} =
      Parsing.parse_facts_json(Jason.encode!(%{"facts" => [fakt]}), [%{id: "id-a"}])

    f
  end

  describe "Extraktion: aus der Liste werden Figuren und Entitäten" do
    test "beide Figuren landen im Fakt, die handelnde zuerst" do
      f =
        parse(
          neu([
            %{"name" => "Verrin", "cast" => "Verrin"},
            %{"name" => "der Alte", "cast" => ""}
          ])
        )

      assert f["characters"] == ["Verrin", "der Alte"]
      assert length(f["entity_ids"]) == 2
    end

    test "die beiden Skalare bleiben — als ERSTGENANNTE Figur" do
      # Feldkonservativ: ein Leser, der noch nicht umgestellt ist, sieht
      # weiterhin genau das, was er vorher sah (die handelnde Figur).
      f =
        parse(
          neu([
            %{"name" => "Verrin", "cast" => "Verrin"},
            %{"name" => "der Alte", "cast" => ""}
          ])
        )

      assert f["character_alias"] == "Verrin"
      assert f["entity_id"] == List.first(f["entity_ids"])
    end

    test "der Cast-Treffer gewinnt je Figur über den Freitext" do
      f =
        parse(
          neu([
            %{"name" => "der Alte", "cast" => "Verrin"},
            %{"name" => "die Frau am Tresen", "cast" => ""}
          ])
        )

      assert f["characters"] == ["Verrin", "die Frau am Tresen"]
    end

    test "eine Weltaussage trägt keine Figur" do
      f = parse(neu([]))
      assert f["characters"] == []
      assert f["character_alias"] == ""
      assert f["entity_ids"] == []
    end

    test "leere Namen und Dubletten fallen weg" do
      f =
        parse(
          neu([
            %{"name" => "Verrin", "cast" => ""},
            %{"name" => "  ", "cast" => ""},
            %{"name" => "Verrin", "cast" => ""}
          ])
        )

      assert f["characters"] == ["Verrin"]
    end
  end

  describe "Bestandsfakten ohne Regenerate" do
    test "die alten Skalare werden weiter gelesen" do
      alt = %{
        "claim" => "Der Alte raucht.",
        "character" => "der Alte",
        "cast_match" => "",
        "narration_time" => "present",
        "time_anchor" => "session",
        "fact_type" => "zustand",
        "threads" => [],
        "source_refs" => ["u1"],
        "beleg" => "raucht"
      }

      f = parse(alt)
      assert f["characters"] == ["der Alte"]
      assert f["character_alias"] == "der Alte"
    end

    test "fact_characters/1 liest beide Formen" do
      assert Parsing.fact_characters(%{"characters" => ["A", "B"]}) == ["A", "B"]
      assert Parsing.fact_characters(%{"character_alias" => "A"}) == ["A"]
      assert Parsing.fact_characters(%{"character_alias" => ""}) == []
      assert Parsing.fact_characters(%{}) == []
    end

    test "fact_entity_ids/1 liest beide Formen" do
      assert Parsing.fact_entity_ids(%{"entity_ids" => ["a", "b"]}) == ["a", "b"]
      assert Parsing.fact_entity_ids(%{"entity_id" => "a"}) == ["a"]
      assert Parsing.fact_entity_ids(%{"entity_id" => ""}) == []
    end

    test "fact_identities/1 paart ID und Name in der Reihenfolge des Fakts" do
      f = %{"characters" => ["Verrin", "der Alte"], "entity_ids" => ["verrin", "der alte"]}
      assert Parsing.fact_identities(f) == [{"verrin", "Verrin"}, {"der alte", "der Alte"}]
    end

    test "fact_identities/1 springt auf den normalisierten Namen ein, wo die ID fehlt" do
      # Alt-Bestand: nur der Skalar, keine Liste.
      f = %{"character_alias" => "Der Alte", "entity_id" => ""}
      assert [{id, "Der Alte"}] = Parsing.fact_identities(f)
      assert id != ""
    end
  end
end
