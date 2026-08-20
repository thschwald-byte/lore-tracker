defmodule Worker.Timeline.ParserTest do
  @moduledoc """
  Issue #1068 (E2): Tabellentests für den Zeitausdruck-Parser.

  Die Pflichtfälle stammen aus dem Issue-Body, die vier Regressionsstrings aus
  echten Daten der Kampagne `free-seattle-bereinigt` (worker_prod, 2026-08-17).
  """
  use ExUnit.Case, async: true

  alias Worker.Timeline.{Calendar, Parser}

  setup do
    cal = Calendar.default()
    {:ok, cal: cal}
  end

  defp intervall(cal, s) do
    {:ok, i} = Parser.parse(cal, s)
    i
  end

  defp als_datum(cal, i) do
    {
      i.von && Calendar.from_day(cal, i.von),
      i.bis && Calendar.from_day(cal, i.bis)
    }
  end

  describe "Typ-Erkennung — drei von vier gehören NICHT auf den Zeitstrahl" do
    test "Dauer wird nie zu einem Datum", %{cal: cal} do
      # Der Kernfall aus #1068: „Trolle werden 50 Jahre alt" darf nicht als
      # Jahr 50 auf dem Zeitstrahl landen. Dass das bisher nicht passierte, lag
      # am Zufall (das Modell setzte dort kein Datum), nicht an einer Schranke.
      for s <- [
            "sechs Jahre lang",
            "50 Jahre alt",
            "zwei Stunden lang",
            "drei Tage hindurch",
            "zehn Jahre später"
          ] do
        i = intervall(cal, s)
        assert i.typ == :duration, "#{s} → #{i.typ}"
        assert i.von == nil and i.bis == nil
      end
    end

    test "Uhrzeit ist feiner als ein Tag — der Tageszähler kann sie nicht", %{cal: cal} do
      for s <- ["am Abend", "um 20:10 Uhr", "Freitagnachmittag", "morgens", "in der Dämmerung"] do
        assert intervall(cal, s).typ == :time, s
      end
    end

    test "wiederkehrend ist kein Punkt", %{cal: cal} do
      for s <- ["jeden Freitag", "täglich", "alle 3 Tage"] do
        assert intervall(cal, s).typ == :set, s
      end
    end

    test "vage Ausdrücke werden erkannt, aber nicht geraten", %{cal: cal} do
      # „damals" ist mit 17 Vorkommen der häufigste Zeitausdruck im ganzen
      # Transkript — und war bisher nicht darstellbar.
      for s <- ["damals", "früher", "vor langer Zeit", "irgendwann"] do
        i = intervall(cal, s)
        assert i.typ == :vage, s
        assert i.von == nil and i.bis == nil, "#{s} darf kein Datum bekommen"
      end
    end

    test "die Reihenfolge der Erkennung ist Vertrag", %{cal: cal} do
      # Ohne Vorrang der Dauer-Prüfung frisst das blanke-Jahr-Muster die Zahl.
      assert intervall(cal, "50 Jahre alt").typ == :duration
      refute intervall(cal, "50 Jahre alt").von
      # Die blanke Zahl allein ist dagegen sehr wohl ein Jahr.
      assert intervall(cal, "50").typ == :date
    end
  end

  describe "blankes Jahr — die Kernkorrektur" do
    test "2011 ist das ganze Jahr, nicht der 1. Januar", %{cal: cal} do
      i = intervall(cal, "2011")
      assert i.typ == :date
      assert i.praezision == :year
      assert als_datum(cal, i) == {{2011, 1, 1}, {2011, 12, 31}}
    end

    test "Regression: Calendar.parse gab hier still den 1. Januar zurück", %{cal: cal} do
      # Das ist die Stelle, an der aus einer Jahresangabe ein taggenaues Datum
      # wurde — ohne dass irgendwo vermerkt war, dass es geraten ist.
      alt = Calendar.parse(cal, "2011")
      assert alt == {:ok, {2011, 1, 1}}

      neu = intervall(cal, "2011")
      assert neu.bis != neu.von, "ein Jahr ist kein Tag"
    end
  end

  describe "Pflichtfälle aus dem Issue-Body" do
    test "offene Spannen", %{cal: cal} do
      for s <- ["ab 2000", "seit 2000"] do
        i = intervall(cal, s)
        assert {{2000, 1, 1}, nil} = als_datum(cal, i), s
      end

      i = intervall(cal, "nach 2019")
      assert {{2019, 1, 1}, nil} = als_datum(cal, i)

      # „vor 2080" endet mit dem letzten Tag von 2079 — 2080 selbst ist raus.
      i = intervall(cal, "vor 2080")
      assert {nil, {2079, 12, 31}} = als_datum(cal, i)
    end

    test "geschlossene Bereiche", %{cal: cal} do
      for s <- ["von 2001 bis 2009", "2001–2009", "2001-2009"] do
        i = intervall(cal, s)
        assert als_datum(cal, i) == {{2001, 1, 1}, {2009, 12, 31}}, s
      end
    end

    test "verdrehter Bereich wird geordnet statt verworfen", %{cal: cal} do
      assert als_datum(cal, intervall(cal, "von 2009 bis 2001")) ==
               {{2001, 1, 1}, {2009, 12, 31}}
    end

    test "Jahres-Drittel", %{cal: cal} do
      assert {{2012, 1, 1}, {2012, 4, 30}} = als_datum(cal, intervall(cal, "Anfang 2012"))
      assert {{2012, 5, 1}, {2012, 8, 31}} = als_datum(cal, intervall(cal, "Mitte 2012"))
      assert {{2012, 9, 1}, {2012, 12, 31}} = als_datum(cal, intervall(cal, "Ende 2012"))
    end

    test "Saisons", %{cal: cal} do
      assert {{2040, 1, 1}, {2040, 3, 31}} = als_datum(cal, intervall(cal, "Winter 2040"))
      assert {{2040, 4, 1}, {2040, 6, 30}} = als_datum(cal, intervall(cal, "Frühjahr 2040"))
      assert {{2040, 7, 1}, {2040, 9, 30}} = als_datum(cal, intervall(cal, "Sommer 2040"))
      assert {{2040, 10, 1}, {2040, 12, 31}} = als_datum(cal, intervall(cal, "Herbst 2040"))
    end

    test "Jahrzehnte und ihre Drittel (D1: früh 0–3, Mitte 4–6, spät 7–9)", %{cal: cal} do
      assert als_datum(cal, intervall(cal, "die frühen 2000er")) ==
               {{2000, 1, 1}, {2003, 12, 31}}

      assert als_datum(cal, intervall(cal, "Mitte der 2060er")) ==
               {{2064, 1, 1}, {2066, 12, 31}}

      assert als_datum(cal, intervall(cal, "Ende der 2060er")) ==
               {{2067, 1, 1}, {2069, 12, 31}}

      # Ohne Drittel-Wort das ganze Jahrzehnt.
      i = intervall(cal, "2010er")
      assert als_datum(cal, i) == {{2010, 1, 1}, {2019, 12, 31}}
      assert i.praezision == :decade
    end
  end

  describe "Regressionen aus echten Daten (free-seattle-bereinigt)" do
    test "\"2055 bis 2065\" blieb bisher ein roher String", %{cal: cal} do
      assert als_datum(cal, intervall(cal, "2055 bis 2065")) ==
               {{2055, 1, 1}, {2065, 12, 31}}
    end

    test "\"1.1.2061 \" mit Leerzeichen am Ende", %{cal: cal} do
      i = intervall(cal, "1.1.2061 ")
      assert i.praezision == :day
      assert als_datum(cal, i) == {{2061, 1, 1}, {2061, 1, 1}}
    end

    test "\"1.1.200\" — das Modell meinte 2000, schrieb aber Jahr 200", %{cal: cal} do
      # Der Parser kann das nicht heilen; er darf es aber auch nicht
      # verschlimmern. Jahr 200 bleibt Jahr 200 — die Korrektur ist Kuration.
      assert als_datum(cal, intervall(cal, "1.1.200")) == {{200, 1, 1}, {200, 1, 1}}
    end

    test "\"in den frühen 2000ern\" wird nicht mehr zu einem Tag", %{cal: cal} do
      # Vorher: in_game_date "1.1.2010", precision nil.
      i = intervall(cal, "die frühen 2000er")
      assert i.praezision == :year
      assert i.von != i.bis
    end
  end

  describe "exakte Formen bleiben exakt" do
    test "alle vier Alt-Muster ergeben ein Länge-1-Intervall", %{cal: cal} do
      for s <- ["2011-12-24", "24.12.2011", "24. Dezember 2011"] do
        i = intervall(cal, s)
        assert i.von == i.bis, s
        assert i.praezision == :day, s
        assert als_datum(cal, i) == {{2011, 12, 24}, {2011, 12, 24}}, s
      end
    end

    test "ungültige Tage werden nicht stillschweigend geklemmt", %{cal: cal} do
      # 30. Februar existiert im Default-Kalender nicht (28 Tage, keine
      # Schaltjahre) — das darf kein 1. März werden.
      assert Parser.parse(cal, "30.2.2011") == :error
    end

    test "Monat plus Jahr", %{cal: cal} do
      assert als_datum(cal, intervall(cal, "2011-03")) == {{2011, 3, 1}, {2011, 3, 31}}
      assert als_datum(cal, intervall(cal, "März 2011")) == {{2011, 3, 1}, {2011, 3, 31}}
    end
  end

  describe "Nicht-Erkanntes" do
    test "leerer und sinnfreier String", %{cal: cal} do
      assert Parser.parse(cal, "") == :error
      assert Parser.parse(cal, "   ") == :error
      assert Parser.parse(cal, "Romeo trifft Julia") == :error
    end

    test "kein String", %{cal: cal} do
      assert Parser.parse(cal, nil) == :error
    end
  end

  describe "Verdrahtung — der Parser wirkt dort, wo die Präzision entsteht (#1068)" do
    test "infer_precision liest die Präzision aus dem Intervall, nicht aus der Schreibweise",
         %{cal: cal} do
      alias Worker.Timeline.Resolver

      # Das frühere Dreizeiler-Muster kannte nur „blanke Zahl" und
      # „Zahl-Zahl" — alles andere war :day. Damit hätte der Session-Anker
      # (#1092) ein saisongenaues Datum als taggenau gespeichert und die
      # Korrektur von #1092 wäre durch die Hintertür ausgehebelt gewesen.
      assert Resolver.infer_precision(cal, "Herbst 2040") == :season
      assert Resolver.infer_precision(cal, "die frühen 2000er") == :year
      assert Resolver.infer_precision(cal, "Mitte 2012") == :month
      assert Resolver.infer_precision(cal, "2011") == :year
      assert Resolver.infer_precision(cal, "24. Dezember 2011") == :day
    end

    test "Nicht-Datums-Typen erben KEINE Präzision und kein Datum", %{cal: cal} do
      alias Worker.Timeline.Resolver

      for s <- ["50 Jahre alt", "am Abend", "damals", "jeden Freitag"] do
        assert Calendar.parse(cal, s) == :error, "#{s} darf kein Datum ergeben"
        # :day ist hier „keine Aussage", nicht „taggenau" — der Aufrufer
        # bekommt ohnehin kein Datum, an dem sie hängen könnte.
        assert Resolver.infer_precision(cal, s) == :day, s
      end
    end

    test "Calendar.parse bleibt für seine drei Aufrufer unverändert", %{cal: cal} do
      # Der Adapter darf die exakten Alt-Formen nicht verschieben.
      assert Calendar.parse(cal, "2011-12-24") == {:ok, {2011, 12, 24}}
      assert Calendar.parse(cal, "24.12.2011") == {:ok, {2011, 12, 24}}
      assert Calendar.parse(cal, "24. Dezember 2011") == {:ok, {2011, 12, 24}}
      assert Calendar.parse(cal, "2011") == {:ok, {2011, 1, 1}}
      assert Calendar.parse(cal, "Romeo trifft Julia") == :error
    end
  end

  describe "Positionsfilter — was auf den Zeitstrahl darf (#1068 E3)" do
    alias Worker.Timeline.Graph

    test "erkannte Nicht-Datums-Typen fallen raus", %{cal: cal} do
      for s <- ["sechs Jahre lang", "am Abend", "jeden Freitag", "damals"] do
        refute Graph.datierbar?(%{"in_game_date" => s}, cal), "#{s} hat keine Position"
      end
    end

    test "Datumsangaben bleiben drin", %{cal: cal} do
      for s <- ["24. Dezember 2011", "2011", "Herbst 2040", "die frühen 2000er"] do
        assert Graph.datierbar?(%{"in_game_date" => s}, cal), s
      end
    end

    test "UNVERSTANDENE Strings bleiben drin — das ist der #724-Vertrag", %{cal: cal} do
      # „Ich verstehe es nicht" und „ich verstehe es, und es ist keine
      # Position" sind verschiedene Aussagen. Ein unauflösbares Datum bekommt
      # seinen Chronik-Eintrag mit nil-Tageszähler und bewahrtem Roh-String;
      # es hier mit auszusortieren würde bestehende Einträge stillschweigend
      # verschwinden lassen.
      for s <- ["Tag 5", "im dritten Zyklus", "Mondwende der Ahnen"] do
        assert Parser.parse(cal, s) == :error, "Vorbedingung: #{s} ist unverstanden"
        assert Graph.datierbar?(%{"in_game_date" => s}, cal), s
      end
    end

    test "Anker und Offset tragen die Position anderswoher", %{cal: cal} do
      # Ein Fakt mit „sechs Jahre lang" im Datumsfeld, aber gesetztem Anker,
      # bezieht seine Position aus dem Anker — der String ist dann nicht die
      # Quelle und darf ihn nicht disqualifizieren.
      assert Graph.datierbar?(
               %{"in_game_date" => "sechs Jahre lang", "time_anchor" => "session"},
               cal
             )

      assert Graph.datierbar?(
               %{
                 "in_game_date" => "am Abend",
                 "time_offset" => %{"value" => -10, "unit" => "year"}
               },
               cal
             )

      # „unknown" ist KEIN Anker.
      refute Graph.datierbar?(
               %{"in_game_date" => "am Abend", "time_anchor" => "unknown"},
               cal
             )
    end

    test "der Resolver datiert eine Dauer nicht", %{cal: cal} do
      alias Worker.Timeline.Resolver

      # Der eigentliche Schutz: selbst wenn ein solcher Fakt den Vorfilter
      # passierte, bekäme er kein Datum.
      r = Resolver.resolve_one(%{"in_game_date" => "50 Jahre alt"}, cal, nil)
      assert r.in_game_day == nil
      assert r.anchor_status == :unknown
    end
  end

  describe "Feldlisten-Lücke (#1068 E3)" do
    alias Worker.Recording.Pipeline.Parsing

    test "time_anchor erreicht den Fakt-Blob", %{cal: _} do
      # Bis #1068 fehlte `time_anchor` in `normalize_fact/4`s fixer Feldliste.
      # Der Resolver kennt vier Ankertypen, `Timeline.Graph` hält den ganzen
      # Event-Referenz-Apparat — aber aus der Extraktion konnte das Feld NIE
      # entstehen. Gemessen an echten Daten: "session" und "event:…" kamen
      # null Mal vor.
      utts = [%{id: "u1", text: "egal", discord_id: "d", timestamp: nil}]

      roh =
        Jason.encode!(%{
          "facts" => [
            %{
              "claim" => "Etwas geschieht",
              "source_refs" => ["u1"],
              "time_anchor" => "session"
            }
          ]
        })

      {:ok, [fakt]} = Parsing.parse_facts_json(roh, utts)
      assert fakt["time_anchor"] == "session"
    end

    test "Ankertypen werden geprüft statt durchgereicht (Ereignis-Form seit #1109 verworfen)", %{
      cal: _
    } do
      utts = [%{id: "u1", text: "egal", discord_id: "d", timestamp: nil}]

      pruefe = fn wert ->
        roh =
          Jason.encode!(%{
            "facts" => [
              %{"claim" => "X", "source_refs" => ["u1"], "time_anchor" => wert}
            ]
          })

        {:ok, [f]} = Parsing.parse_facts_json(roh, utts)
        f["time_anchor"]
      end

      assert pruefe.("absolute") == "absolute"
      assert pruefe.("session") == "session"

      # Issue #1109: die Ereignis-Form wird nicht mehr durchgereicht. Sie kam
      # mit #1068 in die Whitelist, weil der Resolver sie kennt — der Matcher
      # dahinter sucht das Stichwort aber als Teilstring in fremden Claims,
      # ohne Wortgrenzen und ohne Negativliste. Solange das so ist, darf die
      # Extraktion kein Produzent dafür sein (Begründung am Riegel in
      # `normalize_anchor/1`).
      assert pruefe.("event:der Turmbrand") == nil

      # Modell-Garbage wird nil, nicht durchgereicht.
      assert pruefe.("irgendwas") == nil
      assert pruefe.("event:") == nil
      assert pruefe.(42) == nil
    end
  end

  describe "Fantasy-Kalender" do
    test "Saisons und Drittel rechnen anteilig, nicht gregorianisch", %{cal: _} do
      # Acht Monate à 40 Tage — die Viertelung muss sich anpassen, sonst zeigt
      # „Herbst" auf einen Monat, den es nicht gibt.
      cal = %Calendar{
        months: for(i <- 1..8, do: %{name: "Mond #{i}", days: 40}),
        epoch_label: "n.d.Z."
      }

      i = intervall(cal, "Herbst 1000")
      assert i.typ == :date
      {von, bis} = {Calendar.from_day(cal, i.von), Calendar.from_day(cal, i.bis)}
      assert {1000, 7, 1} = von
      assert {1000, 8, 40} = bis
    end
  end
end
