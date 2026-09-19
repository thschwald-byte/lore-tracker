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

  alias Worker.Agent.Aufruf
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

  # **Gerufen wird über DIESELBE Kette wie zur Laufzeit** (`Worker.Agent.Aufruf`),
  # nicht über `w.ausfuehren` direkt. Der erste Wurf tat das Zweite und prüfte
  # den blanken String — und ging damit an genau der Stelle vorbei, an der die
  # Laufzeit die Form prüft: `Aufruf.sicher/2` verlangt `{:ok | :error | :halt
  # | …, inhalt}`. Alle Zeit-Werkzeuge lieferten stattdessen nackten Text.
  #
  # Im echten Lauf war deshalb JEDER Aufruf „Werkzeug X lieferte ein ungültiges
  # Ergebnis" — der Text kam trotzdem durch, das Modell sah eine Fehlermeldung
  # über einer korrekten Antwort und zweifelte an sich statt am Werkzeug. Und
  # `fertig()` konnte den Lauf nie beenden, weil `:halt` fehlte. Beides hätte
  # dieser Helfer gefangen, wenn er die echte Kette gefahren wäre; 21 grüne
  # Tests haben es nicht gemerkt.
  defp ruf(h, name, felder) do
    assert Enum.any?(Werkzeuge.fuer(h), &(&1.name == name)), "Werkzeug #{name} fehlt"

    case laufzeit(h, name, felder) do
      {art, text} when art in [:ok, :error, :halt] -> text
      anderes -> flunk("#{name} lieferte eine Form, die die Laufzeit ablehnt: #{inspect(anderes)}")
    end
  end

  # Wie das Werkzeug geantwortet hat — für die Fälle, in denen die ART zählt.
  defp art(h, name, felder), do: laufzeit(h, name, felder) |> elem(0)

  defp laufzeit(h, name, felder) do
    werkzeuge = Werkzeuge.fuer(h) |> Map.new(&{&1.name, &1})
    Aufruf.ausfuehren(%{name: name, argumente: {:ok, felder}}, werkzeuge)
  end

  defp stand(h), do: Halter.stand(h)

  # Gültige Beispielargumente je Werkzeug — für den Formtest, der jedes
  # einmal ruft.
  defp beispiel("notiz"), do: %{"abschnitt" => "ABLAUF", "schluessel" => "k", "text" => "t"}
  defp beispiel("notizen_lesen"), do: %{}
  defp beispiel("mitschnitt"), do: %{"ab" => 1, "anzahl" => 2}
  defp beispiel("linie"), do: %{}
  defp beispiel(n) when n in ~w(offen zahlen fertig hilfe), do: %{}

  defp beispiel(n) when n in ~w(zeitpunkt spanne frist),
    do: %{"zeilen" => [1], "wert" => "22:45", "welt" => "spielwelt", "beleg" => "b"}

  defp beispiel(n) when n in ~w(dazu ersetzen),
    do: %{
      "kennung" => "unbekannt",
      "zeilen" => [1],
      "art" => "zeitpunkt",
      "wert" => "22:45",
      "welt" => "spielwelt",
      "beleg" => "b"
    }

  defp beispiel("verschieben"),
    do: %{"zeilen" => [1], "richtung" => "vor", "ziel" => 3, "beleg" => "b"}

  defp beispiel("loesen"), do: %{"zeilen" => [1], "grund" => "Tisch"}
  defp beispiel("ingame"), do: %{"von" => 1, "bis" => 2}
  defp beispiel("konflikt"), do: %{"zeilen" => [1], "befund" => "x", "beleg" => "b"}
  defp beispiel("zweifel"), do: %{"zeilen" => [1], "text" => "unklar"}

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

  describe "die Form, die die Laufzeit verlangt" do
    # Der Befund des ersten echten Laufs (19.09.2026): Jedes Werkzeug lieferte
    # nackten Text statt `{art, inhalt}`. `Worker.Agent.Aufruf.sicher/2` machte
    # daraus „Werkzeug X lieferte ein ungültiges Ergebnis" — der Text kam
    # trotzdem durch, das Modell sah also eine Fehlermeldung über einer
    # korrekten Antwort und zweifelte an sich statt am Werkzeug. Nach drei
    # inneren Fehlern desselben Werkzeugs endet der Lauf.
    test "JEDES Werkzeug jedes Laufs antwortet in einer Form, die die Laufzeit annimmt" do
      for lauf <- [:gedaechtnis, :einsortieren, :pruefen] do
        {:ok, h} = Halter.start_link(Stand.neu(lauf, mitschnitt()), abbild: &Stand.abbild/1)

        for w <- Werkzeuge.fuer(h) do
          felder = beispiel(w.name)

          assert {a, t} = laufzeit(h, w.name, felder),
                 "#{lauf}/#{w.name}: kein Tupel"

          assert a in [:ok, :error, :halt],
                 "#{lauf}/#{w.name}: Art #{inspect(a)} — die Laufzeit kennt " <>
                   ":ok, :error, :halt, :abbruch, :innerer_fehler"

          assert is_binary(t), "#{lauf}/#{w.name}: Inhalt ist kein Text"

          refute t =~ "ungültiges Ergebnis",
                 "#{lauf}/#{w.name}: die Laufzeit hat die Form abgelehnt"
        end
      end
    end

    test "fertig beendet den Lauf mit :halt — sonst endet er nie" do
      # `Worker.Jack.Resuemee.Lauf` prüft auf `%{ende: :halt}`. Ohne die Art
      # wäre der Lauf in den Rundendeckel gelaufen: Stunden, vollständige
      # Arbeit, kein Ergebnis.
      h = halter()
      ruf(h, "mitschnitt", %{"ab" => 1, "anzahl" => 5})
      ruf(h, "ingame", %{"von" => 1, "bis" => 5})

      assert art(h, "fertig", %{}) == :halt
    end

    test "eine Ablehnung ist :error, keine Auskunft" do
      h = halter()
      ruf(h, "mitschnitt", %{"ab" => 1, "anzahl" => 2})

      # Noch ungelesene Zeilen: fertig lehnt ab.
      assert art(h, "fertig", %{}) == :error

      # Eine Zeilennummer, die es nicht gibt.
      assert art(h, "zeitpunkt", %{
               "zeilen" => [99],
               "wert" => "x",
               "welt" => "spielwelt",
               "beleg" => "b"
             }) == :error
    end
  end

  describe "der Gedächtnis-Lauf liest die ÄUSSERUNGEN wie die anderen" do
    # Maintainer, 19.09.2026: „wir stellen den jacklauf ganz auf die utts um —
    # also auch datensammeln aus utts, werkzeug für fakten weg". Der Lauf las
    # bis dahin die Fakten: eine andere Schicht mit anderer Körnung (418 gegen
    # 2168), aus allen Sitzungen der Kampagne, nicht in Gesprächsreihenfolge.
    # Das Modell rätselte darüber mehrfach („facts 205 through 239 seem to
    # repeat earlier content"). Jetzt ist es Jacks eigenes Muster: Phase 1 und
    # Phase 2 lesen denselben Mitschnitt.
    defp gedaechtnis do
      {:ok, h} = Halter.start_link(Stand.neu(:gedaechtnis, mitschnitt()), abbild: &Stand.abbild/1)
      h
    end

    test "er hat KEINE Fakten-Werkzeuge mehr" do
      namen = Werkzeuge.namen(Stand.neu(:gedaechtnis, mitschnitt()))

      refute "fakten" in namen
      refute "fakt" in namen
      assert "mitschnitt" in namen
    end

    test "er setzt nichts — sein Ergebnis sind die Notizen" do
      namen = Werkzeuge.namen(Stand.neu(:gedaechtnis, mitschnitt()))

      for w <- ~w(zeitpunkt spanne frist verschieben loesen konflikt), do: refute(w in namen, w)
      assert "notiz" in namen
      assert "notizen_lesen" in namen
    end

    test "fertig prüft die Leseabdeckung des Mitschnitts" do
      h = gedaechtnis()

      assert art(h, "fertig", %{}) == :error

      ruf(h, "mitschnitt", %{"ab" => 1, "anzahl" => 5})
      assert art(h, "fertig", %{}) == :halt
    end

    test "notiz hält fest, was der nächste Lauf braucht" do
      # Ohne dieses Werkzeug wäre der ganze Lauf wirkungslos: Er setzt nichts,
      # und sein Ergebnis SIND die Notizen.
      h = gedaechtnis()

      assert ruf(h, "notiz", %{
               "abschnitt" => "ZEITEN",
               "schluessel" => "elf",
               "text" => "Zeile 3: „Drei viertel elf\" — Uhrzeit, Welt unklar."
             }) =~ "Notiert unter ZEITEN/elf"

      assert ruf(h, "notizen_lesen", %{}) =~ "Drei viertel elf"
      assert map_size(stand(h).notizen) == 1
    end

    test "ein unbekannter Abschnitt und leere Notizen werden abgelehnt" do
      h = gedaechtnis()

      assert art(h, "notiz", %{"abschnitt" => "ABLAUF", "schluessel" => "k", "text" => " "}) ==
               :error

      assert art(h, "notiz", %{"abschnitt" => "ABLAUF", "schluessel" => " ", "text" => "t"}) ==
               :error
    end

    test "die beiden anderen Läufe notieren nicht — sie setzen Anker" do
      namen = Werkzeuge.namen(Stand.neu(:einsortieren, mitschnitt()))

      refute "notiz" in namen
      assert "zeitpunkt" in namen
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

  describe "die Frist zeigt nach vorn" do
    test "sie wird gesetzt und sagt, dass sie nichts verschiebt" do
      h = halter()

      antwort =
        ruf(h, "frist", %{
          "zeilen" => [3],
          "wert" => "noch eine Woche",
          "welt" => "spielwelt",
          "beleg" => "die Verhandlungen dauern noch eine Woche"
        })

      assert antwort =~ "Frist"
      assert antwort =~ "verschiebt nichts"
      assert Stand.zahlen(stand(h)).fristen == 1
    end

    test "sie bewegt die Linie nicht" do
      # Der Unterschied zur Spanne: Bei der ist die Zeit vergangen, hier steht
      # sie noch bevor. Eine Frist, die interpolierte, verschöbe alles
      # Folgende um eine Woche.
      h = halter()
      ruf(h, "zeitpunkt", %{"zeilen" => [1], "wert" => "22:00", "welt" => "spielwelt", "beleg" => "b"})
      ruf(h, "zeitpunkt", %{"zeilen" => [5], "wert" => "23:00", "welt" => "spielwelt", "beleg" => "b"})
      ohne = ruf(h, "linie", %{})

      ruf(h, "frist", %{"zeilen" => [3], "wert" => "noch eine Woche", "welt" => "spielwelt", "beleg" => "b"})
      mit = ruf(h, "linie", %{})

      assert ohne == mit, "eine Frist darf die gerechnete Linie nicht verändern"
    end

    test "eine Frist neben einer Spanne an derselben Zeile ist kein Konflikt" do
      h = halter()
      ruf(h, "spanne", %{"zeilen" => [3], "wert" => "zwei Stunden", "welt" => "spielwelt", "beleg" => "b"})

      assert art(h, "frist", %{
               "zeilen" => [3],
               "wert" => "noch eine Woche",
               "welt" => "spielwelt",
               "beleg" => "b"
             }) == :ok
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

  describe "offen nennt Bereiche, keine Einzelnummern" do
    test "drei Lücken in 2168 Zeilen werden zu drei Angaben" do
      # Eine Liste der „nächsten zwölf" ist bei tausend offenen Zeilen keine
      # Auskunft: Sie sagt nicht, WO die Lücken sind, und legt nahe, es seien
      # nur diese.
      lang = for i <- 1..2168, do: zeile(i, "u#{i}", "t")
      {:ok, h} = Halter.start_link(Stand.neu(:einsortieren, lang), abbild: &Stand.abbild/1)

      ruf(h, "mitschnitt", %{"ab" => 61, "anzahl" => 80})

      antwort = ruf(h, "offen", %{})

      assert antwort =~ "1–60"
      assert antwort =~ "141–2168"
    end

    test "lückenlos gelesen ergibt einen Bereich" do
      h = halter()
      ruf(h, "mitschnitt", %{"ab" => 1, "anzahl" => 2})

      assert ruf(h, "offen", %{}) =~ "3–5"
    end
  end

  describe "jede Zeile braucht eine Einordnung" do
    # Maintainer, 19.09.2026: „er muss zu jeder schreiben Tischgespräch /
    # In-Game / unklar — alle utts mit tischgespräche müssen aus der kette
    # entfernt sein". Der Grund ist die Linie selbst: Was auf ihr liegt, soll
    # Spielwelt sein. Eine nicht eingeordnete Zeile wird trotzdem
    # interpoliert und bekommt eine Spielzeit, die es nicht gibt.
    test "gelesen allein reicht nicht mehr" do
      h = halter()
      ruf(h, "mitschnitt", %{"ab" => 1, "anzahl" => 5})

      antwort = ruf(h, "fertig", %{})

      assert art(h, "fertig", %{}) == :error
      assert antwort =~ "nicht eingeordnet"
      assert antwort =~ "1–5"
    end

    test "ingame, loesen und zweifel ordnen ein — dann geht fertig" do
      h = halter()
      ruf(h, "mitschnitt", %{"ab" => 1, "anzahl" => 5})

      ruf(h, "ingame", %{"von" => 1, "bis" => 3})
      ruf(h, "loesen", %{"zeilen" => [4], "grund" => "Pausenabsprache"})
      ruf(h, "zweifel", %{"zeilen" => [5], "text" => "Tisch oder Welt unklar"})

      assert Stand.zahlen(stand(h)).eingeordnet == 5
      assert art(h, "fertig", %{}) == :halt
    end

    test "ingame nimmt einen Bereich — nicht achtzig Einzelnummern" do
      h = halter()
      ruf(h, "mitschnitt", %{"ab" => 1, "anzahl" => 5})

      antwort = ruf(h, "ingame", %{"von" => 2, "bis" => 4})

      assert antwort =~ "3 Zeile(n)"
      assert Stand.zahlen(stand(h)).eingeordnet == 3
    end

    test "ingame zählt die Zeilen auch als gelesen" do
      # Wer eine Zeile einordnet, hat sie gesehen — sonst müsste er sie
      # zweimal anfassen.
      h = halter()
      ruf(h, "ingame", %{"von" => 1, "bis" => 5})

      assert Stand.zahlen(stand(h)).gelesen == 5
    end

    test "eine Zeile ohne jede Angabe wird abgelehnt" do
      assert art(halter(), "ingame", %{}) == :error
    end
  end

  describe "fertig" do
    test "lehnt ab, solange Zeilen ungelesen sind — mit Zahl und Nummern" do
      h = halter()
      ruf(h, "mitschnitt", %{"ab" => 1, "anzahl" => 2})

      antwort = ruf(h, "fertig", %{})

      assert antwort =~ "Noch nicht fertig"
      assert antwort =~ "3 von 5"
      assert antwort =~ "3–5"
    end

    test "geht, wenn alles gelesen UND eingeordnet ist" do
      h = halter()
      ruf(h, "mitschnitt", %{"ab" => 1, "anzahl" => 5})
      ruf(h, "ingame", %{"von" => 1, "bis" => 5})

      assert ruf(h, "fertig", %{}) =~ "Abgeschlossen"
    end

    test "offen/0 nennt dasselbe, bevor fertig ablehnt" do
      h = halter()
      ruf(h, "mitschnitt", %{"ab" => 1, "anzahl" => 2})

      assert ruf(h, "offen", %{}) =~ "3 von 5"
      assert ruf(h, "offen", %{}) =~ "3–5"
    end
  end

  describe "Wortform-Uhrzeiten durch die ganze Kette" do
    test "drei gesagte Uhrzeiten ergeben eine Linie mit stimmenden Abständen" do
      # Die drei echten Anker der Referenzsitzung, so wie Jack sie setzen
      # würde — in Worten, ohne Halbtag. Die Kette entscheidet ihn.
      h = halter()
      ruf(h, "mitschnitt", %{"ab" => 1, "anzahl" => 5})

      for {zeile, wert} <- [{1, "Drei viertel elf"}, {3, "kurz nach zwölf"}, {5, "kurz vor zwei"}] do
        ruf(h, "zeitpunkt", %{
          "zeilen" => [zeile],
          "wert" => wert,
          "welt" => "spielwelt",
          "beleg" => wert
        })
      end

      antwort = ruf(h, "linie", %{})

      assert antwort =~ "10:45 belegt"
      assert antwort =~ "12:05 belegt"
      assert antwort =~ "13:50 belegt"
    end

    test "die Antwort sagt, dass die Wortform gelesen wurde" do
      h = halter()

      antwort =
        ruf(h, "zeitpunkt", %{
          "zeilen" => [3],
          "wert" => "Drei viertel elf",
          "welt" => "spielwelt",
          "beleg" => "Drei viertel elf."
        })

      assert antwort =~ "10:45"
      assert antwort =~ "22:45"
    end

    test "mit genanntem Halbtag ist die Uhrzeit sofort eindeutig" do
      h = halter()
      ruf(h, "mitschnitt", %{"ab" => 1, "anzahl" => 5})

      ruf(h, "zeitpunkt", %{
        "zeilen" => [1],
        "wert" => "Drei viertel elf",
        "welt" => "spielwelt",
        "beleg" => "b",
        "halbtag" => "nachmittag"
      })

      assert ruf(h, "linie", %{}) =~ "22:45 belegt"
    end
  end

  describe "die Linie zeigt ein Datum, keinen Tageszähler" do
    test "ein Jahr wird als Datum gezeigt, nicht als T+730000" do
      # Der Befund des dritten echten Laufs, und es ist die #1092-Klasse:
      # Für das Jahr 2000 stand `T+730000 00:00` in der Linie. Das Modell
      # konnte die Zahl nicht deuten, riet („roughly 202 hours") und schloss
      # daraus, die Anker seien falsch gemessen.
      h = halter()
      ruf(h, "mitschnitt", %{"ab" => 1, "anzahl" => 5})

      ruf(h, "zeitpunkt", %{
        "zeilen" => [1],
        "wert" => "15.11.2080",
        "welt" => "spielwelt",
        "beleg" => "am fünfzehnten November"
      })

      antwort = ruf(h, "linie", %{})

      assert antwort =~ "2080"
      refute antwort =~ "T+7", "der rohe Tageszähler ist für niemanden lesbar"
    end

    test "innerhalb des ersten Tages bleibt es bei der Uhrzeit" do
      h = halter()
      ruf(h, "zeitpunkt", %{"zeilen" => [1], "wert" => "22:45", "welt" => "spielwelt", "beleg" => "b"})

      antwort = ruf(h, "linie", %{})

      assert antwort =~ "22:45"
      refute antwort =~ "T+"
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
