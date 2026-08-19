defmodule Worker.Timeline.ParserEchteAusdrueckeTest do
  @moduledoc """
  Issue #1068: die 16 Zeitausdrücke, die `qwen3.8:27b` am 2026-08-19 aus
  `seattle-bereinigt-1` extrahiert hat — nachdem der Prompt aus E4 verlangte,
  sie WÖRTLICH abzuschreiben statt sie zu rechnen.

  Der Messlauf hat damit einen Fehler in E2 aufgedeckt: der Parser war gegen
  die kanonischen Formen aus dem Issue-Body gebaut („ab 2000", „die frühen
  2000er"). Echte Sprache trägt Präpositionen und Artikel davor — „ab dem Jahr
  2000", „in den frühen 2000ern". Vorher fiel das nicht auf, weil das Modell
  die Ausdrücke schon zu Datumsformaten normalisiert hatte und den zu engen
  Parser dadurch kaschierte.

  Diese Tabelle ist die Messlatte: sie stammt aus echten Daten, nicht aus
  meiner Vorstellung davon, wie Leute reden.
  """
  use ExUnit.Case, async: true

  alias Worker.Timeline.{Calendar, Parser}

  setup do: {:ok, cal: Calendar.default()}

  # {Ausdruck, erwarteter Typ, auflösbar?}
  @echte [
    # — sollen aufgelöst werden —
    {"ab dem Jahr 2000", :date, true},
    {"in den frühen 2000ern", :date, true},
    {"von 2055 bis 2065", :date, true},
    {"2070", :date, true},
    {"Mitte der 2060er", :date, true},
    {"2080", :date, true},
    {"Ende 2011, am 24. Dezember 2011", :date, true},

    # — korrekt NICHT auf den Zeitstrahl (Uhrzeit) —
    {"um 20.10 Uhr", :time, false},

    # — korrekt NICHT auf den Zeitstrahl (Dauer) —
    {"in den letzten 60 Jahren", :duration, false},
    {"seit mehreren tausend Jahren", :duration, false},
    {"60, 70, 80 Jahre her", :duration, false},
    {"für die Woche", :duration, false},

    # — ankerrelativ: gehört zu #1069 (time_offset), nicht hierher —
    {"gestern Nacht", :vage, false},
    {"vor etwas mehr als einem Jahr", :vage, false},
    {"im Verlauf der kommenden Woche", :vage, false},

    # — zu unbestimmt —
    {"Anfang [des Konflikts]", :vage, false}
  ]

  describe "die 16 Ausdrücke aus dem Messlauf" do
    for {ausdruck, typ, aufloesbar} <- @echte do
      test "#{inspect(ausdruck)} → #{typ}#{if aufloesbar, do: ", auflösbar", else: ""}",
           %{cal: cal} do
        ausdruck = unquote(ausdruck)
        erwarteter_typ = unquote(typ)
        soll_aufloesbar = unquote(aufloesbar)

        case Parser.parse(cal, ausdruck) do
          {:ok, i} ->
            assert i.typ == erwarteter_typ,
                   "#{inspect(ausdruck)}: Typ #{i.typ}, erwartet #{erwarteter_typ}"

            if soll_aufloesbar do
              assert is_integer(i.von),
                     "#{inspect(ausdruck)} muss einen Startpunkt haben"
            else
              refute is_integer(i.von),
                     "#{inspect(ausdruck)} darf KEINEN Startpunkt bekommen"
            end

          :error ->
            refute soll_aufloesbar, "#{inspect(ausdruck)} sollte erkannt werden"
        end
      end
    end
  end

  describe "Dauern tragen ihre Länge (#1068, Softanker für #1069)" do
    test "die Vertragsdauer aus Romeos Anwerbung", %{cal: cal} do
      # „ihr seid für die Woche mein Team" — Block 650 aus seattle-bereinigt-1.
      # Das ist keine Datierung, aber es sagt, über welche Spanne sich die
      # Handlung erstreckt. Genau der Rohstoff für den Zeitrahmen aus #1069.
      {:ok, i} = Parser.parse(cal, "für die Woche")
      assert i.typ == :duration
      assert i.laenge == {1, :week}
      refute is_integer(i.von), "eine Dauer hat keinen Ort"
    end

    test "Mengen in Ziffern und in Worten", %{cal: cal} do
      erwartet = %{
        "sechs Jahre lang" => {6, :year},
        "50 Jahre alt" => {50, :year},
        "zwei Stunden lang" => {2, :hour},
        "in den letzten 60 Jahren" => {60, :year},
        "die nächsten 3 Tage" => {3, :day},
        "für einen Monat" => {1, :month}
      }

      for {s, soll} <- erwartet do
        {:ok, i} = Parser.parse(cal, s)
        assert i.laenge == soll, "#{s} → #{inspect(i.laenge)}, erwartet #{inspect(soll)}"
      end
    end

    test "der bestimmte Artikel zählt als eins", %{cal: cal} do
      # „für die Woche" meint eine Woche — nicht „irgendeine unbestimmte".
      assert {:ok, %{laenge: {1, :week}}} = Parser.parse(cal, "für die Woche")
      assert {:ok, %{laenge: {1, :year}}} = Parser.parse(cal, "für das Jahr")
    end

    test "Beugung darf die Einheit nicht verschlucken", %{cal: cal} do
      # Ein Stamm-Strip von `(en|n|e)$` machte aus „Woche" ein „woch" — das
      # steht in keiner Tabelle, und die Länge fiel still weg. Deshalb Präfix.
      for {s, einheit} <- [
            {"für die Woche", :week},
            {"zwei Wochen lang", :week},
            {"drei Monate lang", :month},
            {"für einen Tag", :day},
            {"zwei Stunden lang", :hour}
          ] do
        {:ok, %{laenge: {_, e}}} = Parser.parse(cal, s)
        assert e == einheit, "#{s} → #{e}"
      end
    end

    test "ohne eindeutige Menge keine erfundene Zahl", %{cal: cal} do
      # Ein Datum trägt keine Länge — und wo keine Menge steht, wird keine
      # geraten.
      assert {:ok, %{typ: :date, laenge: nil}} = Parser.parse(cal, "2070")
    end
  end

  describe "die Präfix-Toleranz darf nicht zu weit gehen" do
    test "eine Dauer bleibt eine Dauer, auch mit Vorspann", %{cal: cal} do
      # Die Gefahr beim Abschneiden von Füllwörtern: „in den letzten 60 Jahren"
      # würde zu „60 Jahren" und dann als Jahr 60 durchgehen. Genau das darf
      # nicht passieren — eine Jahresangabe im Jahr 60 wäre 2000 Jahre daneben.
      for s <- [
            "in den letzten 60 Jahren",
            "seit mehreren tausend Jahren",
            "über 50 Jahre hinweg",
            "die nächsten 3 Tage"
          ] do
        {:ok, i} = Parser.parse(cal, s)
        refute is_integer(i.von), "#{s} darf kein Datum ergeben"
      end
    end

    test "eine echte Jahreszahl mit Vorspann wird trotzdem aufgelöst", %{cal: cal} do
      for s <- ["im Jahr 2070", "ab dem Jahr 2000", "seit 2019"] do
        {:ok, i} = Parser.parse(cal, s)
        assert i.typ == :date, s
        assert is_integer(i.von), "#{s} sollte auflösbar sein"
      end
    end
  end
end
