defmodule Worker.Jack.Chronik.DatierungTest do
  @moduledoc """
  Issue #1211: aus der Reihenfolge wird ein Datum — aber nur dort, wo ein
  Anker es trägt.

  Der wichtigste Test hier ist der, in dem **nichts** datiert wird: Der alte
  Pfad gab jedem Fakt ohne Zeitangabe den Tag des Session-Ankers, und das
  Ergebnis waren 543 von 544 Einträgen auf demselben Tag (#1092).
  """
  use ExUnit.Case, async: true

  alias Worker.Jack.Chronik.Datierung
  alias Worker.Timeline.Calendar

  defp cal, do: Calendar.default()

  defp e(id, bezug \\ %{"art" => "isoliert"}) do
    %{
      id: id,
      titel: "T",
      text: "t",
      fakt_ids: [],
      wichtigkeit: "phase",
      zeit_bezug: bezug,
      kuratiert?: false,
      kuratierter_text: nil,
      neu?: true
    }
  end

  defp absolut(zeit), do: %{"art" => "absolut", "zeit" => zeit}

  describe "ohne jeden Anker wird nichts datiert" do
    test "drei Einträge, kein Anker, keine Zeitangabe → kein Datum" do
      eintraege = [e("a"), e("b"), e("c")]
      assert Datierung.datieren(eintraege, ["a", "b", "c"], cal(), nil) == %{}
    end

    test "auch ein unlesbarer Zeitausdruck datiert nicht" do
      eintraege = [e("a", absolut("irgendwann im Sommer"))]
      assert Datierung.datieren(eintraege, ["a"], cal(), nil) == %{}
    end
  end

  describe "ein genannter Zeitpunkt datiert seine Stelle" do
    test "der Eintrag bekommt Tag und Ausdruck" do
      eintraege = [e("a", absolut("1888-03-05"))]
      d = Datierung.datieren(eintraege, ["a"], cal(), nil)

      assert %{in_game_day: tag, in_game_date: "1888-03-05"} = d["a"]
      assert is_integer(tag)
    end

    test "die Nachbarn bekommen KEINEN eigenen Tag, nur weil sie daneben stehen" do
      eintraege = [e("a"), e("b", absolut("1888-03-05")), e("c")]
      d = Datierung.datieren(eintraege, ["a", "b", "c"], cal(), nil)

      assert Map.has_key?(d, "b")
      refute Map.has_key?(d, "a")
      refute Map.has_key?(d, "c")
    end
  end

  describe "zwischen zwei festen Punkten" do
    test "ein Eintrag dazwischen bekommt die Spanne, nicht einen erfundenen Tag" do
      eintraege = [e("a", absolut("1888-03-01")), e("b"), e("c", absolut("1888-03-03"))]
      d = Datierung.datieren(eintraege, ["a", "b", "c"], cal(), nil)

      assert %{in_game_day: tag, precision: "day"} = d["b"]
      # Zwischen dem 1. und dem 3. — die Mitte, und taggenau ist das vertretbar.
      assert tag == d["a"].in_game_day + 1
    end

    test "weit auseinanderliegende Anker ergeben eine GRÖBERE Angabe" do
      eintraege = [e("a", absolut("1888-01-01")), e("b"), e("c", absolut("1889-01-01"))]
      d = Datierung.datieren(eintraege, ["a", "b", "c"], cal(), nil)

      # Ein Jahr Abstand: der Eintrag dazwischen ist nicht taggenau zu haben.
      assert d["b"].precision == "year"
    end

    test "ein Monat Abstand ergibt Monatsgenauigkeit" do
      eintraege = [e("a", absolut("1888-03-01")), e("b"), e("c", absolut("1888-03-20"))]
      d = Datierung.datieren(eintraege, ["a", "b", "c"], cal(), nil)
      assert d["b"].precision == "month"
    end

    test "am Rand, ohne zweiten festen Punkt, bleibt es ohne Datum" do
      eintraege = [e("a", absolut("1888-03-01")), e("b")]
      d = Datierung.datieren(eintraege, ["a", "b"], cal(), nil)

      assert Map.has_key?(d, "a")
      refute Map.has_key?(d, "b")
    end
  end

  describe "der Session-Anker" do
    test "datiert den ERSTEN Eintrag, nicht alle" do
      eintraege = [e("a"), e("b"), e("c")]
      anker = %{in_game_day: 700_000, precision: :day}

      d = Datierung.datieren(eintraege, ["a", "b", "c"], cal(), anker)

      assert d["a"].in_game_day == 700_000
      # Genau das ist der #1092-Fehler, der nicht zurückkommen darf: nicht
      # jeder Eintrag bekommt den Ankertag.
      refute Map.has_key?(d, "b")
      refute Map.has_key?(d, "c")
    end

    test "seine Präzision ist die Untergrenze (#1092)" do
      eintraege = [e("a")]
      anker = %{in_game_day: 700_000, precision: :year}

      d = Datierung.datieren(eintraege, ["a"], cal(), anker)
      assert d["a"].precision == "year"
    end

    test "ein genannter Zeitpunkt hat Vorrang vor dem Session-Anker" do
      eintraege = [e("a", absolut("1888-03-05"))]
      anker = %{in_game_day: 700_000, precision: :day}

      d = Datierung.datieren(eintraege, ["a"], cal(), anker)
      assert d["a"].in_game_date == "1888-03-05"
      refute d["a"].in_game_day == 700_000
    end
  end

  describe "Ränder" do
    test "keine Einträge" do
      assert Datierung.datieren([], [], cal(), nil) == %{}
    end

    test "eine Reihenfolge, die einen unbekannten Eintrag nennt, stört nicht" do
      assert Datierung.datieren([e("a")], ["a", "weg"], cal(), nil) == %{}
    end
  end
end
