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
