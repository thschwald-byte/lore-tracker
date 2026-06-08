defmodule Worker.Recording.Pipeline.FactsParserTest do
  @moduledoc """
  Issue #651 (Wahrheitsbild, Phase A): Parser des Extraktions-Outputs
  (`Worker.Recording.Pipeline.Parsing.parse_facts_json/2`). Pur — kein LLM,
  kein Mnesia. Testet Normalisierung, `[uN]`→UUID-Ref-Auflösung, Flag-statt-Drop
  und die Fehlerpfade.
  """

  use ExUnit.Case, async: true

  alias Worker.Recording.Pipeline.Parsing

  # utterance_index_map bildet u1→id-a, u2→id-b, u3→id-c (Reihenfolge = with_index).
  defp utts, do: [%{id: "id-a"}, %{id: "id-b"}, %{id: "id-c"}]

  test "normalisiert Fakten + löst source_refs (uN → UUID) auf" do
    raw = ~s({"facts":[
      {"claim":"Der König beauftragt Holmes.","character":"König","in_game_date":"20. März 1888","source_refs":["u1","u2"]},
      {"claim":"Irene flieht ins Ausland.","character":"Irene Adler","source_refs":["u3"]}
    ]})

    assert {:ok, [f1, f2]} = Parsing.parse_facts_json(raw, utts())

    assert f1["id"] == "f1"
    assert f1["claim"] == "Der König beauftragt Holmes."
    assert f1["character_alias"] == "König"
    assert f1["entity_id"] == "könig"
    assert f1["in_game_date"] == "20. März 1888"
    assert f1["source_refs"] == ["id-a", "id-b"]
    assert f1["verified?"] == false

    assert f2["id"] == "f2"
    assert f2["source_refs"] == ["id-c"]
  end

  test "halluzinierte source_refs werden gefiltert, der Fakt bleibt (Flag statt Drop)" do
    raw = ~s({"facts":[{"claim":"Unbelegt.","character":"X","source_refs":["u-fake","u999"]}]})

    assert {:ok, [f]} = Parsing.parse_facts_json(raw, utts())
    assert f["claim"] == "Unbelegt."
    assert f["source_refs"] == []
  end

  test "Fakt ohne claim wird verworfen (Junk)" do
    raw = ~s({"facts":[
      {"claim":"Gültig.","character":"A","source_refs":["u1"]},
      {"claim":"   ","character":"B","source_refs":["u2"]},
      {"character":"C","source_refs":["u3"]}
    ]})

    assert {:ok, facts} = Parsing.parse_facts_json(raw, utts())
    assert Enum.map(facts, & &1["claim"]) == ["Gültig."]
  end

  test "in_game_date leer/fehlend → nil; fehlende character → leerer alias + entity_id" do
    raw = ~s({"facts":[
      {"claim":"A.","character":"Holmes","in_game_date":"","source_refs":["u1"]},
      {"claim":"B.","source_refs":["u2"]}
    ]})

    assert {:ok, [a, b]} = Parsing.parse_facts_json(raw, utts())
    assert a["in_game_date"] == nil
    assert b["character_alias"] == ""
    assert b["entity_id"] == ""
  end

  test "entity_id ist der normalisierte Alias (lowercase, Whitespace zusammengefasst)" do
    raw = ~s({"facts":[{"claim":"X.","character":"  Wilhelm   von  Ormstein ","source_refs":["u1"]}]})
    assert {:ok, [f]} = Parsing.parse_facts_json(raw, utts())
    assert f["character_alias"] == "Wilhelm   von  Ormstein"
    assert f["entity_id"] == "wilhelm von ormstein"
  end

  describe "Fehlerpfade" do
    test "undecodierbar → :parse_failed" do
      assert {:error, :parse_failed} = Parsing.parse_facts_json("kein json {{{", utts())
    end

    test "JSON ohne facts-Key → :no_facts_key" do
      assert {:error, :no_facts_key} = Parsing.parse_facts_json(~s({"foo":1}), utts())
    end

    test "nil → :parse_failed" do
      assert {:error, :parse_failed} = Parsing.parse_facts_json(nil, utts())
    end

    test "leere facts-Liste → {:ok, []}" do
      assert {:ok, []} = Parsing.parse_facts_json(~s({"facts":[]}), utts())
    end
  end
end
