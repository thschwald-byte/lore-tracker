defmodule Worker.Timeline.LinieTest do
  @moduledoc """
  #1247 (Z1): die Linie rechnet aus Ankern — pur, ohne Mnesia und ohne Modell.

  Geprüft wird das, was die Linie **zusagt**, und ausdrücklich auch das, was
  sie NICHT tut: kein Mittelwert, kein gebautes Konstrukt, keine erfundene
  Zeit, wo kein Anker in Reichweite ist.
  """
  use ExUnit.Case, async: true

  alias Worker.Timeline.Linie

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
    test "zwischen zwei Ankern wird interpoliert, ausserhalb nicht rückwärts erfunden" do
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

      # VOR dem ersten Anker gibt es keine Zeit: rückwärts zu rechnen hiesse,
      # eine Zeit zu erfinden, für die nichts spricht.
      assert nach["u11"].minute == nil
      assert nach["u11"].herkunft == :ohne

      # Nach dem letzten Anker gilt er weiter (ohne Spanne vergeht nichts).
      assert nach["u33"].minute == 1400
      assert nach["u33"].herkunft == :interpoliert
    end

    test "ein Zeitpunkt gilt an der frühesten Stelle seiner Menge" do
      a = [anker(:zeitpunkt, ["u21", "u22", "u23"], %{minute: 500})]
      nach = Linie.bauen(stellen(), a).nach_utterance

      assert nach["u21"].minute == 500
      assert nach["u21"].herkunft == :belegt
      # Die übrigen der Menge liegen danach, nicht gleichauf.
      assert nach["u22"].herkunft == :interpoliert
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
      assert nach["u21"].minute == 720
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

    test "eine Äußerung ohne eigenen Anker liefert genau einen Eintrag mit gerechneter Zeit" do
      a = [anker(:zeitpunkt, ["u11"], %{minute: 100})]
      linie = Linie.bauen(stellen(), a)

      assert [%{herkunft: :interpoliert, minute: 100}] = Linie.anker_fuer(linie, ["u13"])
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
      assert befund.text =~ "300"
      assert befund.text =~ "60"

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
          anker(:zeitpunkt, ["u11"], %{minute: 22 * 60 + 45, wert: "22:45",
                                        abgesegnet_am: "2026-09-19"}),
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
        Map.put(anker(:zeitpunkt, ["u11"], %{minute: 600, abgesegnet_am: "2026-09-18"}),
                :anker_id, "z_a"),
        Map.put(anker(:zeitpunkt, ["u11"], %{minute: 900, abgesegnet_am: "2026-09-19"}),
                :anker_id, "z_b")
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
      vorher = :erlang.system_info(:atom_count)
      a = [anker("voellig-unbekannt-#{System.unique_integer([:positive])}", ["u11"])]

      linie = Linie.bauen(stellen(), a)

      assert length(linie.reihe) == 9
      # Kein String.to_atom auf Fremddaten: die Atom-Tabelle wächst nicht.
      assert :erlang.system_info(:atom_count) - vorher < 5
    end

    test "art als String verhält sich wie das Atom" do
      a = [anker("zeitpunkt", ["u11"], %{minute: 42})]
      assert Linie.bauen(stellen(), a).nach_utterance["u11"].minute == 42
    end
  end
end
