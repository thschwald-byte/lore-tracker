defmodule Worker.Timeline.LinieTest do
  @moduledoc """
  #1247 (Z1): die Linie rechnet aus Ankern — pur, ohne Mnesia und ohne Modell.

  Geprüft wird das, was die Linie **zusagt**, und ausdrücklich auch das, was
  sie NICHT tut: kein Mittelwert, kein gebautes Konstrukt, keine erfundene
  Zeit, wo kein Anker in Reichweite ist.
  """
  use ExUnit.Case, async: true

  alias Worker.Timeline.{Ausdruck, Calendar, Linie}

  defp cal, do: Calendar.default()

  # Drei Sitzungen à drei Äußerungen, in Erzählreihenfolge.
  defp stellen do
    for s <- 1..3, p <- 1..3 do
      %{utterance_id: "u#{s}#{p}", session_nr: s, pos: p}
    end
  end

  defp anker(art, ids, extra \\ %{}) do
    Map.merge(%{art: art, utterance_ids: ids, anker_id: "z_#{Enum.join(ids, "_")}"}, extra)
  end

  describe "anker_id/3 — die Adresse" do
    test "dieselbe Aussage an derselben Stelle ergibt dieselbe Adresse" do
      a = Linie.anker_id(["u2", "u1"], :zeitpunkt, "kurz nach zwölf")
      b = Linie.anker_id(["u1", "u2"], :zeitpunkt, "Kurz nach   zwölf")

      # Reihenfolge, Gross-/Kleinschreibung und Leerraum dürfen keine zweite
      # Adresse für dieselbe Aussage erzeugen — sonst konvergieren zwei
      # Worker nicht.
      assert a == b
      assert String.starts_with?(a, "z_")
    end

    test "zwei Anker an DERSELBEN Utterance kollidieren nicht" do
      # Der reale Fall (seattleV5 S3, Block 1106, eine einzige Utterance):
      # „also ist jetzt so grob eine Stunde vergangen, dann wird es jetzt so
      # kurz nach zwölf sein" — eine Spanne und ein Zeitpunkt in einem Satz.
      # Über die Utterance-Menge allein hätten beide dieselbe Adresse, und der
      # zweite hätte den ersten über LWW stumm überschrieben.
      spanne = Linie.anker_id(["u1106"], :spanne, "eine Stunde")
      punkt = Linie.anker_id(["u1106"], :zeitpunkt, "kurz nach zwölf")

      assert spanne != punkt
    end

    test "gleiche Art, anderer Wert — ebenfalls verschieden" do
      refute Linie.anker_id(["u1"], :spanne, "eine Stunde") ==
               Linie.anker_id(["u1"], :spanne, "zwei Stunden")
    end

    test "art als Atom und als String ergeben dieselbe Adresse" do
      assert Linie.anker_id(["u1"], :spanne, "x") == Linie.anker_id(["u1"], "spanne", "x")
    end
  end

  describe "Grundordnung" do
    test "ohne Anker steht alles in Erzählreihenfolge, und niemand bekommt eine Zeit" do
      linie = Linie.bauen(stellen(), [])

      assert Enum.map(linie.reihe, & &1.utterance_id) == [
               "u11",
               "u12",
               "u13",
               "u21",
               "u22",
               "u23",
               "u31",
               "u32",
               "u33"
             ]

      # Kein Anker heisst keine Zeit — nicht Minute 0.
      assert Enum.all?(linie.reihe, &(&1.minute == nil))
      assert Enum.all?(linie.reihe, &(&1.herkunft == :ohne))
    end

    test "eine Sitzung ohne Nummer sortiert ans Ende statt irgendwohin" do
      ohne = [%{utterance_id: "x1", session_nr: nil, pos: 1}]
      linie = Linie.bauen(stellen() ++ ohne, [])

      assert List.last(linie.reihe).utterance_id == "x1"
    end
  end

  describe "Zeitpunkte und Interpolation" do
    test "zwischen zwei Ankern wird interpoliert, ausserhalb zurückgeschrieben" do
      a = [
        anker(:zeitpunkt, ["u12"], %{minute: 1000}),
        anker(:zeitpunkt, ["u22"], %{minute: 1400})
      ]

      linie = Linie.bauen(stellen(), a)
      nach = linie.nach_utterance

      assert nach["u12"].minute == 1000
      assert nach["u12"].herkunft == :belegt
      assert nach["u22"].minute == 1400

      # Dazwischen: interpoliert, monoton, innerhalb der Grenzen.
      for id <- ["u13", "u21"] do
        assert nach[id].herkunft == :interpoliert
        assert nach[id].minute > 1000 and nach[id].minute < 1400
      end

      assert nach["u13"].minute <= nach["u21"].minute

      # VOR dem ersten Anker wird zurückgeschrieben, wenn keine Spanne
      # dazwischen liegt: Bekannt ist nur „vorher", und die Herkunft sagt es.
      # Mit Spannen dazwischen wird gerechnet (s. „rückwärts rechnen").
      assert nach["u11"].minute == 1000
      assert nach["u11"].herkunft == :fortgeschrieben

      # NACH dem letzten Anker wird fortgeschrieben — die Rechnung ist
      # transient, und ein grober Wert trägt mehr als ein Strich. Aber sie
      # heisst anders: `:fortgeschrieben` hat keinen Beleg nach oben und wird
      # mit dem Abstand beliebig. Wer sie liest, sieht das.
      assert nach["u33"].minute == 1400
      assert nach["u33"].herkunft == :fortgeschrieben
    end

    test "ein Zeitpunkt gilt an der frühesten Stelle seiner Menge" do
      a = [anker(:zeitpunkt, ["u21", "u22", "u23"], %{minute: 500})]
      nach = Linie.bauen(stellen(), a).nach_utterance

      assert nach["u21"].minute == 500
      assert nach["u21"].herkunft == :belegt

      # Die übrigen der Menge liegen danach — ohne zweiten Anker
      # fortgeschrieben, also als Anhalt und nicht als Messung.
      assert nach["u22"].minute == 500
      assert nach["u22"].herkunft == :fortgeschrieben
    end
  end

  describe "hinter dem letzten Anker endet die Zeit" do
    test "ohne Spanne ist die Strecke danach FORTGESCHRIEBEN, nicht gerechnet" do
      # Der erste Wurf schrieb die Zeit des letzten Ankers fort. An einer
      # echten Sitzung standen die einzigen Anker in den ersten hundert
      # Zeilen — danach bekamen 2000 Zeilen dasselbe Jahr, ohne jede Stütze
      # (#1092-Klasse). Was bekannt ist, ist die REIHENFOLGE, und die trägt
      # die Reihe selbst.
      linie =
        Linie.bauen(stellen(), [anker(:zeitpunkt, ["u11"], %{tagesminute: 22 * 60})])

      assert linie.nach_utterance["u11"].minute == 22 * 60
      assert linie.nach_utterance["u11"].herkunft == :belegt

      # Die Zahl bleibt — der Grad sagt, was sie wert ist.
      for id <- ~w(u12 u13 u21 u33) do
        assert linie.nach_utterance[id].minute == 22 * 60, id
        assert linie.nach_utterance[id].herkunft == :fortgeschrieben, id
      end
    end

    test "eine Spanne trägt über den letzten Anker hinaus — sie wurde gesagt" do
      linie =
        Linie.bauen(stellen(), [
          anker(:zeitpunkt, ["u11"], %{tagesminute: 22 * 60}),
          anker(:spanne, ["u13"], %{minuten: 30})
        ])

      assert linie.nach_utterance["u13"].minute == 22 * 60 + 30
      assert linie.nach_utterance["u13"].herkunft == :interpoliert

      # Zwischen Anker und Spanne ist die Strecke GEMESSEN.
      assert linie.nach_utterance["u12"].herkunft == :interpoliert

      # Dahinter endet das Gesagte — die Zahl läuft weiter, der Grad sinkt.
      assert linie.nach_utterance["u21"].minute == 22 * 60 + 30
      assert linie.nach_utterance["u21"].herkunft == :fortgeschrieben
    end

    test "ohne jeden Anker gibt es keine Zeit — da ist nichts fortzuschreiben" do
      linie = Linie.bauen(stellen(), [])

      assert length(linie.reihe) == length(stellen())
      assert Enum.all?(linie.reihe, &(&1.minute == nil))
      assert Enum.map(linie.reihe, & &1.utterance_id) == Enum.map(stellen(), & &1.utterance_id)
    end
  end

  describe "Spannen" do
    test "eine genannte Dauer schiebt die Zeit weiter, statt im Tag zu verschwinden" do
      a = [
        anker(:zeitpunkt, ["u11"], %{minute: 600}),
        anker(:spanne, ["u12", "u13"], %{minuten: 120})
      ]

      nach = Linie.bauen(stellen(), a).nach_utterance

      # Die Spanne gilt ab der SPÄTESTEN Stelle ihrer Menge (u13): gesagt wird
      # „wir sind zwei Stunden marschiert", wenn der Marsch vorbei ist.
      assert nach["u12"].minute == 600
      assert nach["u13"].minute == 720

      # Hinter der Spanne läuft die Zahl weiter, aber als Anhalt: Die zwei
      # Stunden sind gesagt worden, alles danach nicht.
      assert nach["u21"].minute == 720
      assert nach["u21"].herkunft == :fortgeschrieben
    end

    test "zwei Stunden sind auf einem Tageszähler nicht darstellbar — hier schon" do
      a = [
        anker(:zeitpunkt, ["u11"], %{minute: 0}),
        anker(:spanne, ["u12"], %{minuten: 120})
      ]

      nach = Linie.bauen(stellen(), a).nach_utterance

      assert nach["u12"].minute == 120
      # Derselbe Tag, aber die Zeit ist vergangen.
      assert Linie.tag(nach["u12"]) == 0
    end

    test "genug Spannen ergeben einen Tageswechsel" do
      a =
        [anker(:zeitpunkt, ["u11"], %{minute: 0})] ++
          for id <- ["u12", "u13", "u21", "u22", "u23"] do
            anker(:spanne, [id], %{minuten: 300})
          end

      nach = Linie.bauen(stellen(), a).nach_utterance

      assert nach["u23"].minute == 1500
      assert Linie.tag(nach["u23"]) == 1
    end
  end

  describe "Verschiebung gegen die Erzählreihenfolge" do
    test "ein Rückblick wandert nach vorn" do
      a = [anker(:ordnung, ["u31"], %{ziel: "u12", richtung: :vor})]
      linie = Linie.bauen(stellen(), a)

      reihe = Enum.map(linie.reihe, & &1.utterance_id)
      assert Enum.find_index(reihe, &(&1 == "u31")) < Enum.find_index(reihe, &(&1 == "u12"))
      assert length(reihe) == 9
    end

    test "eine Verschiebung ohne auflösbares Ziel bleibt wirkungslos UND wird gemeldet" do
      a = [anker(:ordnung, ["u31"], %{ziel: "gibt-es-nicht", richtung: :vor})]
      linie = Linie.bauen(stellen(), a)

      assert Enum.map(linie.reihe, & &1.utterance_id) |> List.last() == "u33"
      assert Enum.any?(linie.befunde, &(&1.art == :verschiebung_ohne_ziel))
    end
  end

  describe "aus der Kette gelöst" do
    test "Gelöstes liegt nicht auf der Linie und wird nie interpoliert" do
      a = [
        anker(:geloest, ["u22"], %{}),
        anker(:zeitpunkt, ["u11"], %{minute: 100})
      ]

      linie = Linie.bauen(stellen(), a)

      refute Enum.any?(linie.reihe, &(&1.utterance_id == "u22"))
      assert MapSet.member?(linie.geloest, "u22")
      assert Linie.anker_fuer(linie, ["u22"]) == []
    end
  end

  describe "anker_fuer/2 — die transiente Methode" do
    test "liefert eine LISTE, auch wenn die Einträge verschieden sind" do
      a = [
        anker(:zeitpunkt, ["u11"], %{minute: 100}),
        anker(:zeitpunkt, ["u31"], %{minute: 900})
      ]

      linie = Linie.bauen(stellen(), a)
      liste = Linie.anker_fuer(linie, ["u11", "u31"])

      assert length(liste) == 2
      assert Enum.map(liste, & &1.minute) == [100, 900]

      # Kein Mittelwert, keine gebaute Spanne: die Liste IST die Antwort.
      refute Enum.any?(liste, &Map.has_key?(&1, :von))
    end

    test "MEHRERE Anker an EINER Äußerung kommen alle" do
      # Der reale Fall (seattleV5 S3, Block 1106, eine Utterance): „also ist
      # jetzt so grob eine Stunde vergangen, dann wird es jetzt so kurz nach
      # zwölf sein" — eine Spanne und ein Zeitpunkt in einem Satz.
      a = [
        anker(:zeitpunkt, ["u11"], %{minute: 600}),
        anker(:spanne, ["u12"], %{minuten: 60, wert: "eine Stunde"}),
        Map.put(
          anker(:zeitpunkt, ["u12"], %{minute: 660, wert: "kurz nach zwölf"}),
          :anker_id,
          "z_punkt_u12"
        )
      ]

      linie = Linie.bauen(stellen(), a)
      liste = Linie.anker_fuer(linie, ["u12"])

      assert length(liste) == 2, "beide Anker derselben Äußerung müssen kommen"
      assert Enum.sort(Enum.map(liste, & &1.art)) == [:spanne, :zeitpunkt]
      assert Enum.any?(liste, &(&1.wert == "eine Stunde"))
      assert Enum.any?(liste, &(&1.wert == "kurz nach zwölf"))
    end

    test "eine Äußerung ohne eigenen Anker liefert genau einen Eintrag" do
      # Zwischen zwei Ankern trägt er die gerechnete Zeit; hinter dem letzten
      # steht er ohne — und das ist eine Aussage, kein Fehler.
      a = [
        anker(:zeitpunkt, ["u11"], %{minute: 100}),
        anker(:zeitpunkt, ["u21"], %{minute: 400})
      ]

      linie = Linie.bauen(stellen(), a)

      assert [%{herkunft: :interpoliert, minute: m}] = Linie.anker_fuer(linie, ["u13"])
      assert m > 100 and m < 400

      # Hinter dem letzten Anker trägt der Eintrag seinen Grad mit — genau
      # dafür ist die Herkunft da: Wer daraus etwas rechnet, sieht, worauf.
      assert [%{herkunft: :fortgeschrieben, minute: 400}] = Linie.anker_fuer(linie, ["u33"])
    end

    test "unbekannte Utterances erzeugen keinen Eintrag statt eines leeren" do
      linie = Linie.bauen(stellen(), [])
      assert Linie.anker_fuer(linie, ["fremd"]) == []
    end

    test "Doppelte zählen einmal" do
      a = [anker(:zeitpunkt, ["u11"], %{minute: 100})]
      linie = Linie.bauen(stellen(), a)

      assert length(Linie.anker_fuer(linie, ["u11", "u11"])) == 1
    end
  end

  describe "Uhrzeiten bekommen ihren Tag aus der Reihe" do
    test "ohne Datum beginnt die Linie auf Tag 0 — die Abstände stimmen trotzdem" do
      linie =
        Linie.bauen(stellen(), [
          anker(:zeitpunkt, ["u11"], %{tagesminute: 22 * 60}),
          anker(:zeitpunkt, ["u13"], %{tagesminute: 23 * 60})
        ])

      assert linie.nach_utterance["u11"].minute == 22 * 60
      assert linie.nach_utterance["u13"].minute == 23 * 60
      assert linie.nach_utterance["u12"].herkunft == :interpoliert
    end

    test "eine Uhrzeit erbt den Tag des Datums davor" do
      tag = 734_372

      linie =
        Linie.bauen(stellen(), [
          anker(:zeitpunkt, ["u11"], %{minute: tag * 1440}),
          anker(:zeitpunkt, ["u13"], %{tagesminute: 22 * 60 + 45})
        ])

      assert linie.nach_utterance["u13"].minute == tag * 1440 + 22 * 60 + 45
      assert Linie.tag(linie.nach_utterance["u13"]) == tag
    end

    test "Datum und Uhrzeit an DERSELBEN Stelle ergänzen sich" do
      # „Am 15. November, so gegen 22:45" — zwei Anker an einer Äusserung.
      # Ohne die Genauigkeitsstufe gewänne das Datum nach der Minutenregel
      # (Mitternacht ist früher), und die einzige wirklich gesagte Uhrzeit
      # fiele aus der Rechnung.
      tag = 734_372

      linie =
        Linie.bauen(stellen(), [
          anker(:zeitpunkt, ["u11"], %{minute: tag * 1440, anker_id: "z_datum"}),
          anker(:zeitpunkt, ["u11"], %{tagesminute: 22 * 60 + 45, anker_id: "z_uhr"})
        ])

      eintrag = linie.nach_utterance["u11"]
      assert eintrag.minute == tag * 1440 + 22 * 60 + 45
      assert eintrag.anker_id == "z_uhr"
    end

    test "eine zurückspringende Uhrzeit ist Mitternacht, kein Sprung rückwärts" do
      # 23:40 → 00:20 geht eine halbe Stunde vorwärts, nicht 23 Stunden
      # zurück.
      linie =
        Linie.bauen(stellen(), [
          anker(:zeitpunkt, ["u11"], %{tagesminute: 23 * 60 + 40}),
          anker(:zeitpunkt, ["u13"], %{tagesminute: 20})
        ])

      a = linie.nach_utterance["u11"].minute
      b = linie.nach_utterance["u13"].minute

      assert b > a
      assert b - a == 40
    end

    test "eine abgesegnete Uhrzeit schlägt eine gerechnete an derselben Stelle" do
      linie =
        Linie.bauen(stellen(), [
          anker(:zeitpunkt, ["u11"], %{tagesminute: 4 * 60 + 11, anker_id: "z_jack"}),
          anker(:zeitpunkt, ["u11"], %{
            tagesminute: 22 * 60 + 45,
            anker_id: "z_mensch",
            abgesegnet_am: "2026-09-19"
          })
        ])

      # Der Fall aus dem Ticket: die Spracherkennung verstand „4:11", gesagt
      # war „22:45". Nach reiner Minutenwahl gewönne die Verstümmelung.
      assert linie.nach_utterance["u11"].anker_id == "z_mensch"
    end

    test "zwei widersprechende Uhrzeiten an einer Stelle sind ein Befund" do
      # Nur auf `:minute` zu prüfen liesse den häufigsten Fall am Spieltisch
      # still durchgehen.
      linie =
        Linie.bauen(stellen(), [
          anker(:zeitpunkt, ["u11"], %{tagesminute: 4 * 60 + 11, anker_id: "z_a"}),
          anker(:zeitpunkt, ["u11"], %{tagesminute: 22 * 60 + 45, anker_id: "z_b"})
        ])

      assert Enum.any?(linie.befunde, &(&1.art == :zeitpunkte_uneinig))
    end
  end

  describe "Wortform-Uhrzeiten: die KETTE entscheidet den Halbtag" do
    # Die drei echten Anker der Referenzsitzung S3, in ihrer Reihenfolge:
    # „Drei viertel elf" (10:45/22:45) → „kurz nach zwölf" (00:05/12:05) →
    # „kurz vor zwei" (01:50/13:50).
    defp s3_kette do
      [
        anker(:zeitpunkt, ["u11"], %{halbtag_minute: 10 * 60 + 45, anker_id: "z_1"}),
        anker(:zeitpunkt, ["u12"], %{halbtag_minute: 5, anker_id: "z_2"}),
        anker(:zeitpunkt, ["u13"], %{halbtag_minute: 60 + 50, anker_id: "z_3"})
      ]
    end

    test "die Abstände stimmen — unabhängig davon, welcher Halbtag gemeint war" do
      # Das ist der Kern: 22:45 → 00:05 → 01:50 und 10:45 → 12:05 → 13:50
      # haben IDENTISCHE Abstände, und die Linie braucht die Abstände. Läge
      # die Wahl beim Modell und es entschiede falsch, spannte die Sitzung
      # fünfzehn Stunden statt drei (Befund dave, 19.09.2026).
      linie = Linie.bauen(stellen(), s3_kette())

      [a, b, c] = for id <- ~w(u11 u12 u13), do: linie.nach_utterance[id].minute

      assert b - a == 80, "drei viertel elf → kurz nach zwölf sind 1h20"
      assert c - b == 105, "kurz nach zwölf → kurz vor zwei sind 1h45"
      assert c - a == 185, "die ganze Kette spannt 3h05, nicht 15 Stunden"
    end

    test "kein Anker springt rückwärts" do
      linie = Linie.bauen(stellen(), s3_kette())
      minuten = for id <- ~w(u11 u12 u13), do: linie.nach_utterance[id].minute

      assert minuten == Enum.sort(minuten)
    end

    test "ein Datum davor gibt der ganzen Kette ihren Tag" do
      tag = 734_372

      linie =
        Linie.bauen(
          stellen(),
          [anker(:zeitpunkt, ["u11"], %{minute: tag * 1440, anker_id: "z_datum"})] ++
            [
              # „Drei viertel elf" im 12-Stunden-Raum: 10:45 ODER 22:45.
              anker(:zeitpunkt, ["u12"], %{halbtag_minute: 10 * 60 + 45, anker_id: "z_a"}),
              anker(:zeitpunkt, ["u13"], %{halbtag_minute: 5, anker_id: "z_b"})
            ]
        )

      # Das Datum steht auf Mitternacht, die Wortform läuft vorwärts: 10:45.
      assert linie.nach_utterance["u12"].minute == tag * 1440 + 10 * 60 + 45
      assert Linie.tag(linie.nach_utterance["u12"]) == tag

      # 10:45 → „kurz nach zwölf": vorwärts auf 12:05, NICHT zurück auf 00:05.
      assert linie.nach_utterance["u13"].minute == tag * 1440 + 12 * 60 + 5
      assert Linie.tag(linie.nach_utterance["u13"]) == tag
    end

    test "die gewöhnliche Kette meldet keinen Sprung" do
      linie = Linie.bauen(stellen(), s3_kette())

      refute Enum.any?(linie.befunde, &(&1.art == :zeitsprung_angenommen))
    end
  end

  describe "die Abend-Kette aus S4 — der Zweig OHNE Mitternacht" do
    # Vier Glieder aus einer Sitzung (dave, vollständige Referenzliste):
    #
    #   [ 896] „kommt ihr kurz vor 19 Uhr dort an"        → 18:50
    #   [ 898] „Also um 19 Uhr Beginn"                     → 19:00
    #   [1007] „Dreiviertelstunde, Stunde … endet das Ganze"  → Spanne
    #   [1203] „Drei Viertel neun … also 20:45 Uhr"        → 20:45
    #
    # Zusammen mit der Nacht-Kette aus S3 (22:45 → 00:05 → 01:50) prüfen die
    # beiden Ketten beide Zweige der Verankerung: mit und ohne Tageswechsel.
    test "zwei Anker, eine Spanne dazwischen, ein Endanker — monoton und ohne Befund" do
      linie =
        Linie.bauen(stellen(), [
          anker(:zeitpunkt, ["u11"], %{tagesminute: 18 * 60 + 50, anker_id: "z_ankunft"}),
          anker(:zeitpunkt, ["u12"], %{tagesminute: 19 * 60, anker_id: "z_beginn"}),
          anker(:spanne, ["u13"], %{minuten: 60, anker_id: "z_dauer"}),
          anker(:zeitpunkt, ["u21"], %{tagesminute: 20 * 60 + 45, anker_id: "z_ende"})
        ])

      minuten = for id <- ~w(u11 u12 u21), do: linie.nach_utterance[id].minute

      assert minuten == [18 * 60 + 50, 19 * 60, 20 * 60 + 45]
      assert minuten == Enum.sort(minuten)

      # Die Stunde Veranstaltung passt in die 105 Minuten zwischen Beginn und
      # Ende — kein Überlauf, kein angenommener Sprung.
      refute Enum.any?(linie.befunde, &(&1.art == :zeitsprung_angenommen))
      refute Enum.any?(linie.befunde, &(&1.art == :spannen_ueberlauf))
    end

    test "Ankunft und Beginn bleiben getrennte Punkte" do
      # Ohne den Modifikator vor der Ziffer fielen beide auf 19:00, und die
      # Anfahrt verschwände (dave, 19.09.2026).
      linie =
        Linie.bauen(stellen(), [
          anker(:zeitpunkt, ["u11"], %{
            tagesminute: Worker.Timeline.Ausdruck.tagesminute("kurz vor 19 Uhr"),
            anker_id: "z_ankunft"
          }),
          anker(:zeitpunkt, ["u12"], %{
            tagesminute: Worker.Timeline.Ausdruck.tagesminute("um 19 Uhr Beginn"),
            anker_id: "z_beginn"
          })
        ])

      a = linie.nach_utterance["u11"].minute
      b = linie.nach_utterance["u12"].minute

      assert b - a == 10
    end
  end

  describe "der grosse Vorwärtssprung ist ein Befund" do
    test "eine feste Uhrzeit, die zurückspringt, wird gemeldet" do
      # Der Fall dahinter ist der ÜBERSEHENE Rückblick (bob, 19.09.2026): Hat
      # Jack ihn nicht verschoben, steht seine Uhrzeit an der Erzählstelle,
      # springt zurück, und die Rechnung schiebt sie über Mitternacht — und
      # weil der Vorlauf fortgeschrieben wird, erbt der ganze REST der Sitzung
      # die Verschiebung.
      linie =
        Linie.bauen(stellen(), [
          anker(:zeitpunkt, ["u11"], %{tagesminute: 22 * 60, anker_id: "z_spaet"}),
          anker(:zeitpunkt, ["u13"], %{tagesminute: 9 * 60, anker_id: "z_frueh"})
        ])

      befund = Enum.find(linie.befunde, &(&1.art == :zeitsprung_angenommen))

      assert befund, "ein erfundener Sprung muss sichtbar sein"
      assert befund.anker_id == "z_frueh"
      assert befund.text =~ "Rückblick"
    end

    test "eine WORTFORM mit demselben Sprung wird genauso gemeldet" do
      # Die Asymmetrie des ersten Entwurfs: Er mass den Tageswechsel, den nur
      # die feste Form erzeugt. Die Wortform springt formal bloss in den
      # anderen Halbtag — kommt aber auf denselben Zeitpunkt, aus derselben
      # Ursache, und ist nach daves Zählung die HÄUFIGERE Form. Der Befund
      # hätte vorwiegend im selteneren Fall gegriffen.
      fest =
        Linie.bauen(stellen(), [
          anker(:zeitpunkt, ["u11"], %{tagesminute: 22 * 60 + 45, anker_id: "z_a"}),
          anker(:zeitpunkt, ["u13"], %{tagesminute: 9 * 60 + 30, anker_id: "z_b"})
        ])

      wort =
        Linie.bauen(stellen(), [
          anker(:zeitpunkt, ["u11"], %{halbtag_minute: 10 * 60 + 45, anker_id: "z_a"}),
          anker(:zeitpunkt, ["u13"], %{halbtag_minute: 9 * 60 + 30, anker_id: "z_b"})
        ])

      # Beide springen um 10¾ Stunden vorwärts — beide werden gemeldet.
      for linie <- [fest, wort] do
        assert Enum.any?(linie.befunde, &(&1.art == :zeitsprung_angenommen))
      end
    end

    test "eine aufsteigende Folge meldet nichts" do
      linie =
        Linie.bauen(stellen(), [
          anker(:zeitpunkt, ["u11"], %{tagesminute: 9 * 60}),
          anker(:zeitpunkt, ["u13"], %{tagesminute: 13 * 60})
        ])

      refute Enum.any?(linie.befunde, &(&1.art == :zeitsprung_angenommen))
    end
  end

  describe "Verfeinerung ist kein Widerspruch" do
    test "eine Uhrzeit füllt das abgesegnete Datum aus, statt ihm zu weichen" do
      # Das Sitzungsdatum kommt vom GM und ist abgesegnet; die Uhrzeit kommt
      # von Jack. Stünde die Absegnung vor der Genauigkeit, gewänne
      # Mitternacht — und die einzige wirklich gesagte Uhrzeit fiele genau in
      # dem Fall aus der Rechnung, für den die Stufe eingezogen wurde (bob,
      # 19.09.2026).
      tag = 734_372

      linie =
        Linie.bauen(stellen(), [
          anker(:zeitpunkt, ["u11"], %{
            minute: tag * 1440,
            anker_id: "z_gm",
            abgesegnet_am: "2026-09-19"
          }),
          anker(:zeitpunkt, ["u11"], %{tagesminute: 22 * 60 + 45, anker_id: "z_jack"})
        ])

      eintrag = linie.nach_utterance["u11"]
      assert eintrag.minute == tag * 1440 + 22 * 60 + 45
      assert eintrag.anker_id == "z_jack"
    end

    test "an einem ANDEREN Tag ist es ein Widerspruch — die Kuration gewinnt" do
      tag = 734_372

      linie =
        Linie.bauen(stellen(), [
          anker(:zeitpunkt, ["u11"], %{
            minute: tag * 1440,
            anker_id: "z_gm",
            abgesegnet_am: "2026-09-19"
          }),
          # Ein anderes DATUM, keine Verfeinerung: beide sind grob, die
          # Absegnung entscheidet.
          anker(:zeitpunkt, ["u11"], %{minute: (tag + 3) * 1440, anker_id: "z_jack"})
        ])

      assert linie.nach_utterance["u11"].anker_id == "z_gm"
    end
  end

  describe "einen Tag vererbt nur, wer tagesgenau ist" do
    # Der Fall (Maintainer, 19.09.2026): Die Spielleitung erzählt
    # Vergangenheit — „seit dem Beben 2044", „vor zwei Jahren in Namibia" —,
    # und gleich danach fällt eine Uhrzeit der Gegenwart. Die nahm bis dahin
    # den Tag des letzten festen Punktes, und das war die Jahreszahl: Die
    # Sitzung spielte plötzlich am 1. Januar 2044.
    test "eine Jahreszahl datiert die folgende Uhrzeit NICHT" do
      jahr =
        Ausdruck.aufloesen(
          %{art: :zeitpunkt, utterance_ids: ["u11"], wert: "im Jahr 2044"},
          cal()
        )

      uhr =
        Ausdruck.aufloesen(
          %{art: :zeitpunkt, utterance_ids: ["u13"], wert: "kurz nach acht"},
          cal()
        )

      nach = Linie.bauen(stellen(), [jahr, uhr]).nach_utterance

      # Die Jahreszahl steht mit ihrem Datum da.
      assert Linie.tag(nach["u11"]) > 700_000

      # Die Uhrzeit bleibt relativ — acht Uhr an einem unbekannten Tag.
      assert nach["u13"].minute < 1440
      assert nach["u13"].herkunft == :belegt
    end

    test "ein TAGESgenaues Datum vererbt seinen Tag sehr wohl" do
      datum =
        Ausdruck.aufloesen(%{art: :zeitpunkt, utterance_ids: ["u11"], wert: "15.11.2080"}, cal())

      uhr = Ausdruck.aufloesen(%{art: :zeitpunkt, utterance_ids: ["u13"], wert: "22:45"}, cal())

      nach = Linie.bauen(stellen(), [datum, uhr]).nach_utterance

      assert Linie.tag(nach["u13"]) == Linie.tag(nach["u11"])
      assert nach["u13"].minute == Linie.tag(nach["u11"]) * 1440 + 22 * 60 + 45
    end
  end

  describe "rückwärts rechnen und der Tageswechsel" do
    # Maintainer-Szenario, 19.09.2026: „gut, dass heute Montag ist" … „die
    # Nacht vergeht" … „ihr müsst 3 Tage warten" … „Schlagzeile am
    # 12.12.2024" — daraus weiss man, an welchem Tag der Montag war. Das
    # Datum fällt am ENDE, und am Tisch ist das der Normalfall.
    test "ein Anker am Ende datiert über Spannen zurück" do
      anker = [
        anker(:spanne, ["u12"], %{minuten: 3 * 1440}),
        anker(:zeitpunkt, ["u21"], %{minute: 739_105 * 1440})
      ]

      nach = Linie.bauen(stellen(), anker).nach_utterance

      assert Linie.tag(nach["u21"]) == 739_105
      assert Linie.tag(nach["u11"]) == 739_105 - 3, "drei Tage vor dem Beleg"
      assert nach["u11"].herkunft == :interpoliert
    end

    test "ohne Spanne dazwischen wird nichts gerechnet, nur zurückgeschrieben" do
      nach =
        Linie.bauen(stellen(), [anker(:zeitpunkt, ["u21"], %{minute: 739_105 * 1440})]).nach_utterance

      assert nach["u11"].minute == 739_105 * 1440
      assert nach["u11"].herkunft == :fortgeschrieben, "kein Mass, also kein Rechnen"
    end

    test "der Tageswechsel springt auf den Morgen danach, nicht um N Stunden" do
      # „Es vergeht eine Nacht" sagt nicht, wie lange — es sagt, dass ein
      # neuer Tag begann. Ob ein Satz das meint, entscheidet Jack; die Linie
      # rechnet es nur (`morgen_stunde`).
      anker = [
        anker(:zeitpunkt, ["u11"], %{minute: 100 * 1440 + 22 * 60}),
        anker(:spanne, ["u12"], %{morgen_stunde: 7})
      ]

      nach = Linie.bauen(stellen(), anker).nach_utterance

      assert nach["u12"].minute == 101 * 1440 + 7 * 60, "22 Uhr + eine Nacht = 7 Uhr am Folgetag"
    end

    test "zwei Nächte sind zwei Tage, egal wie spät es war" do
      anker = [
        anker(:zeitpunkt, ["u11"], %{minute: 100 * 1440 + 2 * 60}),
        anker(:spanne, ["u12"], %{morgen_stunde: 7}),
        anker(:spanne, ["u13"], %{morgen_stunde: 7})
      ]

      nach = Linie.bauen(stellen(), anker).nach_utterance

      assert Linie.tag(nach["u13"]) == 102, "zwei Uhr nachts, zwei Nächte, zwei Tage weiter"
    end
  end

  describe "Gewissheit und Auflösung sind zweierlei" do
    # Maintainer, 19.09.2026: „die gezeigten beispiele sind gewiss → 100%,
    # aber die unschärfe gilt für die fakten dazwischen". Der erste Wurf
    # verwechselte GROB mit UNSICHER: „Ende 2011" bekam 15 %, obwohl die
    # Aussage gewiss ist — sie ist nur vier Monate breit.
    test "ein belegter Anker ist 100 %, wie grob er auch ist" do
      grob =
        Ausdruck.aufloesen(%{art: :zeitpunkt, utterance_ids: ["u11"], wert: "Ende 2011"}, cal())

      fein = Ausdruck.aufloesen(%{art: :zeitpunkt, utterance_ids: ["u13"], wert: "22:45"}, cal())

      nach = Linie.bauen(stellen(), [grob, fein]).nach_utterance

      assert nach["u11"].gewissheit == 100
      assert nach["u13"].gewissheit == 100

      # Der Unterschied steht in der AUFLÖSUNG, nicht in der Gewissheit.
      assert nach["u11"].aufloesung > 100 * 1440, "Ende 2011 ist Monate breit"
      assert nach["u13"].aufloesung == 1, "eine Uhrzeit ist auf die Minute"
    end

    test "die Gewissheit gilt den Zeilen DAZWISCHEN und hängt am Abstand" do
      eng =
        Linie.bauen(stellen(), [
          anker(:zeitpunkt, ["u11"], %{minute: 1000}),
          anker(:zeitpunkt, ["u13"], %{minute: 1030})
        ])

      weit =
        Linie.bauen(stellen(), [
          anker(:zeitpunkt, ["u11"], %{minute: 1000}),
          anker(:zeitpunkt, ["u13"], %{minute: 1000 + 400 * 1440})
        ])

      assert eng.nach_utterance["u12"].gewissheit == 90, "eine halbe Stunde auseinander"
      assert weit.nach_utterance["u12"].gewissheit == 5, "über ein Jahr auseinander"
    end

    test "interpolierte Stellen haben keine Auflösung — sie sind nicht belegt" do
      nach =
        Linie.bauen(stellen(), [
          anker(:zeitpunkt, ["u11"], %{minute: 1000}),
          anker(:zeitpunkt, ["u13"], %{minute: 1030})
        ]).nach_utterance

      assert nach["u12"].aufloesung == nil
      assert nach["u21"].gewissheit == 0, "fortgeschrieben ist kein Beleg"
    end
  end

  describe "Befunde" do
    test "Spannen, die nicht zwischen zwei Anker passen, werden gemeldet statt gestaucht" do
      a = [
        anker(:zeitpunkt, ["u11"], %{minute: 0}),
        anker(:zeitpunkt, ["u13"], %{minute: 60}),
        anker(:spanne, ["u12"], %{minuten: 300})
      ]

      linie = Linie.bauen(stellen(), a)

      befund = Enum.find(linie.befunde, &(&1.art == :spannen_ueberlauf))
      assert befund, "der Widerspruch muss ein Befund sein"
      # **Der Befund nennt die Dauer in Worten, nicht in Rohminuten** (#1247,
      # 20.09.2026): „5.0 Stunden" statt „300". Am echten Lauf stand dort
      # „-1057331035 Minuten" — formal richtig, praktisch unlesbar.
      assert befund.text =~ "5.0 Stunden"
      assert befund.text =~ "1.0 Stunden"

      # Die Linie bleibt trotzdem benutzbar und monoton — best effort.
      nach = linie.nach_utterance
      assert nach["u12"].minute >= nach["u11"].minute
      assert nach["u12"].minute <= nach["u13"].minute
    end

    test "zwei widersprüchliche Zeitpunkte an derselben Stelle sind ein Befund" do
      a = [
        anker(:zeitpunkt, ["u11"], %{minute: 600}),
        Map.put(anker(:zeitpunkt, ["u11"], %{minute: 900}), :anker_id, "z_zweiter")
      ]

      linie = Linie.bauen(stellen(), a)

      befund = Enum.find(linie.befunde, &(&1.art == :zeitpunkte_uneinig))
      assert befund, "der Widerspruch darf nicht still nach Listenreihenfolge entschieden werden"

      # Gerechnet wird mit dem früheren — deterministisch, nicht nach
      # Zustellreihenfolge.
      assert linie.nach_utterance["u11"].minute == 600
    end

    test "zwei GLEICHE Zeitpunkte an derselben Stelle sind kein Befund" do
      a = [
        anker(:zeitpunkt, ["u11"], %{minute: 600}),
        Map.put(anker(:zeitpunkt, ["u11"], %{minute: 600}), :anker_id, "z_gleich")
      ]

      linie = Linie.bauen(stellen(), a)
      refute Enum.any?(linie.befunde, &(&1.art == :zeitpunkte_uneinig))
    end

    test "ein Zweifel reist als Befund UND steht an der Stelle" do
      a = [anker(:zeitpunkt, ["u11"], %{minute: 0, zweifel: "Tisch oder Welt unklar"})]
      linie = Linie.bauen(stellen(), a)

      assert Enum.any?(linie.befunde, &(&1.art == :zweifel and &1.text =~ "Tisch"))
      assert linie.nach_utterance["u11"].zweifel =~ "Tisch"
    end
  end

  describe "Absegnung" do
    test "der abgesegnete Zeitpunkt gewinnt gegen den FRÜHEREN maschinellen" do
      # Der Fall aus dem Ticket, und der Grund, warum die Auswahl zweistufig
      # ist: Die Spracherkennung verstand „4:11", gesagt war „22:45". Ein
      # Mensch segnet 22:45 ab, ein späterer Lauf trägt 4:11 ein.
      #
      # Beide haben VERSCHIEDENE Adressen (der Wert geht in die anker_id ein),
      # der Fold sieht sie also nie gegeneinander — entschieden wird hier. Nach
      # reiner Minutenwahl gewänne 4:11, weil es früher ist: die Verstümmelung
      # gegen die Festlegung, deterministisch.
      a = [
        Map.put(
          anker(:zeitpunkt, ["u11"], %{
            minute: 22 * 60 + 45,
            wert: "22:45",
            abgesegnet_am: "2026-09-19"
          }),
          :anker_id,
          "z_mensch"
        ),
        Map.put(
          anker(:zeitpunkt, ["u11"], %{minute: 4 * 60 + 11, wert: "4:11"}),
          :anker_id,
          "z_jack"
        )
      ]

      linie = Linie.bauen(stellen(), a)

      assert linie.nach_utterance["u11"].minute == 22 * 60 + 45,
             "die menschliche Festlegung muss gewinnen, auch gegen den früheren Wert"

      # Und der Widerspruch bleibt sichtbar — die Kuration ist eine
      # Entscheidung, kein Verschweigen.
      befund = Enum.find(linie.befunde, &(&1.art == :zeitpunkte_uneinig))
      assert befund
      assert befund.text =~ "abgesegnete"
    end

    test "zwei abgesegnete untereinander: wieder der frühere" do
      a = [
        Map.put(
          anker(:zeitpunkt, ["u11"], %{minute: 600, abgesegnet_am: "2026-09-18"}),
          :anker_id,
          "z_a"
        ),
        Map.put(
          anker(:zeitpunkt, ["u11"], %{minute: 900, abgesegnet_am: "2026-09-19"}),
          :anker_id,
          "z_b"
        )
      ]

      assert Linie.bauen(stellen(), a).nach_utterance["u11"].minute == 600
    end

    test "eine abgesegnete Stelle ist als solche erkennbar" do
      a = [
        anker(:zeitpunkt, ["u11"], %{minute: 0, abgesegnet_am: "2026-09-19T10:00:00Z"}),
        anker(:zeitpunkt, ["u31"], %{minute: 900})
      ]

      nach = Linie.bauen(stellen(), a).nach_utterance

      assert nach["u11"].abgesegnet?
      refute nach["u31"].abgesegnet?
    end
  end

  describe "Fremddaten" do
    test "eine unbekannte art wird ignoriert statt zu einem Atom zu werden" do
      # **Geprüft wird DIESES Atom, nicht die Grösse der Atom-Tabelle.**
      # Der erste Wurf zählte `:erlang.system_info(:atom_count)` vor und nach
      # dem Aufruf — eine VM-weite Zahl, während bis zu 64 Testprozesse
      # parallel laufen. Jeder fremde Test, der zufällig ein Atom anlegt,
      # zählte mit; der Test war rot, ohne dass am Code etwas falsch war
      # (gesehen am 20.09.2026, danach dreimal grün mit anderen Seeds).
      # Ein Wächter, der misst, was ihm nicht gehört, meldet Rauschen —
      # und wird nach dem zweiten Fehlalarm ignoriert.
      wort = "voellig-unbekannt-#{System.unique_integer([:positive])}"
      linie = Linie.bauen(stellen(), [anker(wort, ["u11"])])

      assert length(linie.reihe) == 9

      # Kein String.to_atom auf Fremddaten: das Atom gibt es danach nicht.
      assert_raise ArgumentError, fn -> String.to_existing_atom(wort) end
    end

    test "art als String verhält sich wie das Atom" do
      a = [anker("zeitpunkt", ["u11"], %{minute: 42})]
      assert Linie.bauen(stellen(), a).nach_utterance["u11"].minute == 42
    end
  end
end
