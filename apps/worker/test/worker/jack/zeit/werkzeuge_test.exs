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
    do: %{
      nr: nr,
      utterance_id: id,
      sprecher: "SL",
      text: text,
      block_id: "b#{nr}",
      block_text: nil,
      ooc?: false
    }

  defp mitschnitt do
    [
      zeile(1, "u1", "Ich schaue mal auf die Uhr."),
      zeile(2, "u2", "Wie viel Uhr ist es denn jetzt gerade?"),
      zeile(3, "u3", "Drei viertel elf."),
      zeile(4, "u4", "Wir machen nochmal zehn Minuten mehr."),
      zeile(5, "u5", "Nach einer weiteren halben Stunde seid ihr wieder da.")
    ]
  end

  # **Der Halter liefert eine Kette, in der schon alles liegt.** Seit sie leer
  # beginnt (#1247, 20.09.2026), wird ein Anker an einer nicht eingereihten
  # Zeile abgelehnt — er wäre gesetzt und unsichtbar. Die Tests dieser Datei
  # prüfen das Verhalten der ANKER; dass sie dafür erst einreihen müssen, ist
  # Vorbedingung, nicht Gegenstand. Wer die leere Kette braucht, nimmt
  # `leerer_halter/1`.
  defp halter(lauf \\ :einsortieren) do
    h = leerer_halter(lauf)
    if lauf != :gedaechtnis, do: ruf(h, "haenge_an_kette", %{"von" => 1, "bis" => 5})
    h
  end

  defp leerer_halter(lauf \\ :einsortieren) do
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
      {art, text} when art in [:ok, :error, :halt] ->
        text

      anderes ->
        flunk("#{name} lieferte eine Form, die die Laufzeit ablehnt: #{inspect(anderes)}")
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
  defp beispiel("lies_sprechlinie"), do: %{"ab" => 1, "anzahl" => 2}
  defp beispiel("lies_kette"), do: %{}
  defp beispiel(n) when n in ~w(offen zahlen fertig hilfe), do: %{}

  defp beispiel(n) when n in ~w(setz_zeitpunkt setz_spanne setz_frist),
    do: %{"zeilen" => [1], "wert" => "22:45", "welt" => "spielwelt", "beleg" => "b"}

  defp beispiel(n) when n in ~w(anker_dazu anker_ersetzen),
    do: %{
      "kennung" => "unbekannt",
      "zeilen" => [1],
      "art" => "setz_zeitpunkt",
      "wert" => "22:45",
      "welt" => "spielwelt",
      "beleg" => "b"
    }

  defp beispiel("versetze_kettenglied"), do: %{"glied" => 1, "anfang" => true, "beleg" => "b"}
  defp beispiel("loesche_kettenglied"), do: %{"glied" => 1}
  defp beispiel("erweitere_kettenglied"), do: %{"glied" => 1, "zeilen" => [3]}
  defp beispiel("nicht_in_die_kette"), do: %{"zeilen" => [1], "grund" => "Tisch"}
  defp beispiel("haenge_an_kette"), do: %{"von" => 1, "bis" => 2}
  defp beispiel("unterhaenge_kettenglied"), do: %{"glied" => 1, "zeilen" => [3]}

  defp beispiel("sitzungen"), do: %{}
  defp beispiel("lies_frueher"), do: %{"sitzung" => 9, "ab" => 1}
  defp beispiel("vorige_gedanken"), do: %{}

  defp beispiel("nimm_anker_zurueck"),
    do: %{"zeilen" => [1], "art" => "zeitpunkt", "grund" => "trägt nicht"}

  defp beispiel("melde_konflikt"), do: %{"zeilen" => [1], "befund" => "x", "beleg" => "b"}
  defp beispiel("kettenplatz_unklar"), do: %{"zeilen" => [1], "text" => "unklar"}

  describe "welche Werkzeuge es gibt" do
    test "der Gedächtnis-Lauf setzt nichts" do
      namen = Werkzeuge.namen(Stand.neu(:gedaechtnis, mitschnitt()))

      assert "lies_sprechlinie" in namen
      assert "lies_kette" in namen
      refute "setz_zeitpunkt" in namen
      refute "loesche_kettenplatz" in namen
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
      ruf(h, "lies_sprechlinie", %{"ab" => 1, "anzahl" => 5})
      ruf(h, "haenge_an_kette", %{"von" => 1, "bis" => 5})

      assert art(h, "fertig", %{}) == :halt
    end

    test "eine Ablehnung ist :error, keine Auskunft" do
      h = leerer_halter()
      ruf(h, "lies_sprechlinie", %{"ab" => 1, "anzahl" => 2})

      # Noch ungelesene Zeilen: fertig lehnt ab.
      assert art(h, "fertig", %{}) == :error

      # Eine Zeilennummer, die es nicht gibt.
      assert art(h, "setz_zeitpunkt", %{
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
      assert "lies_sprechlinie" in namen
    end

    test "er setzt nichts — sein Ergebnis sind die Notizen" do
      namen = Werkzeuge.namen(Stand.neu(:gedaechtnis, mitschnitt()))

      for w <-
            ~w(setz_zeitpunkt setz_spanne setz_frist versetze_kettenplatz loesche_kettenplatz melde_konflikt),
          do: refute(w in namen, w)

      assert "notiz" in namen
      assert "notizen_lesen" in namen
    end

    test "fertig prüft die Leseabdeckung des Mitschnitts" do
      h = gedaechtnis()

      assert art(h, "fertig", %{}) == :error

      ruf(h, "lies_sprechlinie", %{"ab" => 1, "anzahl" => 5})
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
      assert "setz_zeitpunkt" in namen
    end
  end

  describe "lesen zählt mit" do
    test "mitschnitt/2 gibt Zeilen aus und merkt sie als gelesen" do
      h = leerer_halter()
      assert Stand.zahlen(stand(h)).gelesen == 0

      antwort = ruf(h, "lies_sprechlinie", %{"ab" => 1, "anzahl" => 3})

      assert antwort =~ "Drei viertel elf"
      assert antwort =~ "gelesen 3"
      assert Stand.zahlen(stand(h)).gelesen == 3
    end

    test "jenseits des Endes kommt eine Auskunft, kein leerer Text" do
      assert ruf(halter(), "lies_sprechlinie", %{"ab" => 99}) =~ "5 Zeilen"
    end
  end

  describe "setzen" do
    test "ein Zeitpunkt wird gesetzt, die Antwort nennt Stelle und Reststand" do
      h = halter()

      antwort =
        ruf(h, "setz_zeitpunkt", %{
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
        ruf(h, "setz_zeitpunkt", %{
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

      ruf(h, "setz_zeitpunkt", %{
        "zeilen" => [5],
        "wert" => "zwölf",
        "welt" => "spielwelt",
        "beleg" => "b"
      })

      antwort =
        ruf(h, "setz_spanne", %{
          "zeilen" => [5],
          "wert" => "eine halbe Stunde",
          "welt" => "spielwelt",
          "beleg" => "b"
        })

      assert antwort =~ "Spanne"
      assert Stand.zahlen(stand(h)).anker == 2
    end
  end

  describe "die Frist zeigt nach vorn" do
    test "sie wird gesetzt und sagt, dass sie nichts verschiebt" do
      h = halter()

      antwort =
        ruf(h, "setz_frist", %{
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

      ruf(h, "setz_zeitpunkt", %{
        "zeilen" => [1],
        "wert" => "22:00",
        "welt" => "spielwelt",
        "beleg" => "b"
      })

      ruf(h, "setz_zeitpunkt", %{
        "zeilen" => [5],
        "wert" => "23:00",
        "welt" => "spielwelt",
        "beleg" => "b"
      })

      ohne = ruf(h, "lies_kette", %{})

      ruf(h, "setz_frist", %{
        "zeilen" => [3],
        "wert" => "noch eine Woche",
        "welt" => "spielwelt",
        "beleg" => "b"
      })

      mit = ruf(h, "lies_kette", %{})

      assert ohne == mit, "eine Frist darf die gerechnete Linie nicht verändern"
    end

    test "eine Frist neben einer Spanne an derselben Zeile ist kein Konflikt" do
      h = halter()

      ruf(h, "setz_spanne", %{
        "zeilen" => [3],
        "wert" => "zwei Stunden",
        "welt" => "spielwelt",
        "beleg" => "b"
      })

      assert art(h, "setz_frist", %{
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

      ruf(h, "setz_zeitpunkt", %{
        "zeilen" => [3],
        "wert" => "4:11",
        "welt" => "spielwelt",
        "beleg" => "b"
      })

      antwort =
        ruf(h, "setz_zeitpunkt", %{
          "zeilen" => [3],
          "wert" => "22:45",
          "welt" => "spielwelt",
          "beleg" => "b"
        })

      assert antwort =~ "hängt schon"
      assert antwort =~ "4:11"
      assert antwort =~ "noch nichts"
      # Nichts eingetragen: immer noch ein Anker.
      assert Stand.zahlen(stand(h)).anker == 1
    end

    test "mit der Kennung aus der Rückfrage kommt er daneben" do
      h = halter()

      ruf(h, "setz_zeitpunkt", %{
        "zeilen" => [3],
        "wert" => "4:11",
        "welt" => "spielwelt",
        "beleg" => "b"
      })

      rueck =
        ruf(h, "setz_zeitpunkt", %{
          "zeilen" => [3],
          "wert" => "22:45",
          "welt" => "spielwelt",
          "beleg" => "b"
        })

      [_, guid] = Regex.run(~r/dazu\("([^"]+)"/, rueck)

      antwort =
        ruf(h, "anker_dazu", %{
          "kennung" => guid,
          "zeilen" => [3],
          "art" => "setz_zeitpunkt",
          "wert" => "22:45",
          "welt" => "spielwelt",
          "beleg" => "b"
        })

      assert antwort =~ "22:45"
      assert Stand.zahlen(stand(h)).anker == 2
    end

    test "eine erfundene Kennung trägt nichts ein und wird benannt" do
      h = halter()

      ruf(h, "setz_zeitpunkt", %{
        "zeilen" => [3],
        "wert" => "4:11",
        "welt" => "spielwelt",
        "beleg" => "b"
      })

      antwort =
        ruf(h, "anker_dazu", %{
          "kennung" => "ausgedacht",
          "zeilen" => [3],
          "art" => "setz_zeitpunkt",
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
      antwort = ruf(h, "nicht_in_die_kette", %{"zeilen" => [4], "grund" => "Restzeit des Abends"})

      assert antwort =~ "bleiben draussen"
      assert antwort =~ "bleiben draussen"
      # `geloest` zählte Anker der Art `:geloest`; die gibt es seit dem
      # Kettenumbau nicht mehr — „draussen" ist ein Zustand der Kette, kein
      # Anker.
      assert Stand.zahlen(stand(h)).draussen == 1
    end

    test "zweifel setzt nichts, hält aber fest" do
      h = halter()

      antwort =
        ruf(h, "kettenplatz_unklar", %{"zeilen" => [3], "text" => "Tisch oder Welt unklar"})

      assert antwort =~ "keine Zeit gesetzt"
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

      ruf(h, "lies_sprechlinie", %{"ab" => 61, "anzahl" => 80})

      antwort = ruf(h, "offen", %{})

      assert antwort =~ "1–60"
      assert antwort =~ "141–2168"
    end

    test "lückenlos gelesen ergibt einen Bereich" do
      h = leerer_halter()
      ruf(h, "lies_sprechlinie", %{"ab" => 1, "anzahl" => 2})

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
      h = leerer_halter()
      ruf(h, "lies_sprechlinie", %{"ab" => 1, "anzahl" => 5})

      antwort = ruf(h, "fertig", %{})

      assert art(h, "fertig", %{}) == :error
      assert antwort =~ "nicht entschieden"
      assert antwort =~ "1–5"
    end

    test "einreihen, draussen und unklar entscheiden — dann geht fertig" do
      h = leerer_halter()
      ruf(h, "lies_sprechlinie", %{"ab" => 1, "anzahl" => 5})

      ruf(h, "haenge_an_kette", %{"von" => 1, "bis" => 3})
      ruf(h, "nicht_in_die_kette", %{"zeilen" => [4], "grund" => "Pausenabsprache"})
      ruf(h, "kettenplatz_unklar", %{"zeilen" => [5], "text" => "Tisch oder Welt unklar"})

      assert Stand.zahlen(stand(h)).unentschieden == 0
      assert art(h, "fertig", %{}) == :halt
    end

    test "haenge_an_kette nimmt einen Bereich — nicht achtzig Einzelnummern" do
      h = leerer_halter()
      ruf(h, "lies_sprechlinie", %{"ab" => 1, "anzahl" => 5})

      antwort = ruf(h, "haenge_an_kette", %{"von" => 2, "bis" => 4})

      assert antwort =~ "Zeilen 2–4"
      assert Stand.zahlen(stand(h)).in_der_kette == 3
    end

    test "haenge_an_kette zählt die Zeilen auch als gelesen" do
      # Wer eine Zeile einordnet, hat sie gesehen — sonst müsste er sie
      # zweimal anfassen.
      h = leerer_halter()
      ruf(h, "haenge_an_kette", %{"von" => 1, "bis" => 5})

      assert Stand.zahlen(stand(h)).gelesen == 5
    end

    test "eine Zeile ohne jede Angabe wird abgelehnt" do
      assert art(leerer_halter(), "haenge_an_kette", %{}) == :error
    end

    test "unterhaengen stellt ein Glied IN ein anderes, nicht daneben" do
      # Maintainer, 20.09.2026: „ein glied hängt entweder am zeitstrahl oder
      # an einem glied." Der Zeitstrahl bekommt kein zweites Wurzelglied.
      h = leerer_halter()
      ruf(h, "lies_sprechlinie", %{"ab" => 1, "anzahl" => 5})
      ruf(h, "haenge_an_kette", %{"von" => 1, "bis" => 3, "grund" => "der Überfall"})

      antwort =
        ruf(h, "unterhaenge_kettenglied", %{
          "glied" => 1,
          "von" => 4,
          "bis" => 5,
          "grund" => "die Flucht"
        })

      assert antwort =~ "Zeilen 4–5"
      assert antwort =~ "gehängt"

      k = stand(h).kette
      assert length(k.glieder) == 1, "auf dem Zeitstrahl steht weiterhin EIN Glied"
      assert Worker.Timeline.Kette.anzahl(k) == 2, "im Baum sind es zwei"
      assert Worker.Timeline.Kette.reihenfolge(k) == ~w(u1 u2 u3 u4 u5)
    end

    test "lies_kette zeigt das Unterglied eingerückt unter seinem Elternglied" do
      h = leerer_halter()
      ruf(h, "haenge_an_kette", %{"von" => 1, "bis" => 3, "grund" => "der Überfall"})
      ruf(h, "unterhaenge_kettenglied", %{"glied" => 1, "zeilen" => [4], "grund" => "die Flucht"})

      antwort = ruf(h, "lies_kette", %{})

      assert antwort =~ "der Überfall"
      assert antwort =~ "↳", "ein Unterglied ist als solches erkennbar"
      assert antwort =~ "die Flucht"
    end

    test "das Elternglied nennt die Spanne seines ganzen Unterbaums" do
      # „Zeilen 1–3" wäre eine Teilangabe, sobald Kinder daran hängen — wer
      # das Glied versetzt, bewegt den ganzen Baum.
      h = leerer_halter()
      ruf(h, "haenge_an_kette", %{"von" => 1, "bis" => 3})
      ruf(h, "unterhaenge_kettenglied", %{"glied" => 1, "von" => 4, "bis" => 5})

      assert ruf(h, "lies_kette", %{}) =~ "Zeilen 1–5"
    end

    test "unterhaengen an einer Zeile, die in keinem Glied liegt" do
      h = leerer_halter()
      antwort = ruf(h, "unterhaenge_kettenglied", %{"glied" => 1, "zeilen" => [3]})

      assert art(h, "unterhaenge_kettenglied", %{"glied" => 1, "zeilen" => [3]}) == :error
      assert antwort =~ "keinem Kettenglied"
    end

    test "die Glieder an einem Glied sind wieder eine Kette — versetzen und löschen gelten dort" do
      # Maintainer, 20.09.2026: „die glieder die an einem glied hängen sind
      # wieder eine kette."
      h = leerer_halter()
      ruf(h, "haenge_an_kette", %{"zeilen" => [1], "grund" => "der Überfall"})
      ruf(h, "unterhaenge_kettenglied", %{"zeilen" => [2], "glied" => 1, "grund" => "Hinterhalt"})
      ruf(h, "unterhaenge_kettenglied", %{"zeilen" => [3], "glied" => 1, "grund" => "Flucht"})

      ruf(h, "versetze_kettenglied", %{"glied" => 3, "vor" => 2, "beleg" => "davor"})
      assert Worker.Timeline.Kette.reihenfolge(stand(h).kette) == ~w(u1 u3 u2)

      ruf(h, "loesche_kettenglied", %{"glied" => 3})
      assert Worker.Timeline.Kette.reihenfolge(stand(h).kette) == ~w(u1 u2)
    end

    test "versetzen über die Ebenengrenze wird abgelehnt, mit Grund" do
      h = leerer_halter()
      ruf(h, "haenge_an_kette", %{"zeilen" => [1]})
      ruf(h, "haenge_an_kette", %{"zeilen" => [2]})
      ruf(h, "unterhaenge_kettenglied", %{"zeilen" => [3], "glied" => 1})

      antwort = ruf(h, "versetze_kettenglied", %{"glied" => 3, "nach" => 2, "beleg" => "danach"})

      assert antwort =~ "derselben Ebene"
      assert Worker.Timeline.Kette.reihenfolge(stand(h).kette) == ~w(u1 u3 u2)
    end
  end

  describe "fertig" do
    test "lehnt ab, solange Zeilen ungelesen sind — mit Zahl und Nummern" do
      h = leerer_halter()
      ruf(h, "lies_sprechlinie", %{"ab" => 1, "anzahl" => 2})

      antwort = ruf(h, "fertig", %{})

      assert antwort =~ "Noch nicht fertig"
      assert antwort =~ "3 von 5"
      assert antwort =~ "3–5"
    end

    test "geht, wenn alles gelesen UND entschieden ist" do
      h = leerer_halter()
      ruf(h, "lies_sprechlinie", %{"ab" => 1, "anzahl" => 5})
      ruf(h, "haenge_an_kette", %{"von" => 1, "bis" => 5})

      assert ruf(h, "fertig", %{}) =~ "Abgeschlossen"
    end

    test "offen/0 nennt dasselbe, bevor fertig ablehnt" do
      h = leerer_halter()
      ruf(h, "lies_sprechlinie", %{"ab" => 1, "anzahl" => 2})

      assert ruf(h, "offen", %{}) =~ "3 von 5"
      assert ruf(h, "offen", %{}) =~ "3–5"
    end
  end

  describe "Wortform-Uhrzeiten durch die ganze Kette" do
    test "drei gesagte Uhrzeiten ergeben eine Linie mit stimmenden Abständen" do
      # Die drei echten Anker der Referenzsitzung, so wie Jack sie setzen
      # würde — in Worten, ohne Halbtag. Die Kette entscheidet ihn.
      # **Je Uhrzeit ein Glied** — ein Glied ist eine Zeiteinheit, drei
      # verschiedene Zeitpunkte darin wären ein Widerspruch (und werden als
      # solcher gemeldet).
      h = leerer_halter()
      ruf(h, "lies_sprechlinie", %{"ab" => 1, "anzahl" => 5})
      for nr <- 1..5, do: ruf(h, "haenge_an_kette", %{"zeilen" => [nr]})

      for {zeile, wert} <- [{1, "Drei viertel elf"}, {3, "kurz nach zwölf"}, {5, "kurz vor zwei"}] do
        ruf(h, "setz_zeitpunkt", %{
          "zeilen" => [zeile],
          "wert" => wert,
          "welt" => "spielwelt",
          "beleg" => wert
        })
      end

      antwort = ruf(h, "lies_kette", %{})

      assert antwort =~ "10:45 belegt"
      assert antwort =~ "12:05 belegt"
      assert antwort =~ "13:50 belegt"
    end

    test "die Antwort sagt, dass die Wortform gelesen wurde" do
      h = halter()

      antwort =
        ruf(h, "setz_zeitpunkt", %{
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
      ruf(h, "lies_sprechlinie", %{"ab" => 1, "anzahl" => 5})

      ruf(h, "setz_zeitpunkt", %{
        "zeilen" => [1],
        "wert" => "Drei viertel elf",
        "welt" => "spielwelt",
        "beleg" => "b",
        "halbtag" => "nachmittag"
      })

      assert ruf(h, "lies_kette", %{}) =~ "22:45 belegt"
    end
  end

  describe "die Linie zeigt ein Datum, keinen Tageszähler" do
    test "ein Jahr wird als Datum gezeigt, nicht als T+730000" do
      # Der Befund des dritten echten Laufs, und es ist die #1092-Klasse:
      # Für das Jahr 2000 stand `T+730000 00:00` in der Linie. Das Modell
      # konnte die Zahl nicht deuten, riet („roughly 202 hours") und schloss
      # daraus, die Anker seien falsch gemessen.
      h = halter()
      ruf(h, "lies_sprechlinie", %{"ab" => 1, "anzahl" => 5})

      ruf(h, "setz_zeitpunkt", %{
        "zeilen" => [1],
        "wert" => "15.11.2080",
        "welt" => "spielwelt",
        "beleg" => "am fünfzehnten November"
      })

      antwort = ruf(h, "lies_kette", %{})

      assert antwort =~ "2080"
      refute antwort =~ "T+7", "der rohe Tageszähler ist für niemanden lesbar"
    end

    test "innerhalb des ersten Tages bleibt es bei der Uhrzeit" do
      h = halter()

      ruf(h, "setz_zeitpunkt", %{
        "zeilen" => [1],
        "wert" => "22:45",
        "welt" => "spielwelt",
        "beleg" => "b"
      })

      antwort = ruf(h, "lies_kette", %{})

      assert antwort =~ "22:45"
      refute antwort =~ "T+"
    end
  end

  describe "linie zeigt das Ergebnis" do
    test "belegte und gerechnete Zeiten sind unterscheidbar" do
      # Gerechnet wird zwischen GLIEDERN — mit allem in einem Glied gäbe es
      # nichts zu interpolieren.
      h = leerer_halter()
      ruf(h, "lies_sprechlinie", %{"ab" => 1, "anzahl" => 5})
      for nr <- 1..5, do: ruf(h, "haenge_an_kette", %{"zeilen" => [nr]})

      ruf(h, "setz_zeitpunkt", %{
        "zeilen" => [1],
        "wert" => "22:00",
        "welt" => "spielwelt",
        "beleg" => "b"
      })

      ruf(h, "setz_zeitpunkt", %{
        "zeilen" => [5],
        "wert" => "23:00",
        "welt" => "spielwelt",
        "beleg" => "b"
      })

      antwort = ruf(h, "lies_kette", %{})

      assert antwort =~ "belegt"
      assert antwort =~ "gerechnet"
    end

    test "Zeilen draussen erscheinen nicht in der Kette, aber im Stand" do
      h = halter()
      ruf(h, "nicht_in_die_kette", %{"zeilen" => [4], "grund" => "Tisch"})

      antwort = ruf(h, "lies_kette", %{})
      assert antwort =~ "1 draussen"
      assert antwort =~ "4 Zeilen drin"
    end
  end
end
