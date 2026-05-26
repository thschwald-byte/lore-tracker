defmodule Worker.Recording.PipelineChronikFilterTest do
  @moduledoc """
  Issue #230: Stage-4-Post-Filter gegen selbst-eingestandene Fabrication.

  Stage 4 erfindet manchmal Chronik-Einträge mit Labels wie "Nicht im
  Transkript erwähnt" oder Date-Placeholders wie "Unbekannt" — getrieben
  vom Prompt der "mindestens einen Eintrag pro Kapitel" einfordert.
  `filter_fabricated_chronik/1` droppt diese Einträge per Sentinel-Regex
  und loggt eine Warnung.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  alias Worker.Recording.Pipeline

  describe "filter_fabricated_chronik/1 — sentinel matches" do
    test "in_game_date == 'Nicht im Transkript erwähnt' → ge-dropped" do
      entry = %{
        "in_game_date" => "Nicht im Transkript erwähnt",
        "label" => "Aufbruch aus Oakhaven",
        "summary" => "Die Helden verlassen die Redaktion."
      }

      log = capture_log(fn -> assert [] == Pipeline.filter_fabricated_chronik([entry]) end)
      assert log =~ "Stage 4: filtered 1 fabricated chronik entries"
    end

    test "label enthält 'nicht erwähnt' (case-insensitive) → ge-dropped" do
      entry = %{
        "in_game_date" => "Tag 14",
        "label" => "NICHT ERWÄHNT — generisches Ereignis",
        "summary" => "."
      }

      assert [] == Pipeline.filter_fabricated_chronik([entry])
    end

    test "in_game_date == 'Unbekannt' → ge-dropped" do
      entry = %{"in_game_date" => "Unbekannt", "label" => "Etwas", "summary" => "x"}
      assert [] == Pipeline.filter_fabricated_chronik([entry])
    end

    test "in_game_date == 'N/A' → ge-dropped" do
      entry = %{"in_game_date" => "N/A", "label" => "X", "summary" => "y"}
      assert [] == Pipeline.filter_fabricated_chronik([entry])
    end

    test "summary enthält 'Keine Angabe' → ge-dropped" do
      entry = %{
        "in_game_date" => "Tag 1",
        "label" => "Start",
        "summary" => "Keine Angabe zum Geschehen."
      }

      assert [] == Pipeline.filter_fabricated_chronik([entry])
    end
  end

  describe "filter_fabricated_chronik/1 — keeps legitimate entries" do
    test "echter Eintrag mit Tag-Datum bleibt" do
      entry = %{
        "in_game_date" => "Tag 14",
        "label" => "Aufbruch nach Oakhaven",
        "summary" => "Die Gruppe verlässt die Stadt im Morgengrauen."
      }

      assert [^entry] = Pipeline.filter_fabricated_chronik([entry])
    end

    test "narrativer Marker als Datum bleibt (Issue-Doku-Pattern)" do
      entry = %{
        "in_game_date" => "Erste Begegnung",
        "label" => "Treffen mit Gardal",
        "summary" => "Die Helden begegnen Gardal dem Krummbein."
      }

      assert [_] = Pipeline.filter_fabricated_chronik([entry])
    end

    test "Wort 'vermutet' in summary ist KEIN Fabrication-Trigger (legitimer Plot-Wortschatz)" do
      entry = %{
        "in_game_date" => "Tag 2",
        "label" => "Spurensuche",
        "summary" => "Der Spielleiter vermutet einen Verrat in den eigenen Reihen."
      }

      assert [_] = Pipeline.filter_fabricated_chronik([entry])
    end

    test "Wort 'unklar' in summary ist KEIN Trigger" do
      entry = %{
        "in_game_date" => "Tag 3",
        "label" => "Mord",
        "summary" => "Die Motivation des Mörders bleibt unklar."
      }

      assert [_] = Pipeline.filter_fabricated_chronik([entry])
    end
  end

  describe "filter_fabricated_chronik/1 — edge cases" do
    test "leere Liste → leere Liste" do
      assert [] == Pipeline.filter_fabricated_chronik([])
    end

    test "gemischte Liste: drei Real, einer fabricated → drei behalten" do
      real_1 = %{"in_game_date" => "Tag 1", "label" => "Start", "summary" => "."}
      real_2 = %{"in_game_date" => "Tag 2", "label" => "Mitte", "summary" => "."}
      real_3 = %{"in_game_date" => "Tag 3", "label" => "Ende", "summary" => "."}

      fabricated = %{
        "in_game_date" => "Nicht im Transkript erwähnt",
        "label" => "Filler",
        "summary" => "."
      }

      assert [^real_1, ^real_2, ^real_3] =
               Pipeline.filter_fabricated_chronik([real_1, fabricated, real_2, real_3])
    end

    test "non-list-Input → leere Liste" do
      assert [] == Pipeline.filter_fabricated_chronik(nil)
      assert [] == Pipeline.filter_fabricated_chronik("garbage")
      assert [] == Pipeline.filter_fabricated_chronik(%{"entries" => []})
    end

    test "alternative Field-Names ('date' / 'title' / 'description') werden auch gefiltert" do
      # parse_chronik_json normalisiert nicht — LLMs liefern manchmal alt. Keys.
      entry = %{
        "date" => "Nicht im Transkript erwähnt",
        "title" => "X",
        "description" => "y"
      }

      assert [] == Pipeline.filter_fabricated_chronik([entry])
    end
  end
end
