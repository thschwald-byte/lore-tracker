defmodule Worker.Jack.Resuemee.DurchsichtTest do
  # J5 (#1209, B3): die Durchsicht, rein auf dem Stand — kein Mnesia, kein
  # Modell. Beispiele aus der Demo-Welt (Werkstatt am Hafen).
  use ExUnit.Case, async: true

  alias Worker.Agent.Schema

  alias Worker.Jack.Resuemee.{
    Abschluss,
    Durchsicht,
    Eingabe,
    Entwurf,
    Ergebnis,
    Halter,
    Hinweise,
    Lesen,
    Notizen,
    Stand,
    Werkzeuge,
    Zusammenfassung
  }

  @uhrmacher "Der verschwundene Uhrmacher"
  @arnheim "Die Familie von Arnheim"
  @salz "Die Salzmine"
  @grund "Satz 2 lässt Brann handeln, der Fakt S2-F3 nennt Mira."

  defp roh(id, claim, refs, figur \\ nil),
    do: %{
      "id" => id,
      "claim" => claim,
      "source_refs" => refs,
      "verified?" => true,
      "character_alias" => figur
    }

  defp eingabe do
    uhr = [%{titel: @uhrmacher, kind: "arc"}]

    zuordnung = %{
      "f_a" => uhr,
      "f_b" => uhr,
      "f_c" => [%{titel: @arnheim, kind: "context"}],
      "f_d" => [%{titel: @salz, kind: "arc"}],
      "f_frueh" => uhr
    }

    fakten =
      Eingabe.fakten(
        [
          roh("f_a", "Der Alte zeigt der Gruppe eine Spieldose mit einem Wappen.", ["b0"]),
          roh("f_b", "Die Spieldose gehörte dem Uhrmacher.", ["b1"]),
          roh("f_c", "Mira erkennt das Wappen der Familie von Arnheim.", ["b2"], "Mira"),
          roh("f_d", "Die Gruppe erreicht das Dorf an den Salzminen.", ["b3"])
        ],
        2,
        zuordnung,
        %{"b0" => 0, "b1" => 1, "b2" => 2, "b3" => 3}
      )

    frueh =
      Eingabe.fakten(
        [roh("f_frueh", "Tess nimmt den Auftrag an, den Uhrmacher zu finden.", ["x"], "Tess")],
        1,
        zuordnung,
        nil
      )

    %{
      sitzung: %{id: "s2", nummer: 2, name: "Nach Norden"},
      fakten: fakten,
      fruehere: [%{nummer: 1, name: "Die Werkstatt", fakten: frueh}],
      boegen: Eingabe.boegen(fakten, []),
      bloecke: [
        %{text: "Der Alte zeigt euch eine Spieldose.", sprecher: "SL", block_id: "b0"},
        %{text: "Die gehörte dem Uhrmacher.", sprecher: "SL", block_id: "b1"},
        %{text: "Das Wappen kenne ich.", sprecher: "Mira", block_id: "b2"},
        %{text: "Ihr erreicht das Dorf an den Salzminen.", sprecher: "SL", block_id: "b3"}
      ],
      cast: ["Mira", "Tess", "Brann"],
      straenge: [@uhrmacher, @arnheim, @salz],
      ueberschrift: "Rückblick",
      flavor: %{base: "Düster.", summary: nil}
    }
  end

  defp ablage do
    %{
      "notizen" => [
        %{
          "abschnitt" => "FORM",
          "schluessel" => "Form",
          "zeile" => "chronologische Nacherzählung",
          "fakten" => [],
          "boegen" => []
        }
      ]
    }
  end

  defp js(text, fakten, extra \\ %{}), do: Map.merge(%{"text" => text, "fakten" => fakten}, extra)

  # Der Entwurf aus dem Schreiben, als JSON: Absatz 1 hat die falsche Figur
  # (Brann statt Mira), Absatz 2 einen Übergang und einen Satz mit Namen
  # ohne Fundstelle, Absatz 3 ist sauber.
  defp entwurf_json do
    [
      %{
        "titel" => "In der Werkstatt",
        "saetze" => [
          js("Der Alte zeigt der Gruppe eine Spieldose.", ["S2-F1"]),
          js("Brann erkennt das Wappen der Familie von Arnheim.", ["S2-F3"])
        ]
      },
      %{
        "titel" => nil,
        "saetze" => [
          js("Danach zieht es sie nach Norden.", [], %{"uebergang" => true}),
          js("Im Wirtshaus trifft die Gruppe Kapitän Wendel.", ["S2-F4"])
        ]
      },
      %{
        "titel" => "Das Dorf",
        "saetze" => [js("Die Gruppe erreicht das Dorf an den Salzminen.", ["S2-F4"])]
      }
    ]
  end

  defp stand, do: Stand.fuer_durchsicht(eingabe(), ablage(), entwurf_json())

  defp m(o), do: o |> Jason.encode!() |> Jason.decode!()

  defp richtig,
    do: [
      js("Der Alte zeigt der Gruppe eine Spieldose.", ["S2-F1"]),
      js("Mira erkennt das Wappen der Familie von Arnheim.", ["S2-F3"])
    ]

  defp ersetzen(s, nr, saetze, grund \\ @grund),
    do:
      Durchsicht.absatz_ersetzen(s, %{
        "nummer" => nr,
        "titel" => "In der Werkstatt",
        "grund" => grund,
        "saetze" => saetze
      })

  defp zeigen(s, nr) do
    {s, {:ok, _}} = Durchsicht.durchsicht(s, %{"nummer" => nr})
    s
  end

  defp bestaetigen(s, nr) do
    {s, {:ok, a}} = Durchsicht.absatz_bestaetigen(zeigen(s, nr), %{"nummer" => nr})
    {s, m(a)}
  end

  defp alle_bestaetigen(s, nrs), do: Enum.reduce(nrs, s, &elem(bestaetigen(&2, &1), 0))

  defp fertig(s, bestaetigt, ersetzt),
    do:
      Abschluss.fertig(s, %{
        "bestaetigt" => bestaetigt,
        "ersetzt" => ersetzt,
        "offen_geblieben" => ""
      })

  defp satz(text, fakten, extra),
    do: Map.merge(%{text: text, fakten: fakten, uebergang: false, rueckblick: false}, extra)

  defp h(text, fakten, extra \\ %{}), do: Hinweise.satz(stand(), satz(text, fakten, extra))

  describe "der Stand der Durchsicht" do
    test "frisch, mit Notizen und dem Entwurf aus dem Schreiben; jeder Absatz offen" do
      s = stand()

      assert s.lauf == :durchsicht
      assert s.gelesen == MapSet.new()
      assert Stand.form(s).zeile == "chronologische Nacherzählung"

      assert [
               %{
                 titel: "In der Werkstatt",
                 saetze: [%{fakten: ["S2-F1"], uebergang: false, rueckblick: false}, _]
               },
               %{titel: nil, saetze: [%{uebergang: true, fakten: []}, _]},
               %{titel: "Das Dorf"}
             ] = s.entwurf

      assert s.durchsicht.durchgang == 1
      assert Durchsicht.offen(s) == [1, 2, 3]
      assert s.durchsicht.ausgang == s.entwurf

      # Atom- und String-Schlüssel ergeben denselben Entwurf.
      assert Stand.entwurf_aus(s.entwurf) == s.entwurf
      assert Stand.entwurf_aus(nil) == []
    end
  end

  describe "Hinweise" do
    test "ein Wort ohne Fundstelle ist ein Hinweis — am Satzanfang und nach Doppelpunkt nicht" do
      assert h("Dann lacht Wendel.", ["S2-F1"]) == ["Wendel"]
      assert h("Wendel lacht.", ["S2-F1"]) == []
      assert h("Der Alte sagt: Wendel lügt.", ["S2-F1"]) == []
      assert h("Der Alte sagt „Wendel lügt“ und geht.", ["S2-F1"]) == []
      assert h("Der Alte bittet Sie herein. Dann geht er.", ["S2-F1"]) == []
      assert h("Dann ruft Wendel, und Wendel lacht.", ["S2-F1"]) == ["Wendel"]
    end

    test "Fundstelle heißt Wortteil: Stamm ohne Endung, auch in Bogentiteln" do
      assert h("Sie sprechen über Uhrmachers Spieldosen.", ["S2-F2"]) == []
      # „Uhrmachers“ steht im Bogentitel, „Spieldosen“ in keiner Fundstelle.
      assert h("Sie sprechen über Uhrmachers Spieldosen.", ["S2-F4"]) == ["Spieldosen"]
      assert h("Dann spricht der Alte über die Familie.", ["S2-F1"]) == []
    end

    test "ein kurzer Stamm muss als ganzes Wort dastehen" do
      assert h("Dann tickt die Uhr.", ["S2-F2"]) == ["Uhr"]
      assert h("Dann tickt der Uhrmacher.", ["S2-F2"]) == []
    end

    test "ein Wort mit Bindestrich braucht eine Fundstelle für jeden Teil" do
      assert h("Dann zeigt er das Arnheim-Wappen.", ["S2-F3"]) == []
      assert h("Dann zeigt er das Arnheim-Siegel.", ["S2-F3"]) == ["Arnheim-Siegel"]
    end

    test "der Cast zählt als Fundstelle — eine falsche Figur aus dem Cast sieht niemand" do
      assert h("Dann trifft der Alte Tess.", ["S2-F1"]) == []
      assert h("Dann erkennt Brann das Wappen.", ["S2-F3"]) == []
    end

    test "ein Übergang hat keine Fundstelle, auch nicht im Cast" do
      assert h("Danach zieht es sie nach Norden zu Mira.", [], %{uebergang: true}) ==
               ["Norden", "Mira"]

      assert h("Danach geht es weiter.", [], %{uebergang: true}) == []
    end

    test "ein Rückblick sucht in seinen früheren Fakten" do
      assert h("Damals nahm Tess den Auftrag an.", ["S1-F1"], %{rueckblick: true}) == []

      assert h("Damals nahm Tess den Schlüssel an.", ["S1-F1"], %{rueckblick: true}) ==
               ["Schlüssel"]
    end

    test "je Absatz und im ganzen Entwurf" do
      s = stand()

      assert Hinweise.absatz(s, Enum.at(s.entwurf, 1)) ==
               [["Norden"], ["Wirtshaus", "Kapitän", "Wendel"]]

      assert Enum.map(s.entwurf, &Hinweise.zahl(s, &1)) == [0, 4, 0]
      assert Hinweise.anzahl(s, s.entwurf) == 4
    end
  end

  describe "durchsicht und absatz_bestaetigen" do
    test "durchsicht(n) zeigt jeden Satz mit seinen Fakten im Wortlaut und den Hinweisen" do
      {s, {:ok, a}} = Durchsicht.durchsicht(stand(), %{"nummer" => 1})
      a = m(a)

      assert %{"absatz" => 1, "titel" => "In der Werkstatt", "durchgang" => 1} = a
      assert a["status"] == "offen"

      assert [s1, s2] = a["saetze"]

      assert s1 == %{
               "satz" => 1,
               "text" => "Der Alte zeigt der Gruppe eine Spieldose.",
               "fakten" => ["S2-F1 — Der Alte zeigt der Gruppe eine Spieldose mit einem Wappen."]
             }

      assert s2["fakten"] == [
               "S2-F3 — Figur: Mira — Mira erkennt das Wappen der Familie von Arnheim."
             ]

      assert a["hinweis"] =~ "absatz_bestaetigen(1)"
      assert hd(s.durchsicht.absaetze).gesehen

      {_s, {:ok, a}} = Durchsicht.durchsicht(stand(), %{"nummer" => 2})

      assert [
               %{"art" => "Übergang", "hinweise" => ["Norden"]} = ue,
               %{"hinweise" => ["Wirtshaus", "Kapitän", "Wendel"]}
             ] = m(a)["saetze"]

      refute Map.has_key?(ue, "fakten")

      assert {_s, {:error, t}} = Durchsicht.durchsicht(stand(), %{"nummer" => 4})
      assert t =~ "Absätze 1 bis 3"
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
    test "ersetzen: dieselbe Prüfung wie im Schreiben, dazu ein Grund" do
      s = stand()

      assert {^s, {:error, t}} = ersetzen(s, 1, richtig(), "  ")
      assert t =~ "grund ist leer"

      # Abgelehnt: nichts ändert sich, die Antwort nennt den Satz.
      {s2, {:error, a}} = ersetzen(s, 1, [js("x", ["S2-F9"])])
      assert s2.entwurf == s.entwurf
      assert Durchsicht.offen(s2) == [1, 2, 3]
      assert [%{"satz" => 1}] = m(a)["abgelehnt"]

      {s, {:ok, a}} = ersetzen(s, 1, richtig() ++ [js("Dann ruft Wendel.", ["S2-F1"])])
      a = m(a)

      assert %{"ok" => true, "ersetzt" => 1, "durchgang" => 1, "offen" => [2, 3]} = a
      assert a["hinweise"] == [%{"satz" => 3, "hinweise" => ["Wendel"]}]
      assert a["hinweis"] =~ "Im nächsten Durchgang liest du ihn noch einmal"

      assert Enum.at(hd(s.entwurf).saetze, 1).text ==
               "Mira erkennt das Wappen der Familie von Arnheim."

      assert %{status: :ersetzt, gesehen: false} = hd(s.durchsicht.absaetze)

      assert {"durchsicht.jsonl", %{"art" => "ersetzt", "absatz" => 1, "grund" => @grund}} =
               List.last(Stand.journal_liste(s))

      # Ersetzt ist in diesem Durchgang entschieden; bestätigt wird im nächsten.
      assert {_s, {:error, t}} = Durchsicht.absatz_bestaetigen(zeigen(s, 1), %{"nummer" => 1})
      assert t =~ "hast du in diesem Durchgang ersetzt"
    end

    test "streichen: mit Grund, die Absätze dahinter rücken auf, der letzte bleibt" do
      s = stand()

      assert {^s, {:error, t}} =
               Durchsicht.absatz_streichen(s, %{"nummer" => 2, "grund" => " "})

      assert t =~ "grund ist leer"

      {s, _} = bestaetigen(s, 1)

      {s, {:ok, a}} =
        Durchsicht.absatz_streichen(s, %{"nummer" => 2, "grund" => "Der Absatz steht doppelt."})

      a = m(a)
      assert %{"gestrichen" => 2, "offen" => [2]} = a
      assert a["hinweis"] =~ "um eins nach vorn gerückt"
      assert length(s.entwurf) == 2
      assert Enum.map(s.durchsicht.absaetze, & &1.status) == [:bestaetigt, :offen]

      # Nur gestrichen, nichts ersetzt: kein weiterer Durchgang.
      {s, a} = bestaetigen(s, 2)
      assert a["durchgang"] == 1
      assert {_s, {:halt, _}} = fertig(s, 2, 0)

      einer = Stand.fuer_durchsicht(eingabe(), ablage(), [hd(entwurf_json())])

      assert {_s, {:error, t}} =
               Durchsicht.absatz_streichen(einer, %{"nummer" => 1, "grund" => "doppelt"})

      assert t =~ "der einzige Absatz"
    end
  end

  describe "Durchgänge und fertig" do
    test "ohne Änderung genügt ein Durchgang" do
      s = alle_bestaetigen(stand(), 1..3)

      assert s.durchsicht.durchgang == 1
      assert Durchsicht.offen(s) == []
      assert {_s, {:halt, a}} = fertig(s, 3, 0)
      assert m(a)["zahlen"] == %{"bestaetigt" => 3, "ersetzt" => 0}
    end

    test "nach einer Ersetzung beginnt ein Durchgang nur mit den ersetzten Absätzen" do
      s = stand()
      {s, {:ok, _}} = ersetzen(s, 1, richtig())
      {s, _} = bestaetigen(s, 2)

      assert {_s, {:error, a}} = fertig(s, 1, 1)
      assert [h] = m(a)["offen"]
      assert h =~ "In Durchgang 1 sind diese Absätze noch offen: 3."

      {s, a} = bestaetigen(s, 3)
      assert %{"durchgang" => 2, "offen" => [1]} = a
      assert a["hinweis"] =~ "Durchgang 1 ist durch"
      assert a["hinweis"] =~ "Durchgang 2 beginnt: lies Absatz 1 noch einmal"
      assert Enum.map(s.durchsicht.absaetze, & &1.status) == [:offen, :frei, :frei]

      # Ein unveränderter Absatz ist in Durchgang 2 nicht zu prüfen.
      assert {_s, {:error, t}} = Durchsicht.absatz_bestaetigen(zeigen(s, 2), %{"nummer" => 2})
      assert t =~ "blieb im vorigen Durchgang unverändert"

      {s, a} = bestaetigen(s, 1)
      assert a["durchgang"] == 2
      refute Map.has_key?(a, "offen")
      assert a["hinweis"] =~ "Jeder Absatz ist entschieden. Schließ mit fertig() ab."

      assert {s, {:halt, _}} = fertig(s, 3, 1)

      assert {"abschluss.jsonl",
              %{
                "abschluss" => true,
                "lauf" => "durchsicht",
                "durchgaenge" => 2,
                "zahlen" => %{"bestaetigt" => 3, "ersetzt" => 1}
              }} = List.last(Stand.journal_liste(s))
    end

    test "nach dem dritten Durchgang beginnt keiner mehr" do
      s = alle_bestaetigen(stand(), 2..3)

      {s, {:ok, _}} = ersetzen(s, 1, richtig())
      assert s.durchsicht.durchgang == 2

      {s, {:ok, _}} = ersetzen(s, 1, richtig() ++ [js("Dann geht der Alte.", ["S2-F1"])])
      assert s.durchsicht.durchgang == 3

      {s, {:ok, a}} = ersetzen(s, 1, richtig())
      a = m(a)

      assert a["durchgang"] == 3
      assert a["hinweis"] =~ "Das ist der letzte Durchgang"
      assert a["hinweis"] =~ "Das war der 3. Durchgang"
      assert Durchsicht.offen(s) == []
      assert Durchsicht.max_durchgaenge() == 3
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

      assert {"abschluss.jsonl", %{"zahlen_stimmten" => "nein", "abweichung" => [abw]}} =
               List.last(Stand.journal_liste(s))

      assert abw == "bestaetigt: du sagst 2, gezaehlt sind 3"
    end
  end

  describe "Werkzeuge, Halter, Stand und Zusammenfassung in der Durchsicht" do
    test "der Werkzeugsatz: Lesen, notizen_lesen, entwurf, die Durchsicht, fertig — kein absatz" do
      assert Werkzeuge.namen(stand()) ==
               ~w(fakten fakt boegen vorige_resuemees vorige_gedanken bloecke block suche cast
                  straenge notizen_lesen entwurf durchsicht absatz_bestaetigen absatz_ersetzen
                  absatz_streichen fertig)
    end

    test "streng angelegt: Pflichtfelder, der Grund ist Pflicht" do
      {:ok, h} = Halter.start_link(stand())
      by = h |> Werkzeuge.fuer() |> Map.new(&{&1.name, &1})

      refute Map.has_key?(by, "absatz")
      refute Map.has_key?(by, "notiz")

      assert by["durchsicht"].parameter["required"] == ["nummer"]
      assert by["durchsicht"].wiederholung == :bis_aenderung
      assert by["absatz_bestaetigen"].parameter["required"] == ["nummer"]
      assert by["absatz_bestaetigen"].aendert_bestand
      assert by["absatz_ersetzen"].parameter["required"] == ~w(grund nummer saetze)

      assert by["absatz_ersetzen"].parameter["properties"]["saetze"]["items"]["required"] ==
               ~w(fakten text)

      assert by["absatz_streichen"].parameter["required"] == ~w(grund nummer)
      assert by["fertig"].parameter["required"] == ~w(bestaetigt ersetzt offen_geblieben)
      assert by["entwurf"].wiederholung == :frei

      assert {:error, [f]} =
               Schema.pruefen(by["absatz_ersetzen"].parameter, %{
                 "nummer" => 1,
                 "grund" => "",
                 "saetze" => [js("x", ["S2-F1"])]
               })

      assert f =~ "grund: mindestens 1"

      # Über den Halter: gelesen, bestätigt, im Stand.
      assert {:ok, _} = by["durchsicht"].ausfuehren.(%{"nummer" => 1})
      assert {:ok, _} = by["absatz_bestaetigen"].ausfuehren.(%{"nummer" => 1})
      assert Durchsicht.offen(Halter.stand(h)) == [2, 3]
      Agent.stop(h)
    end

    test "der Halter meldet die Durchsicht" do
      {:ok, h} = Halter.start_link(stand(), beobachter: self())

      assert_receive {:jack_resuemee_stand,
                      %{
                        "lauf" => "durchsicht",
                        "entwurf" => %{"absaetze" => 3},
                        "durchsicht" => d
                      }}

      assert d == %{
               "durchgang" => 1,
               "offen" => [1, 2, 3],
               "status" => ["offen", "offen", "offen"],
               "bestaetigt" => 0,
               "ersetzt" => 0,
               "gestrichen" => 0,
               "hinweise" => 4
             }

      Agent.stop(h)
    end

    test "notizen_lesen zeigt die Übersicht; entwurf() und boegen() drängen nicht zum Nachschreiben" do
      s = stand()
      {_s, {:ok, a}} = Notizen.notizen_lesen(s, %{})
      st = m(a)["stand"]

      assert st =~
               "Durchsicht: Durchgang 1 von höchstens 3. Bisher bestätigt 0, ersetzt 0, gestrichen 0."

      assert st =~ "Offen in diesem Durchgang: 1, 2, 3."
      assert st =~ "Absätze: 1 offen · 2 offen (4 Hinweise) · 3 offen"

      defs = Map.new(Notizen.werkzeuge(s), &{&1.name, &1})
      assert defs["notizen_lesen"].beschreibung =~ "wo die Durchsicht steht"

      # Ein Handlungsbogen ohne Satz: im Schreiben genannt, in der Durchsicht nicht.
      einer = Stand.fuer_durchsicht(eingabe(), ablage(), [hd(entwurf_json())])
      refute Entwurf.entwurf_text(einer) =~ "Handlungsbögen"

      assert Entwurf.entwurf_text(%{einer | lauf: :schreiben}) =~
               "Handlungsbögen, von denen noch kein Satz"

      {_s, {:ok, t}} = Lesen.boegen(s, %{})
      refute t =~ "GLIEDERUNG"
      refute t =~ "ausgelassen"
    end

    test "die Zusammenfassung trägt Ton, Stand der Durchsicht und den nächsten Schritt" do
      s = stand()
      t = Zusammenfassung.text(s)

      assert t =~ "## Ton\n**Grundton der Kampagne:** Düster."
      assert t =~ "gnädig"
      assert t =~ "Durchgang 1 von höchstens 3"
      assert t =~ "## Nächster Schritt\nWeiter mit Absatz 1: durchsicht(1)."
      assert Zusammenfassung.text(zeigen(s, 1)) =~ "Absatz 1 ist offen und gelesen"
    end
  end

  describe "Ergebnis nach der Durchsicht" do
    test "markdown und satzquellen aus dem durchgesehenen Entwurf, zaehlwerte mit der Durchsicht" do
      s = stand()
      {s, {:ok, _}} = ersetzen(s, 1, richtig())
      {s, _} = bestaetigen(s, 2)

      {s, {:ok, _}} =
        Durchsicht.absatz_streichen(s, %{
          "nummer" => 3,
          "grund" => "Der Absatz wiederholt die Reise."
        })

      assert s.durchsicht.durchgang == 2
      {s, _} = bestaetigen(s, 1)

      assert Ergebnis.markdown(s) ==
               "**In der Werkstatt**\nDer Alte zeigt der Gruppe eine Spieldose. Mira erkennt " <>
                 "das Wappen der Familie von Arnheim.\n\nDanach zieht es sie nach Norden. Im " <>
                 "Wirtshaus trifft die Gruppe Kapitän Wendel."

      assert [%{fakt_ids: ["f_a"]}, %{fakt_ids: ["f_c"]} | _] = Ergebnis.satzquellen(s)

      z = Ergebnis.zaehlwerte(s)
      assert z["absaetze"] == 2

      assert z["durchsicht"] == %{
               "durchgaenge" => 2,
               "bestaetigt" => 2,
               "ersetzt" => 1,
               "gestrichen" => 1,
               "ersetzungen" => [%{"durchgang" => 1, "absatz" => 1, "grund" => @grund}],
               "streichungen" => [
                 %{"durchgang" => 1, "absatz" => 3, "grund" => "Der Absatz wiederholt die Reise."}
               ],
               "hinweise_vorher" => 4,
               "hinweise_nachher" => 4
             }

      # Ohne Durchsicht bleiben die Zählwerte, wie sie waren.
      refute Map.has_key?(
               Ergebnis.zaehlwerte(Stand.fuer_schreiben(eingabe(), ablage())),
               "durchsicht"
             )
    end
  end
end
