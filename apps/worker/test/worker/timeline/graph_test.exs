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

  # Issue #911/#958: Spiegel-Tests gegen Resolver.resolve_one/4s Branches —
  # der Drift-Schutz, der die ursprüngliche (zu enge) Prädikat-Fassung schon
  # in der Planungsphase als falsch entlarvt hätte (fehlende in_game_date-
  # Bridge, #676/#729).
  describe "time_signal?/1 — muss Resolver.resolve_one/4s Branches spiegeln" do
    test "absoluter Anker → ja" do
      assert Graph.time_signal?(%{"time_anchor" => "absolute", "time_absolute" => "1888"})
    end

    test "Session-Anker (explizit) → ja" do
      assert Graph.time_signal?(%{"time_anchor" => "session"})
    end

    test "Event-Referenz-Anker → ja" do
      assert Graph.time_signal?(%{"time_anchor" => "event:Turmbrand"})
    end

    test "expliziter Offset ohne Anker → ja (auch mit narration_time present)" do
      assert Graph.time_signal?(%{
               "narration_time" => "present",
               "time_offset" => %{"value" => -10, "unit" => "year"}
             })
    end

    test "in_game_date-Bridge (#676/#729): roher Datums-String ohne time_anchor → ja" do
      assert Graph.time_signal?(%{"in_game_date" => "1888"})
    end

    test "time_absolute-String ohne time_anchor → ja (dieselbe Bridge)" do
      assert Graph.time_signal?(%{"time_absolute" => "1888"})
    end

    test "reiner Präsens-Fallback — kein Anker, kein Offset, kein Datums-String → nein" do
      refute Graph.time_signal?(%{"narration_time" => "present"})
    end

    test "komplett leerer Fakt → nein" do
      refute Graph.time_signal?(%{})
    end

    test "leere Strings zählen nicht als Signal (blank_to_nil)" do
      refute Graph.time_signal?(%{"in_game_date" => "  ", "time_absolute" => ""})
    end

    test "strukturell vorhandenes, aber kaputtes Offset zählt als ja (Resolver verwirft es später separat)" do
      assert Graph.time_signal?(%{
               "narration_time" => "flashback",
               "time_offset" => %{"value" => 5, "unit" => "äon"}
             })
    end

    test "Flashback ohne jedes Signal → nein (identisch zum Präsens-Fall)" do
      refute Graph.time_signal?(%{"narration_time" => "flashback"})
    end
  end
end
