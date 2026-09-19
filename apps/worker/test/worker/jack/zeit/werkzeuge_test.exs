defmodule Worker.Jack.Zeit.WerkzeugeTest do
  @moduledoc """
  #1247 (Z2): die Werkzeuge des Zeit-Jack — der ganze Weg, nicht nur ihre
  Form.

  **Der Test fährt die Kette**, wie es die #1211-Lehre verlangt: setzen →
  Rückfrage → über die Kennung entscheiden → fertig. Ein Test, der nur ein
  `fertig` skriptet, erreicht die Ablehnungen nie — und genau dort sitzen die
  Regeln.
  """
  use ExUnit.Case, async: true

  alias Worker.Jack.Resuemee.Halter
  alias Worker.Jack.Zeit.{Stand, Werkzeuge}

  defp zeile(nr, id, text),
    do: %{nr: nr, utterance_id: id, sprecher: "SL", text: text, block_id: "b#{nr}", block_text: nil, ooc?: false}

  defp mitschnitt do
    [
      zeile(1, "u1", "Ich schaue mal auf die Uhr."),
      zeile(2, "u2", "Wie viel Uhr ist es denn jetzt gerade?"),
      zeile(3, "u3", "Drei viertel elf."),
      zeile(4, "u4", "Wir machen nochmal zehn Minuten mehr."),
      zeile(5, "u5", "Nach einer weiteren halben Stunde seid ihr wieder da.")
    ]
  end

  defp halter(lauf \\ :einsortieren) do
    {:ok, h} = Halter.start_link(Stand.neu(lauf, mitschnitt()), abbild: &Stand.abbild/1)
    h
  end

  defp ruf(h, name, felder) do
    w = Werkzeuge.fuer(h) |> Enum.find(&(&1.name == name))
    assert w, "Werkzeug #{name} fehlt"
    w.ausfuehren.(felder)
  end

  defp stand(h), do: Halter.stand(h)

  describe "welche Werkzeuge es gibt" do
    test "der Gedächtnis-Lauf setzt nichts" do
      namen = Werkzeuge.namen(Stand.neu(:gedaechtnis, mitschnitt()))

      assert "mitschnitt" in namen
      assert "linie" in namen
      refute "zeitpunkt" in namen
      refute "loesen" in namen
    end

    test "Einsortieren und Prüfen haben dieselben Werkzeuge" do
      a = Werkzeuge.namen(Stand.neu(:einsortieren, mitschnitt()))
      b = Werkzeuge.namen(Stand.neu(:pruefen, mitschnitt()))

      # Der Unterschied liegt im Auftrag und im Gegenstand, nicht im Kasten.
      assert a == b
    end

    test "hilfe kommt automatisch dazu und ist nicht doppelt" do
      namen = Werkzeuge.fuer(halter()) |> Enum.map(& &1.name)

      assert "hilfe" in namen
      assert Enum.count(namen, &(&1 == "hilfe")) == 1
    end
  end

  describe "lesen zählt mit" do
    test "mitschnitt/2 gibt Zeilen aus und merkt sie als gelesen" do
      h = halter()
      assert Stand.zahlen(stand(h)).gelesen == 0

      antwort = ruf(h, "mitschnitt", %{"ab" => 1, "anzahl" => 3})

      assert antwort =~ "Drei viertel elf"
      assert antwort =~ "gelesen 3"
      assert Stand.zahlen(stand(h)).gelesen == 3
    end

    test "jenseits des Endes kommt eine Auskunft, kein leerer Text" do
      assert ruf(halter(), "mitschnitt", %{"ab" => 99}) =~ "5 Zeilen"
    end
  end

  describe "setzen" do
    test "ein Zeitpunkt wird gesetzt, die Antwort nennt Stelle und Reststand" do
      h = halter()

      antwort =
        ruf(h, "zeitpunkt", %{
          "zeilen" => [3],
          "wert" => "drei viertel elf",
          "welt" => "spielwelt",
          "beleg" => "Drei viertel elf."
        })

      assert antwort =~ "drei viertel elf"
      assert antwort =~ "spielwelt"
      assert antwort =~ "Anker 1"
      assert Stand.zahlen(stand(h)).zeitpunkte == 1
    end

    test "eine unbekannte Zeilennummer trägt NICHTS ein und sagt das" do
      # Stilles Weglassen hinge den Anker an weniger Zeilen, als Jack meinte.
      h = halter()

      antwort =
        ruf(h, "zeitpunkt", %{
          "zeilen" => [3, 99],
          "wert" => "x",
          "welt" => "spielwelt",
          "beleg" => "b"
        })

      assert antwort =~ "99"
      assert antwort =~ "Nichts eingetragen"
      assert Stand.zahlen(stand(h)).anker == 0
    end

    test "eine Spanne an derselben Zeile wie ein Zeitpunkt geht ohne Rückfrage" do
      # S3/Block 1106: „eine Stunde vergangen, dann ist es kurz nach zwölf" —
      # Dauer und Zeitpunkt in einer Äusserung ergänzen sich.
      h = halter()

      ruf(h, "zeitpunkt", %{"zeilen" => [5], "wert" => "zwölf", "welt" => "spielwelt", "beleg" => "b"})
      antwort = ruf(h, "spanne", %{"zeilen" => [5], "wert" => "eine halbe Stunde", "welt" => "spielwelt", "beleg" => "b"})

      assert antwort =~ "Spanne"
      assert Stand.zahlen(stand(h)).anker == 2
    end
  end

  describe "die Kette: Rückfrage → Entscheidung" do
    test "zweiter Zeitpunkt an derselben Stelle fragt zurück und trägt nichts ein" do
      h = halter()
      ruf(h, "zeitpunkt", %{"zeilen" => [3], "wert" => "4:11", "welt" => "spielwelt", "beleg" => "b"})

      antwort =
        ruf(h, "zeitpunkt", %{"zeilen" => [3], "wert" => "22:45", "welt" => "spielwelt", "beleg" => "b"})

      assert antwort =~ "hängt schon"
      assert antwort =~ "4:11"
      assert antwort =~ "noch nichts"
      # Nichts eingetragen: immer noch ein Anker.
      assert Stand.zahlen(stand(h)).anker == 1
    end

    test "mit der Kennung aus der Rückfrage kommt er daneben" do
      h = halter()
      ruf(h, "zeitpunkt", %{"zeilen" => [3], "wert" => "4:11", "welt" => "spielwelt", "beleg" => "b"})
      rueck = ruf(h, "zeitpunkt", %{"zeilen" => [3], "wert" => "22:45", "welt" => "spielwelt", "beleg" => "b"})

      [_, guid] = Regex.run(~r/dazu\("([^"]+)"/, rueck)

      antwort =
        ruf(h, "dazu", %{
          "kennung" => guid,
          "zeilen" => [3],
          "art" => "zeitpunkt",
          "wert" => "22:45",
          "welt" => "spielwelt",
          "beleg" => "b"
        })

      assert antwort =~ "22:45"
      assert Stand.zahlen(stand(h)).anker == 2
    end

    test "eine erfundene Kennung trägt nichts ein und wird benannt" do
      h = halter()
      ruf(h, "zeitpunkt", %{"zeilen" => [3], "wert" => "4:11", "welt" => "spielwelt", "beleg" => "b"})

      antwort =
        ruf(h, "dazu", %{
          "kennung" => "ausgedacht",
          "zeilen" => [3],
          "art" => "zeitpunkt",
          "wert" => "22:45",
          "welt" => "spielwelt",
          "beleg" => "b"
        })

      assert antwort =~ "nie ausgegeben"
      assert Stand.zahlen(stand(h)).anker == 1
    end
  end

  describe "loesen und zweifel" do
    test "gelöste Zeilen liegen nicht mehr auf der Linie" do
      h = halter()
      antwort = ruf(h, "loesen", %{"zeilen" => [4], "grund" => "Restzeit des Abends"})

      assert antwort =~ "Restzeit des Abends"
      assert antwort =~ "nie interpoliert"
      assert Stand.zahlen(stand(h)).geloest == 1
    end

    test "zweifel setzt nichts, hält aber fest" do
      h = halter()
      antwort = ruf(h, "zweifel", %{"zeilen" => [3], "text" => "Tisch oder Welt unklar"})

      assert antwort =~ "nichts gesetzt"
      assert Stand.zahlen(stand(h)).zeitpunkte == 0
    end
  end

  describe "fertig" do
    test "lehnt ab, solange Zeilen ungelesen sind — mit Zahl und Nummern" do
      h = halter()
      ruf(h, "mitschnitt", %{"ab" => 1, "anzahl" => 2})

      antwort = ruf(h, "fertig", %{})

      assert antwort =~ "Noch nicht fertig"
      assert antwort =~ "3 von 5"
      assert antwort =~ "3, 4, 5"
    end

    test "geht, wenn alles gelesen ist — ohne dass jede Zeile bestätigt wäre" do
      h = halter()
      ruf(h, "mitschnitt", %{"ab" => 1, "anzahl" => 5})

      assert ruf(h, "fertig", %{}) =~ "Abgeschlossen"
    end

    test "offen/0 nennt dasselbe, bevor fertig ablehnt" do
      h = halter()
      ruf(h, "mitschnitt", %{"ab" => 1, "anzahl" => 2})

      assert ruf(h, "offen", %{}) =~ "3 von 5"
    end
  end

  describe "linie zeigt das Ergebnis" do
    test "belegte und gerechnete Zeiten sind unterscheidbar" do
      h = halter()
      ruf(h, "mitschnitt", %{"ab" => 1, "anzahl" => 5})
      ruf(h, "zeitpunkt", %{"zeilen" => [1], "wert" => "22:00", "welt" => "spielwelt", "beleg" => "b"})
      ruf(h, "zeitpunkt", %{"zeilen" => [5], "wert" => "23:00", "welt" => "spielwelt", "beleg" => "b"})

      antwort = ruf(h, "linie", %{})

      assert antwort =~ "belegt"
      assert antwort =~ "gerechnet"
    end

    test "gelöste Zeilen werden als solche ausgewiesen" do
      h = halter()
      ruf(h, "loesen", %{"zeilen" => [4], "grund" => "Tisch"})

      assert ruf(h, "linie", %{}) =~ "aus der Kette gelöst"
    end
  end
end
