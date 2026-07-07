defmodule Worker.Timeline.GraphTest do
  @moduledoc "Issue #724 Slice A: Event-Referenz-Graph (Topo + Zyklus-Schutz)."
  use ExUnit.Case, async: true

  alias Worker.Timeline.{Calendar, Graph}

  defp cal, do: Calendar.default()
  defp anchor_day, do: Calendar.to_day(cal(), {1000, 6, 1})

  defp by_id(results), do: Map.new(results, &{&1["id"], &1})

  describe "einfache Auflösung" do
    test "leere Liste" do
      assert Graph.resolve([], cal(), anchor_day()) == []
    end

    test "Präsens-Fakten sitzen alle am Session-Anker; Reihenfolge bleibt erhalten" do
      facts = [
        %{"id" => "a", "claim" => "Erstes", "narration_time" => "present"},
        %{"id" => "b", "claim" => "Zweites", "narration_time" => "present"}
      ]

      out = Graph.resolve(facts, cal(), anchor_day())
      assert Enum.map(out, & &1["id"]) == ["a", "b"]
      assert Enum.all?(out, &(&1["in_game_day"] == anchor_day()))
      assert Enum.all?(out, &(&1["anchor_status"] == "resolved"))
    end
  end

  describe "Event-Referenz-Kanten" do
    test "lineare Kette B→A, C→B löst in Abhängigkeitsreihenfolge auf" do
      facts = [
        %{"id" => "a", "claim" => "Der Turmbrand", "narration_time" => "present"},
        %{
          "id" => "b",
          "claim" => "Danach die Flucht",
          "time_anchor" => "event:Turmbrand",
          "time_offset" => %{"value" => 1, "unit" => "day"}
        },
        %{
          "id" => "c",
          "claim" => "Noch später",
          "time_anchor" => "event:Flucht",
          "time_offset" => %{"value" => 2, "unit" => "day"}
        }
      ]

      m = by_id(Graph.resolve(facts, cal(), anchor_day()))
      assert m["a"]["in_game_day"] == anchor_day()
      assert m["b"]["in_game_day"] == anchor_day() + 1
      assert m["c"]["in_game_day"] == anchor_day() + 3
      assert Enum.all?(~w(a b c), &(m[&1]["anchor_status"] == "resolved"))
    end

    test "Diamant (B→A, C→A, D→B) löst alle auf" do
      facts = [
        %{"id" => "a", "claim" => "Wurzel Ereignis", "narration_time" => "present"},
        %{
          "id" => "b",
          "claim" => "Zweig B",
          "time_anchor" => "event:Wurzel",
          "time_offset" => %{"value" => 1, "unit" => "day"}
        },
        %{
          "id" => "c",
          "claim" => "Zweig C",
          "time_anchor" => "event:Wurzel",
          "time_offset" => %{"value" => 2, "unit" => "day"}
        },
        %{
          "id" => "d",
          "claim" => "Blatt D",
          "time_anchor" => "event:Zweig B",
          "time_offset" => %{"value" => 1, "unit" => "day"}
        }
      ]

      m = by_id(Graph.resolve(facts, cal(), anchor_day()))
      assert m["a"]["in_game_day"] == anchor_day()
      assert m["b"]["in_game_day"] == anchor_day() + 1
      assert m["c"]["in_game_day"] == anchor_day() + 2
      assert m["d"]["in_game_day"] == anchor_day() + 2
    end
  end

  describe "Zyklus- und Fehler-Schutz" do
    test "Zyklus A→B→A → beide unknown, terminiert" do
      facts = [
        %{"id" => "a", "claim" => "Alpha", "time_anchor" => "event:Beta"},
        %{"id" => "b", "claim" => "Beta", "time_anchor" => "event:Alpha"}
      ]

      m = by_id(Graph.resolve(facts, cal(), anchor_day()))
      assert m["a"]["in_game_day"] == nil
      assert m["b"]["in_game_day"] == nil
      assert m["a"]["anchor_status"] == "unknown"
      assert m["b"]["anchor_status"] == "unknown"
    end

    test "nicht auflösbare Referenz (kein Match) → unknown" do
      facts = [%{"id" => "a", "claim" => "X", "time_anchor" => "event:existiert nicht"}]
      m = by_id(Graph.resolve(facts, cal(), anchor_day()))
      assert m["a"]["anchor_status"] == "unknown"
    end

    test "mehrdeutige Referenz (2 Treffer) → konservativ unknown" do
      facts = [
        %{"id" => "a", "claim" => "Der Kampf am Fluss", "narration_time" => "present"},
        %{"id" => "b", "claim" => "Ein weiterer Kampf", "narration_time" => "present"},
        %{"id" => "c", "claim" => "Danach", "time_anchor" => "event:Kampf"}
      ]

      m = by_id(Graph.resolve(facts, cal(), anchor_day()))
      # "Kampf" matcht a UND b → mehrdeutig → c unknown, a/b bleiben aufgelöst.
      assert m["c"]["anchor_status"] == "unknown"
      assert m["a"]["anchor_status"] == "resolved"
    end

    test "Referenz auf unauflösbares Ziel erbt unknown" do
      facts = [
        %{"id" => "a", "claim" => "Undatierbar", "narration_time" => "flashback"},
        %{
          "id" => "b",
          "claim" => "Bezug",
          "time_anchor" => "event:Undatierbar",
          "time_offset" => %{"value" => 1, "unit" => "day"}
        }
      ]

      m = by_id(Graph.resolve(facts, cal(), anchor_day()))
      # a ist Flashback ohne Offset → unknown; b hängt daran → ebenfalls unknown.
      assert m["a"]["in_game_day"] == nil
      assert m["b"]["in_game_day"] == nil
    end
  end

  test "Fakten ohne id bekommen stabile Auto-ids und werden aufgelöst" do
    facts = [%{"claim" => "ohne id", "narration_time" => "present"}]
    [out] = Graph.resolve(facts, cal(), anchor_day())
    assert out["in_game_day"] == anchor_day()
  end
end
