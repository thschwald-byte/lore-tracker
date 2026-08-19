defmodule Worker.Recording.Pipeline.CastEnumTest do
  @moduledoc """
  Issue #976 (Epic #911 Slice 3): das neue `cast_match`-Enum-Feld im
  Extraktions-Schema (`Stages.facts_json_schema/1`) + der zugehörige
  Prompt-Abschnitt (`Prompts.build_facts_extraction_prompt/3`). Reine
  Bau-Funktionen, kein LLM.
  """

  use ExUnit.Case, async: true

  alias Worker.Recording.Pipeline.{Parsing, Prompts, Stages}

  defp utt(n), do: %{id: "u#{n}", discord_id: "s", text: "Text #{n}"}

  describe "Stages.facts_json_schema/1 — cast_match-Enum" do
    test "Enum enthält Roster + Sentinel, cast_match ist required" do
      schema = Stages.facts_json_schema(["Romeo", "Julia"])
      cast_match = get_in(schema, ["properties", "facts", "items", "properties", "cast_match"])

      assert cast_match["type"] == "string"

      assert Enum.sort(cast_match["enum"]) ==
               Enum.sort(["Romeo", "Julia", Parsing.no_cast_match_sentinel()])

      required = get_in(schema, ["properties", "facts", "items", "required"])
      assert "cast_match" in required
      assert "character" in required
    end

    test "leeres Roster -> Enum ist NIE leer (Sentinel bleibt immer drin)" do
      schema = Stages.facts_json_schema([])
      cast_match = get_in(schema, ["properties", "facts", "items", "properties", "cast_match"])

      assert cast_match["enum"] == [Parsing.no_cast_match_sentinel()]
    end

    test "character-Feld bleibt unverändert Freitext (kein enum)" do
      schema = Stages.facts_json_schema(["Romeo"])
      character = get_in(schema, ["properties", "facts", "items", "properties", "character"])

      # Die Invariante ist die ABWESENHEIT des Enums (#976: `cast_match` trägt
      # die strukturierte Bestätigung, `character` bleibt der Freitext-Ist-Stand)
      # — nicht die Feldmenge der Map. Seit #1075 trägt jedes Schema-Feld eine
      # `description`; auf Map-Gleichheit zu prüfen hätte diesen additiven
      # Zusatz als Enum-Regression gemeldet.
      assert character["type"] == "string"
      refute Map.has_key?(character, "enum")
    end
  end

  describe "Prompts.build_facts_extraction_prompt/3 — Cast-Abschnitt" do
    test "nicht-leeres Roster erscheint im Prompt" do
      prompt = Prompts.build_facts_extraction_prompt([utt(1)], %{}, ["Romeo", "Julia"])

      assert prompt =~ "Romeo"
      assert prompt =~ "Julia"
      assert prompt =~ Parsing.no_cast_match_sentinel()
    end

    test "leeres Roster -> Kurzhinweis statt leerer Liste" do
      prompt = Prompts.build_facts_extraction_prompt([utt(1)], %{}, [])

      assert prompt =~ "noch kein bekannter Cast"
      assert prompt =~ Parsing.no_cast_match_sentinel()
    end
  end
end
