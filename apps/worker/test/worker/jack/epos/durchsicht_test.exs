defmodule Worker.Jack.Epos.DurchsichtTest do
  # J6 (#1210, E3): die Durchsicht des Epos-Jack, rein auf dem Stand — kein
  # Mnesia, kein Modell. Stilistisch beauftragt, dazu grobe Schnitzer gegen die
  # Fakten; Hinweise als Fingerzeig. Beispiele aus der Demo-Welt.
  use ExUnit.Case, async: true

  alias Worker.Agent.Schema
  alias Worker.Jack.Epos.{Abschluss, Durchsicht, Entwurf, Ergebnis, Hinweise, Notizen}
  alias Worker.Jack.Epos.{Werkzeuge, Zusammenfassung}
  alias Worker.Jack.Resuemee.{Eingabe, Halter, Melder, Stand}
  alias Worker.Jack.Resuemee.Durchsicht, as: Buch

  @uhrmacher "Der verschwundene Uhrmacher"
  @grund "Brann erkennt das Wappen, der Fakt S2-F3 nennt Mira."

  # 14 Wörter.
  @hafen "Der Regen hing über dem Hafen. Tess schob den Brief unter der Tür hindurch."
  @falsch "Im Licht der Lampe beugte sich Brann über das Wappen der Familie von Arnheim."
  @richtig "Im Licht beugte sich Mira über das Wappen der Familie von Arnheim."
  @laterne "Draußen wartete Kapitän Wendel mit einer Laterne."

  defp roh(id, claim, refs, figur \\ nil),
    do: %{
      "id" => id,
      "claim" => claim,
      "source_refs" => refs,
      "verified?" => true,
      "character_alias" => figur
    }

  defp eingabe(opts \\ []) do
    uhr = [%{titel: @uhrmacher, kind: "arc"}]
    zuordnung = %{"f_a" => uhr, "f_b" => uhr, "f_c" => uhr, "f_frueh" => uhr}

    fakten =
      Eingabe.fakten(
        [
          roh("f_a", "Die Gruppe steht im Regen vor der Werkstatt am Hafen.", ["b0"]),
          roh("f_b", "Der Alte öffnet, als Tess den Brief zeigt.", ["b1"], "Tess"),
          roh(
            "f_c",
            "Mira erkennt auf der Spieldose das Wappen der Familie von Arnheim.",
            ["b2"],
            "Mira"
          )
        ],
        2,
        zuordnung,
        %{"b0" => 0, "b1" => 1, "b2" => 2}
      )

    frueh =
      Eingabe.fakten(
        [roh("f_frueh", "Tess nimmt den Auftrag im Kontor an.", ["x"], "Tess")],
        1,
        zuordnung,
        nil
      )

    %{
      art: :epos,
      sitzung: %{id: "s2", nummer: 2, name: "Nach Norden"},
      fakten: fakten,
      fruehere: [%{nummer: 1, name: "Die Werkstatt", fakten: frueh}],
      boegen: Eingabe.boegen(fakten, []),
      bloecke: [
        %{text: "Ihr steht im Regen vor der Werkstatt.", sprecher: "SL", block_id: "b0"},
        %{text: "Tess zeigt den Brief.", sprecher: "Tess", block_id: "b1"},
        %{text: "Das Wappen kenne ich.", sprecher: "Mira", block_id: "b2"}
      ],
      cast: ["Mira", "Tess", "Brann"],
      straenge: [@uhrmacher],
      ueberschrift: "Heldenlied",
      flavor: %{base: "Düster.", epos: "Nah an der Gruppe."},
      kapitel:
        Keyword.get(opts, :kapitel, [
          %{
            nummer: 1,
            name: "Die Werkstatt",
            text: "Am Kai verabschiedete sich Kapitän Wendel von der Gruppe."
          },
          # Die bisherige Fassung des Kapitels dieser Sitzung zählt nicht als Anschluss.
          %{nummer: 2, name: "Nach Norden", text: "Die alte Fassung mit Ritter Kunibert."}
        ])
    }
  end

  defp n(a, k, zeile, fakten \\ []),
    do: %{
      "abschnitt" => a,
      "schluessel" => k,
      "zeile" => zeile,
      "fakten" => fakten,
      "boegen" => []
    }

  defp ablage do
    %{
      "notizen" => [
        n("FORM", "Form", "Heldenlied in Szenen, nah an der Gruppe"),
        n("SZENEN", "Regen am Hafen", "Nacht, Regen, vor der Werkstatt", [
          "S2-F1",
          "S2-F2",
          "S1-F1"
        ]),
        n("SZENEN", "Die Spieldose", "im Licht der Lampe", ["S2-F3"]),
        n("OFFEN", "Anschluss", "das vorige Kapitel endet am Kai")
      ]
    }
  end

  # Das Kapitel aus dem Schreiben, als JSON: Absatz 1 trägt, Absatz 2 hat die
  # falsche Figur (Brann statt Mira), Absatz 3 steht ohne Szene.
  defp entwurf_json do
    [
      %{"titel" => "Am Hafen", "text" => @hafen, "szene" => "Regen am Hafen"},
      %{"text" => @falsch, "szene" => "Die Spieldose"},
      %{"text" => @laterne}
    ]
  end

  defp stand(opts \\ []), do: Durchsicht.stand(eingabe(opts), ablage(), entwurf_json())

  defp m(o), do: o |> Jason.encode!() |> Jason.decode!()

  defp h(text, szene, opts \\ []),
    do: Hinweise.absatz(stand(opts), %{titel: nil, text: text, szene: szene})

  defp zeigen(s, nr) do
    {s, {:ok, _}} = Durchsicht.durchsicht(s, %{"nummer" => nr})
    s
  end

  defp bestaetigen(s, nr) do
    {s, {:ok, a}} = Durchsicht.absatz_bestaetigen(zeigen(s, nr), %{"nummer" => nr})
    {s, m(a)}
  end

  defp alle_bestaetigen(s, nrs), do: Enum.reduce(nrs, s, &elem(bestaetigen(&2, &1), 0))

  defp ersetzen(s, nr, text, extra \\ %{}),
    do:
      Durchsicht.absatz_ersetzen(
        s,
        Map.merge(%{"nummer" => nr, "text" => text, "grund" => @grund}, extra)
      )

  defp ersetze_zwei(s),
    do: ersetzen(s, 2, @richtig, %{"szene" => "Die Spieldose"})

  defp fertig(s, bestaetigt, ersetzt),
    do:
      Abschluss.fertig(s, %{
        "bestaetigt" => bestaetigt,
        "ersetzt" => ersetzt,
        "offen_geblieben" => ""
      })

  defp woerter(n), do: 1..n |> Enum.map(fn _ -> "Wort" end) |> Enum.join(" ")

  describe "der Stand der Durchsicht" do
    test "frisch, mit den Notizen und dem Kapitel aus dem Schreiben; jeder Absatz offen" do
      s = stand()

      assert s.art == :epos
      assert s.lauf == :durchsicht
      assert s.gelesen == MapSet.new()
      assert Stand.form(s).zeile == "Heldenlied in Szenen, nah an der Gruppe"

      assert [
               %{titel: "Am Hafen", text: @hafen, szene: "Regen am Hafen"},
               %{titel: nil, text: @falsch, szene: "Die Spieldose"},
               %{titel: nil, text: @laterne, szene: nil}
             ] = s.entwurf

      assert s.durchsicht.durchgang == 1
      assert Buch.offen(s) == [1, 2, 3]
      assert s.durchsicht.ausgang == s.entwurf
    end

    test "entwurf_aus: Atom- und String-Schlüssel, Leerraum zusammengezogen, leere Absätze fallen weg" do
      s = stand()
      assert Entwurf.entwurf_aus(s.entwurf) == s.entwurf

      assert Entwurf.entwurf_aus([
               %{"titel" => "  ", "text" => "  Regen \n am  Hafen. ", "szene" => ""},
               %{"text" => "   "},
               :kein_absatz
             ]) == [%{titel: nil, text: "Regen am Hafen.", szene: nil}]

      assert Entwurf.entwurf_aus(nil) == []
    end
  end

  describe "Hinweise" do
    test "mit Szene: gemessen an den Fakten der Szene — ein Wort aus einer anderen Szene ist ein Hinweis" do
      assert h("Dann sprach der Alte von der Spieldose.", "Regen am Hafen") == ["Spieldose"]
      assert h("Dann sprach der Alte von der Spieldose.", "Die Spieldose") == ["Alte"]
    end

    test "ohne Szene: gemessen an allen Fakten dieser Sitzung" do
      assert h("Dann sprach der Alte von der Spieldose.", nil) == []
      # Eine Szene, die in den Notizen nicht steht, gilt wie keine.
      assert h("Dann sprach der Alte von der Spieldose.", "Der Keller") == []
    end

    test "ein früherer Fakt zählt nur, wenn die Szene ihn nennt" do
      assert h("Damals nahm Tess den Auftrag im Kontor an.", "Regen am Hafen") == []
      assert h("Damals nahm Tess den Auftrag im Kontor an.", nil) == ["Auftrag", "Kontor"]
    end

    test "das vorige Kapitel ist Fundstelle, die bisherige Fassung dieses Kapitels nicht" do
      assert h("Dann winkte Kapitän Wendel.", nil) == []
      assert h("Dann winkte Kapitän Wendel.", nil, kapitel: []) == ["Kapitän", "Wendel"]
      assert h("Dann kam Ritter Kunibert.", nil) == ["Ritter", "Kunibert"]
      assert Hinweise.voriges_kapitel(stand()).nummer == 1
      assert Hinweise.voriges_kapitel(stand(kapitel: [])) == nil
    end

    test "der Cast ist Fundstelle — eine falsche Figur aus dem Cast sieht niemand" do
      assert h("Dann erkennt Brann das Wappen.", "Die Spieldose") == []
    end

    test "am Satzanfang und nach Doppelpunkt kein Hinweis; je Absatz und im ganzen Kapitel" do
      assert h("Wendel lacht.", nil, kapitel: []) == []
      assert h("Der Alte sagt: Wendel lügt.", nil, kapitel: []) == []

      s = stand()

      assert Enum.map(s.entwurf, &Hinweise.absatz(s, &1)) == [
               ["Tür"],
               ["Licht", "Lampe"],
               ["Laterne"]
             ]

      assert Enum.map(s.entwurf, &Hinweise.zahl(s, &1)) == [1, 2, 1]
      assert Hinweise.anzahl(s, s.entwurf) == 4
    end
  end

  describe "durchsicht und absatz_bestaetigen" do
    test "durchsicht(n): Text, Szene mit Fakten im Wortlaut, Kontext davor und danach, Hinweise" do
      {s, {:ok, a}} = Durchsicht.durchsicht(stand(), %{"nummer" => 1})
      a = m(a)

      assert %{"absatz" => 1, "titel" => "Am Hafen", "durchgang" => 1, "status" => "offen"} = a
      assert a["woerter"] == "16 Wörter"
      assert a["text"] == @hafen

      # Vor Absatz 1 steht das Ende des vorigen Kapitels — der Anschluss.
      assert a["davor"] ==
               "Ende des Kapitels von Sitzung 1: Am Kai verabschiedete sich Kapitän Wendel von " <>
                 "der Gruppe."

      assert a["danach"] == "Absatz 2: " <> @falsch

      assert a["szene"] == %{
               "schluessel" => "Regen am Hafen",
               "zeile" => "Nacht, Regen, vor der Werkstatt",
               "fakten" => [
                 "S2-F1 — Die Gruppe steht im Regen vor der Werkstatt am Hafen.",
                 "S2-F2 — Figur: Tess — Der Alte öffnet, als Tess den Brief zeigt.",
                 "S1-F1 — (Sitzung 1) Figur: Tess — Tess nimmt den Auftrag im Kontor an."
               ]
             }

      assert a["hinweise"] == ["Tür"]
      assert a["hinweis"] =~ "absatz_bestaetigen(1)"
      assert a["hinweis"] =~ "klingt er nach deiner FORM"
      assert hd(s.durchsicht.absaetze).gesehen

      {_s, {:ok, a}} = Durchsicht.durchsicht(stand(), %{"nummer" => 3})
      a = m(a)
      assert a["szene"] =~ "ohne Szene"
      assert a["davor"] == "Absatz 2: " <> @falsch
      refute Map.has_key?(a, "danach")
      refute Map.has_key?(a, "titel")
      assert a["hinweise"] == ["Laterne"]

      assert {_s, {:error, t}} = Durchsicht.durchsicht(stand(), %{"nummer" => 4})
      assert t =~ "Das Kapitel hat die Absätze 1 bis 3"
    end

    test "der Kontext ist gekürzt: das Ende davor, der Anfang danach, je 40 Wörter" do
      lang = woerter(39) <> " Ende."

      s =
        Durchsicht.stand(eingabe(), ablage(), [%{"text" => "Eins " <> lang}, %{"text" => "Zwei."}])

      s = %{s | entwurf: s.entwurf ++ [%{titel: "Drei", text: "Anfang " <> lang, szene: nil}]}

      s = %{
        s
        | durchsicht: %{
            s.durchsicht
            | absaetze: s.durchsicht.absaetze ++ [%{status: :offen, gesehen: false}]
          }
      }

      {_s, {:ok, a}} = Durchsicht.durchsicht(s, %{"nummer" => 2})
      a = m(a)
      assert a["davor"] == "Absatz 1: … " <> lang
      assert a["danach"] == "Absatz 3 (Drei): Anfang " <> woerter(39) <> " …"
    end

    test "bestätigen geht erst nach durchsicht(n), und nur einmal je Durchgang" do
      s = stand()

      assert {^s, {:error, t}} = Durchsicht.absatz_bestaetigen(s, %{"nummer" => 1})
      assert t =~ "zuerst mit durchsicht(1)"

      {s, a} = bestaetigen(s, 1)
      assert %{"ok" => true, "bestaetigt" => 1, "durchgang" => 1, "offen" => [2, 3]} = a
      assert a["hinweis"] =~ "Weiter mit Absatz 2: durchsicht(2)."

      assert {^s, {:error, t}} = Durchsicht.absatz_bestaetigen(s, %{"nummer" => 1})
      assert t =~ "hast du in diesem Durchgang bestätigt"

      assert [{"durchsicht.jsonl", %{"art" => "bestaetigt", "absatz" => 1, "durchgang" => 1}}] =
               Stand.journal_liste(s)
    end
  end

  describe "absatz_ersetzen und absatz_streichen" do
    test "ersetzen: dieselbe Prüfung wie absatz im Schreiben, dazu ein Grund — auch stilistisch" do
      s = stand()

      assert {^s, {:error, t}} = ersetzen(s, 2, @richtig, %{"grund" => "  "})
      assert t =~ "grund ist leer"

      # Abgelehnt: unbekannte Szene, zu lang — nichts ändert sich.
      {s2, {:error, a}} = ersetzen(s, 2, woerter(401), %{"szene" => "Der Keller"})
      [lang, szene] = m(a)["gruende"]
      assert lang =~ "Der Absatz hat 401 Wörter"
      assert szene =~ "Eine Szene „Der Keller“ gibt es in deinen Notizen nicht."
      assert s2.entwurf == s.entwurf
      assert Buch.offen(s2) == [1, 2, 3]

      {_s, {:error, t}} = ersetzen(s, 3, @laterne)
      assert t =~ "Absatz 3 steht bereits genau so"

      {s, {:ok, a}} = ersetze_zwei(s)
      a = m(a)

      assert %{"ok" => true, "ersetzt" => 2, "szene" => "Die Spieldose", "offen" => [1, 3]} = a
      assert a["hinweise"] == ["Licht"]
      assert a["hinweis"] =~ "Absatz 2 ersetzt. Im nächsten Durchgang liest du ihn noch einmal"
      assert %{text: @richtig, szene: "Die Spieldose"} = Enum.at(s.entwurf, 1)
      assert %{status: :ersetzt, gesehen: false} = Enum.at(s.durchsicht.absaetze, 1)

      assert {"durchsicht.jsonl", %{"art" => "ersetzt", "absatz" => 2, "grund" => @grund}} =
               List.last(Stand.journal_liste(s))

      # Ersetzt ist in diesem Durchgang entschieden; bestätigt wird im nächsten.
      assert {_s, {:error, t}} = Durchsicht.absatz_bestaetigen(zeigen(s, 2), %{"nummer" => 2})
      assert t =~ "hast du in diesem Durchgang ersetzt"
    end

    test "ersetzen ohne szene: geht durch, die Antwort nennt die verlorene Szene" do
      {s, {:ok, a}} =
        ersetzen(stand(), 1, "Nebel lag über dem Hafen.", %{
          "grund" => "Der Absatz holpert; die neue Fassung liest sich ruhiger."
        })

      assert m(a)["hinweis"] =~
               "Die neue Fassung ist keiner Szene zugeordnet (vorher „Regen am Hafen“)"

      assert %{titel: nil, szene: nil} = hd(s.entwurf)
    end

    test "streichen: mit Grund, die Absätze dahinter rücken auf, der letzte bleibt" do
      s = stand()

      assert {^s, {:error, t}} = Durchsicht.absatz_streichen(s, %{"nummer" => 2, "grund" => " "})
      assert t =~ "grund ist leer"

      {s, _} = bestaetigen(s, 1)

      {s, {:ok, a}} =
        Durchsicht.absatz_streichen(s, %{"nummer" => 2, "grund" => "Das Bild steht doppelt."})

      a = m(a)
      assert %{"gestrichen" => 2, "offen" => [2]} = a
      assert a["hinweis"] =~ "um eins nach vorn gerückt"
      assert Enum.map(s.entwurf, & &1.text) == [@hafen, @laterne]
      assert Enum.map(s.durchsicht.absaetze, & &1.status) == [:bestaetigt, :offen]

      # Nur gestrichen, nichts ersetzt: kein weiterer Durchgang.
      {s, a} = bestaetigen(s, 2)
      assert a["durchgang"] == 1
      assert {_s, {:halt, _}} = fertig(s, 2, 0)

      einer = Durchsicht.stand(eingabe(), ablage(), [hd(entwurf_json())])

      assert {_s, {:error, t}} =
               Durchsicht.absatz_streichen(einer, %{"nummer" => 1, "grund" => "doppelt"})

      assert t =~ "der einzige Absatz"
    end
  end

  describe "Durchgänge und fertig" do
    test "ohne Änderung genügt ein Durchgang" do
      s = alle_bestaetigen(stand(), 1..3)

      assert s.durchsicht.durchgang == 1
      assert {_s, {:halt, a}} = fertig(s, 3, 0)
      assert m(a)["zahlen"] == %{"bestaetigt" => 3, "ersetzt" => 0}
    end

    test "nach einer Ersetzung beginnt ein Durchgang nur mit den ersetzten Absätzen" do
      s = stand()
      {s, {:ok, _}} = ersetze_zwei(s)
      {s, _} = bestaetigen(s, 1)

      assert {_s, {:error, a}} = fertig(s, 1, 1)
      assert [h] = m(a)["offen"]
      assert h =~ "In Durchgang 1 sind diese Absätze noch offen: 3."

      {s, a} = bestaetigen(s, 3)
      assert %{"durchgang" => 2, "offen" => [2]} = a
      assert a["hinweis"] =~ "Durchgang 2 beginnt: lies Absatz 2 noch einmal"
      # Beim Epos darf ein Absatz auch noch einmal ersetzt werden, weil er sich besser liest.
      assert a["hinweis"] =~ "wenn er sich noch nicht gut liest oder ein grober Schnitzer"
      assert Enum.map(s.durchsicht.absaetze, & &1.status) == [:frei, :offen, :frei]

      assert {_s, {:error, t}} = Durchsicht.absatz_bestaetigen(zeigen(s, 1), %{"nummer" => 1})
      assert t =~ "blieb im vorigen Durchgang unverändert"

      {s, a} = bestaetigen(s, 2)
      assert a["hinweis"] =~ "Jeder Absatz ist entschieden. Schließ mit fertig() ab."

      assert {s, {:halt, _}} = fertig(s, 3, 1)

      assert {"abschluss.jsonl",
              %{
                "abschluss" => true,
                "lauf" => "durchsicht",
                "jack" => "epos",
                "durchgaenge" => 2,
                "zahlen" => %{"bestaetigt" => 3, "ersetzt" => 1}
              }} = List.last(Stand.journal_liste(s))
    end

    test "der Text des nächsten Durchgangs beim Resümee bleibt, wie er war" do
      zwei = [%{titel: nil, saetze: []}, %{titel: nil, saetze: []}]

      nach = fn art ->
        s =
          %Stand{art: art, sitzung: %{id: "s", nummer: 1, name: nil}}
          |> Stand.mit_durchsicht(zwei)
          |> Buch.setzen(1, &%{&1 | status: :ersetzt})
          |> Buch.setzen(2, &%{&1 | status: :bestaetigt})

        {_s, text} = Buch.weiter(s)
        text
      end

      assert nach.(:resuemee) =~
               "und bestätige — oder ersetze noch einmal, wenn ein grober Schnitzer geblieben " <>
                 "ist. Alle anderen Absätze sind entschieden."

      assert nach.(:epos) =~
               "und bestätige — oder ersetze noch einmal, wenn er sich noch nicht gut liest " <>
                 "oder ein grober Schnitzer geblieben ist. Alle anderen Absätze sind entschieden."
    end

    test "nach dem dritten Durchgang beginnt keiner mehr" do
      s = alle_bestaetigen(stand(), [1, 3])

      {s, {:ok, _}} = ersetze_zwei(s)
      assert s.durchsicht.durchgang == 2

      {s, {:ok, _}} =
        ersetzen(s, 2, @richtig <> " Die Melodie brach ab.", %{"szene" => "Die Spieldose"})

      assert s.durchsicht.durchgang == 3

      {s, {:ok, a}} = ersetze_zwei(s)
      a = m(a)

      assert a["durchgang"] == 3
      assert a["hinweis"] =~ "Das ist der letzte Durchgang"
      assert a["hinweis"] =~ "Das war der 3. Durchgang"
      assert Buch.offen(s) == []
      assert {_s, {:halt, _}} = fertig(s, 2, 3)
    end

    test "falsche Zahlen: die Ablehnung verrät die richtigen nicht, der dritte Versuch geht durch" do
      s = alle_bestaetigen(stand(), 1..3)

      {s, {:error, a}} = fertig(s, 2, 0)

      assert m(a)["abweichung"] == [
               "bestaetigt: du sagst 2 — das stimmt nicht mit der Buchhaltung überein"
             ]

      refute Jason.encode!(a) =~ "3"

      {s, {:error, _}} = fertig(s, 2, 0)
      {s, {:halt, a}} = fertig(s, 2, 0)
      assert m(a)["zahlen"] == %{"bestaetigt" => 3, "ersetzt" => 0}

      assert {"abschluss.jsonl", %{"zahlen_stimmten" => "nein", "abweichung" => [abw]} = e} =
               List.last(Stand.journal_liste(s))

      assert abw == "bestaetigt: du sagst 2, gezaehlt sind 3"
      assert e["woerter"] == Entwurf.woerter(s)
      assert e["hinweise"] == 4
    end
  end

  describe "Werkzeuge, Halter, Abbild und Zusammenfassung" do
    test "der Werkzeugsatz: Lesen, resuemee, notizen_lesen, entwurf, die Durchsicht, fertig" do
      assert Werkzeuge.namen(stand()) ==
               Worker.Jack.Resuemee.Werkzeuge.lesend() ++
                 ~w(resuemee notizen_lesen entwurf durchsicht absatz_bestaetigen absatz_ersetzen
                    absatz_streichen fertig)
    end

    test "streng angelegt: Pflichtfelder, grund ist Pflicht, titel und szene optional" do
      {:ok, h} = Halter.start_link(stand())
      by = h |> Werkzeuge.fuer() |> Map.new(&{&1.name, &1})

      refute Map.has_key?(by, "absatz")
      refute Map.has_key?(by, "notiz")

      assert by["durchsicht"].parameter["required"] == ["nummer"]
      assert by["durchsicht"].wiederholung == :bis_aenderung
      assert by["absatz_bestaetigen"].parameter["required"] == ["nummer"]
      assert by["absatz_bestaetigen"].aendert_bestand
      assert Enum.sort(by["absatz_ersetzen"].parameter["required"]) == ~w(grund nummer text)

      assert Enum.sort(Map.keys(by["absatz_ersetzen"].parameter["properties"])) ==
               ~w(grund nummer szene text titel)

      assert Enum.sort(by["absatz_streichen"].parameter["required"]) == ~w(grund nummer)

      assert Enum.sort(by["fertig"].parameter["required"]) ==
               ~w(bestaetigt ersetzt offen_geblieben)

      assert by["entwurf"].wiederholung == :frei
      assert by["resuemee"].beschreibung =~ "Zum Nachlesen"
      assert by["notizen_lesen"].beschreibung =~ "wo die Durchsicht steht"
      assert by["boegen"].beschreibung =~ "Zum Nachschlagen"
      assert by["absatz_ersetzen"].beschreibung =~ "Lesefluss, Rhythmus, eine Wiederholung"

      assert {:error, fehler} =
               Schema.pruefen(by["absatz_ersetzen"].parameter, %{
                 "nummer" => 1,
                 "grund" => "",
                 "text" => "x"
               })

      assert Enum.any?(fehler, &(&1 =~ "grund"))

      # Über den Halter: gelesen, bestätigt, im Stand.
      assert {:ok, _} = by["durchsicht"].ausfuehren.(%{"nummer" => 1})
      assert {:ok, _} = by["absatz_bestaetigen"].ausfuehren.(%{"nummer" => 1})
      assert Buch.offen(Halter.stand(h)) == [2, 3]
      Agent.stop(h)
    end

    test "das Abbild trägt Kapitel und Durchsicht — in der Form, aus der der Melder zählt" do
      a = Notizen.abbild(zeigen(stand(), 1))

      assert %{
               "jack" => "epos",
               "lauf" => "durchsicht",
               "entwurf" => %{"absaetze" => 3, "mit_szene" => 2},
               "durchsicht" => %{
                 "durchgang" => 1,
                 "offen" => [1, 2, 3],
                 "status" => ["offen", "offen", "offen"],
                 "bestaetigt" => 0,
                 "ersetzt" => 0,
                 "gestrichen" => 0,
                 "hinweise" => 4
               }
             } = a

      assert is_binary(Jason.encode!(a))
      assert Melder.zaehlung(a) == {3, 1, []}

      {s, _} = bestaetigen(stand(), 2)
      assert Melder.zaehlung(Notizen.abbild(s)) == {3, 1, [2]}
    end

    test "notizen_lesen zeigt die Übersicht der Durchsicht" do
      {_s, {:ok, a}} = Notizen.notizen_lesen(stand(), %{})
      st = m(a)["stand"]

      assert st =~ "Sitzung 2. Die Epos-Spalte heißt „Heldenlied“."

      assert st =~
               "Kapitel: 3 Absätze, 37 Wörter. Je Absatz: Absatz 1: 16 Wörter, Absatz 2: " <>
                 "14 Wörter, Absatz 3: 7 Wörter."

      assert st =~
               "Durchsicht: Durchgang 1 von höchstens 3. Bisher bestätigt 0, ersetzt 0, gestrichen 0."

      assert st =~ "Offen in diesem Durchgang: 1, 2, 3."
      assert st =~ "Absätze: 1 offen (1 Hinweis) · 2 offen (2 Hinweise) · 3 offen (1 Hinweis)"
    end

    test "die Zusammenfassung trägt Auftrag, Stil mit FORM, Stand, Notizen gekürzt, Kapitel und nächsten Schritt" do
      t = Zusammenfassung.text(stand())

      assert t =~ "Du siehst das Epos-Kapitel von Sitzung 2 für die Spalte"
      assert t =~ "Gut zu lesen hat Vorrang"
      assert t =~ "## Stil\nÜberschrift der Epos-Spalte: „Heldenlied“"
      assert t =~ "**Ton des Epos:** Nah an der Gruppe.\n\nFORM: Heldenlied in Szenen"
      assert t =~ "Durchgang 1 von höchstens 3"

      # Die Notizen gekürzt: Schlüssel und Zeile, ohne die Fakten.
      assert t =~ "### SZENEN\nRegen am Hafen — Nacht, Regen, vor der Werkstatt\nDie Spieldose"
      refute t =~ "[Fakten:"

      assert t =~ "## Dein Kapitel (gekürzt; vollständig mit entwurf())\n1. — Am Hafen · Szene"
      assert t =~ "## Nächster Schritt\nWeiter mit Absatz 1: durchsicht(1)."
      assert Zusammenfassung.text(zeigen(stand(), 1)) =~ "Absatz 1 ist offen und gelesen"
    end
  end

  describe "Ergebnis nach der Durchsicht" do
    test "Markdown und Quellen aus dem durchgesehenen Kapitel, Zählwerte mit der Durchsicht" do
      s = stand()
      {s, {:ok, _}} = ersetze_zwei(s)
      {s, _} = bestaetigen(s, 1)

      {s, {:ok, _}} =
        Durchsicht.absatz_streichen(s, %{"nummer" => 3, "grund" => "Das Bild trägt nicht."})

      assert s.durchsicht.durchgang == 2
      {s, _} = bestaetigen(s, 2)

      assert Ergebnis.markdown(s) == "**Am Hafen**\n" <> @hafen <> "\n\n" <> @richtig

      assert [
               %{szene: "Regen am Hafen", fakt_ids: ["f_a", "f_b", "f_frueh"]},
               %{fakt_ids: ["f_c"]}
             ] =
               Ergebnis.quellen(s)

      z = Ergebnis.zaehlwerte(s)
      assert z["absaetze"] == 2

      assert z["durchsicht"] == %{
               "durchgaenge" => 2,
               "bestaetigt" => 2,
               "ersetzt" => 1,
               "gestrichen" => 1,
               "ersetzungen" => [%{"durchgang" => 1, "absatz" => 2, "grund" => @grund}],
               "streichungen" => [
                 %{"durchgang" => 1, "absatz" => 3, "grund" => "Das Bild trägt nicht."}
               ],
               "hinweise_vorher" => 4,
               "hinweise_nachher" => 2
             }

      assert is_binary(Jason.encode!(z))

      # Ohne Durchsicht bleiben die Zählwerte, wie sie waren.
      refute Map.has_key?(
               Ergebnis.zaehlwerte(Stand.fuer_schreiben(eingabe(), ablage())),
               "durchsicht"
             )
    end
  end
end
