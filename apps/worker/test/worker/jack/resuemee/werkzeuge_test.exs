defmodule Worker.Jack.Resuemee.WerkzeugeTest do
  # J5 (#1209, B1): die Werkzeuge des Überblicks, rein auf dem Stand — kein
  # Mnesia, kein Modell. Beispiele aus der Demo-Welt (Werkstatt am Hafen).
  use ExUnit.Case, async: true

  alias Worker.Jack.Resuemee.{
    Abschluss,
    Eingabe,
    Halter,
    Lesen,
    Notizen,
    Stand,
    Weg,
    Werkzeuge,
    Zusammenfassung
  }

  @uhrmacher "Der verschwundene Uhrmacher"
  @arnheim "Die Familie von Arnheim"
  @keine_frueheren "Es gibt keine früheren Sitzungen — mit dieser Sitzung beginnt die Aufzeichnung."

  @bloecke [
    %{
      text: "Ihr steht im Regen vor der alten Werkstatt am Hafen.",
      sprecher: "SL",
      block_id: "b0"
    },
    %{text: "Ich klopfe zweimal an die Tür und warte.", sprecher: "Mira", block_id: "b1"},
    %{
      text: "Der Alte zeigt euch eine Spieldose mit einem Wappen.",
      sprecher: "SL",
      block_id: "b2"
    },
    %{
      text: "Das Wappen kenne ich, das gehört der Familie von Arnheim.",
      sprecher: "Mira",
      block_id: "b3"
    },
    %{
      text: "Nach zwei Tagen erreicht ihr das Dorf am Rand der Salzminen.",
      sprecher: "SL",
      block_id: "b4"
    }
  ]

  defp roh(id, claim, refs, extra \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "claim" => claim,
        "character_alias" => nil,
        "fact_type" => "ereignis",
        "source_refs" => refs,
        "narration_time" => "present",
        "verified?" => true
      },
      extra
    )
  end

  defp roh_diese do
    [
      roh("f_a", "Die Gruppe steht vor der Werkstatt am Hafen.", ["b0"]),
      roh("f_b", "Mira klopft an die Tür.", ["b1"], %{"character_alias" => "Mira"}),
      roh("f_c", "Der Alte zeigt eine Spieldose mit einem Wappen.", ["b2"], %{
        "in_game_date" => "im Herbst",
        "narration_time" => "flashback"
      }),
      roh("f_d", "Mira erkennt das Wappen der Familie von Arnheim.", ["b3"], %{
        "character_alias" => "Mira"
      }),
      roh("f_e", "Die Gruppe erreicht das Dorf an den Salzminen.", ["b4", "b9"])
    ]
  end

  defp zuordnung do
    arc = [%{titel: @uhrmacher, kind: "arc"}]

    %{
      "f_a" => arc,
      "f_c" => arc,
      "f_d" => [%{titel: @arnheim, kind: "context"}],
      "f_e" => arc,
      "f_frueh" => arc
    }
  end

  defp threads do
    [
      %{
        canonical: @uhrmacher,
        leitfrage: "Wo ist der Uhrmacher?",
        arc_status: "offen",
        status: :offen
      },
      %{canonical: @arnheim, status: :offen}
    ]
  end

  defp eingabe(opts) do
    positionen = Map.new(Enum.with_index(@bloecke), fn {b, i} -> {b.block_id, i} end)
    fakten = Eingabe.fakten(roh_diese(), 2, zuordnung(), positionen)
    frueh = roh("f_frueh", "Tess nimmt den Auftrag an, den Uhrmacher zu finden.", ["x"])

    fruehere =
      Keyword.get(opts, :fruehere, [
        %{nummer: 1, name: "Die Werkstatt", fakten: Eingabe.fakten([frueh], 1, zuordnung(), nil)}
      ])

    mit_frueher = fn liste -> if fruehere == [], do: [], else: liste end

    %{
      sitzung: %{id: "s2", nummer: 2, name: "Nach Norden"},
      fakten: fakten,
      fruehere: fruehere,
      boegen: Eingabe.boegen(fakten, threads()),
      vorige_resuemees:
        mit_frueher.([
          %{nummer: 1, name: "Die Werkstatt", text: "Die Gruppe nimmt den Auftrag an."}
        ]),
      vorige_gedanken:
        mit_frueher.([
          %{
            nummer: 1,
            name: "Die Werkstatt",
            fakten_jack: [
              %{
                "abschnitt" => "FIGUREN",
                "schluessel" => "Mira",
                "zeile" => "Spielfigur, kennt Wappen",
                "bloecke" => [3]
              },
              %{
                "abschnitt" => "ABLAUF",
                "schluessel" => "0-9",
                "zeile" => "Besuch in der Werkstatt",
                "bloecke" => [1]
              }
            ],
            resuemee_jack: nil
          }
        ]),
      bloecke: @bloecke,
      cast: ["Mira", "Brann", "Tess"],
      straenge: [@uhrmacher, @arnheim, "Die Salzmine"],
      ueberschrift: Keyword.get(opts, :ueberschrift, "Resümee"),
      flavor: %{base: nil, summary: nil},
      max_woerter: Keyword.get(opts, :max_woerter)
    }
  end

  defp stand(opts \\ []), do: Stand.neu(eingabe(opts))

  defp m(o), do: o |> Jason.encode!() |> Jason.decode!()

  defp alles_gelesen(s), do: s |> Lesen.fakten(%{"von" => 1, "bis" => 5}) |> elem(0)

  defp e(a, k, zeile, fakten \\ [], boegen \\ []),
    do: %{
      "abschnitt" => a,
      "schluessel" => k,
      "zeile" => zeile,
      "fakten" => fakten,
      "boegen" => boegen
    }

  defp notiz(s, eintraege), do: Notizen.notiz(s, %{"eintraege" => eintraege})

  defp form, do: e("FORM", "Form", "chronologische Zusammenfassung in wenigen Absätzen")

  defp fertig(s, fakten, gliederung),
    do:
      Abschluss.fertig(s, %{
        "fakten" => fakten,
        "gliederung" => gliederung,
        "offen_geblieben" => ""
      })

  # Alles gelesen, FORM und ein Gliederungspunkt mit dem arc-Bogen.
  defp bereit do
    {s, {:ok, _}} =
      notiz(alles_gelesen(stand()), [
        form(),
        e("GLIEDERUNG", "1", "Werkstatt und Spieldose", ["S2-F1", "S2-F3"], [@uhrmacher])
      ])

    s
  end

  describe "Eingabe: Fakten und Bögen" do
    test "kurze IDs, Blocknummern aus der Kontextliste, Belege außerhalb werden gezählt" do
      s = stand()

      assert Enum.map(s.fakten, & &1.id) == ~w(S2-F1 S2-F2 S2-F3 S2-F4 S2-F5)

      assert %{fakt_id: "f_e", bloecke: [4], ohne_block: 1, sitzung: 2} = Enum.at(s.fakten, 4)
      assert %{figur: "Mira", boegen: [%{titel: @arnheim, art: "context"}]} = Enum.at(s.fakten, 3)

      # Frühere Sitzung: ihr Mitschnitt ist nicht geladen, also keine Nummern.
      assert [%{fakten: [%{id: "S1-F1", bloecke: [], ohne_block: 0}]}] = s.fruehere
    end

    test "Bögen in der Reihenfolge ihres ersten Fakts, Leitfrage und Status aus dem Strang" do
      assert stand().boegen == [
               %{
                 titel: @uhrmacher,
                 art: "arc",
                 leitfrage: "Wo ist der Uhrmacher?",
                 status: "offen",
                 fakten: ~w(S2-F1 S2-F3 S2-F5)
               },
               %{
                 titel: @arnheim,
                 art: "context",
                 leitfrage: nil,
                 status: "offen",
                 fakten: ["S2-F4"]
               }
             ]
    end
  end

  describe "fakten(sitzung?, von, bis)" do
    test "portionsweise; gelesen zählt, was geliefert wurde" do
      {s, {:ok, t}} = Lesen.fakten(stand(), %{"von" => 1, "bis" => 2})

      assert t =~ "Sitzung 2, Fakten 1 bis 2 von 5."
      assert t =~ "S2-F1\t—\tereignis\t#{@uhrmacher} (arc)\t—\t0\tDie Gruppe steht"
      assert t =~ "S2-F2\tMira\tereignis\t—\t—\t1\tMira klopft"
      assert Stand.ungelesen(s) == ["3-5"]

      # Über das Ende hinaus wird beschnitten.
      {s, {:ok, t}} = Lesen.fakten(s, %{"von" => 4, "bis" => 99})
      assert t =~ "Fakten 4 bis 5 von 5."
      assert t =~ "S2-F5\t—\tereignis\t#{@uhrmacher} (arc)\t—\t4 (+1 außerhalb)\t"
      assert Stand.ungelesen(s) == ["3"]
    end

    test "Zeit: Datum und Erzählzeit" do
      {_s, {:ok, t}} = Lesen.fakten(stand(), %{"von" => 3, "bis" => 3})
      assert t =~ "\tim Herbst · Rückblende\t2\t"
    end

    test "Grenzen sind Fehler" do
      assert {_, {:error, t}} = Lesen.fakten(stand(), %{"von" => 3, "bis" => 2})
      assert t =~ "von (3) ist größer als bis (2)"

      assert {s, {:error, t}} = Lesen.fakten(stand(), %{"von" => 6, "bis" => 9})
      assert t =~ "Sitzung 2 hat die Fakten 1 bis 5."
      assert s.gelesen == MapSet.new()
    end

    test "eine frühere Sitzung ist Vorgeschichte und zählt nicht als gelesen" do
      {s, {:ok, t}} = Lesen.fakten(stand(), %{"sitzung" => 1, "von" => 1, "bis" => 5})

      assert t =~ "Sitzung 1, Fakten 1 bis 1 von 1."
      assert t =~ "S1-F1\t—\tereignis\t#{@uhrmacher} (arc)\t—\t(Sitzung 1)\tTess nimmt"
      assert s.gelesen == MapSet.new()

      # Die eigene Nummer ist wie ohne Angabe.
      {s, {:ok, _}} = Lesen.fakten(stand(), %{"sitzung" => 2, "von" => 1, "bis" => 1})
      assert MapSet.to_list(s.gelesen) == ["S2-F1"]
    end

    test "eine Sitzung, die nicht früher ist, ist ein Fehler" do
      assert {_, {:error, t}} = Lesen.fakten(stand(), %{"sitzung" => 7, "von" => 1, "bis" => 1})
      assert t =~ "Sitzung 7 gehört nicht zu den früheren Sitzungen. Früher sind: 1."
    end
  end

  test "erste Sitzung: neutraler Hinweis statt Vorgeschichte" do
    s = stand(fruehere: [])

    assert {^s, {:ok, @keine_frueheren}} =
             Lesen.fakten(s, %{"sitzung" => 1, "von" => 1, "bis" => 1})

    assert {^s, {:ok, @keine_frueheren}} = Lesen.vorige_resuemees(s, %{})
    assert {^s, {:ok, @keine_frueheren}} = Lesen.vorige_gedanken(s, %{"sitzung" => 1})
    assert Stand.keine_frueheren() == @keine_frueheren
  end

  describe "fakt(id)" do
    test "samt Belegblöcken; zählt als gelesen; Schreibweise der ID egal" do
      {s, {:ok, t}} = Lesen.fakt(stand(), %{"id" => " s2-f4 "})

      assert t =~ "S2-F4\tMira"
      assert t =~ "Belegblöcke:\n3\tMira\tDas Wappen kenne ich"
      assert MapSet.to_list(s.gelesen) == ["S2-F4"]
    end

    test "ein Beleg außerhalb des Mitschnitts wird genannt" do
      {_s, {:ok, t}} = Lesen.fakt(stand(), %{"id" => "S2-F5"})

      assert t =~ "4\tSL\tNach zwei Tagen"
      assert t =~ "1 Beleg(e) liegen außerhalb des Mitschnitts dieser Sitzung"
    end

    test "ein früherer Fakt: mit Hinweis, ohne Belegblöcke, nicht gelesen" do
      {s, {:ok, t}} = Lesen.fakt(stand(), %{"id" => "S1-F1"})

      assert t =~ "Tess nimmt den Auftrag an"
      assert t =~ "Der Fakt stammt aus Sitzung 1. Deren Mitschnitt ist hier nicht geladen"
      assert s.gelesen == MapSet.new()
    end

    test "eine unbekannte ID ist ein Fehler" do
      assert {_, {:error, t}} = Lesen.fakt(stand(), %{"id" => "S2-F42"})
      assert t =~ "Einen Fakt \"S2-F42\" gibt es nicht."
    end
  end

  describe "boegen, Vorgeschichte, Mitschnitt" do
    test "boegen: Titel, Art, Status, Leitfrage, Fakten; dazu die ohne Bogen" do
      {_s, {:ok, t}} = Lesen.boegen(stand(), %{})

      assert t =~
               "#{@uhrmacher}\tArt: arc\tStatus: offen\tLeitfrage: Wo ist der Uhrmacher?\t" <>
                 "Fakten: S2-F1, S2-F3, S2-F5"

      assert t =~ "#{@arnheim}\tArt: context\tStatus: offen\tLeitfrage: —\tFakten: S2-F4"
      assert t =~ "Ohne Bogen: S2-F2"
    end

    test "vorige_resuemees: alle früheren oder ein Bereich" do
      {_s, {:ok, t}} = Lesen.vorige_resuemees(stand(), %{})
      assert t == "## Sitzung 1 — Die Werkstatt\n\nDie Gruppe nimmt den Auftrag an."

      assert {_s, {:ok, "Zu den früheren Sitzungen 3 bis 5 liegt kein Resümee vor."}} =
               Lesen.vorige_resuemees(stand(), %{"von" => 3, "bis" => 5})

      assert {_s, {:error, _}} = Lesen.vorige_resuemees(stand(), %{"von" => 2, "bis" => 1})
    end

    test "vorige_gedanken: Gedächtnis des Fakten-Jack, Notizen des Resümee-Jack oder keine" do
      {_s, {:ok, t}} = Lesen.vorige_gedanken(stand(), %{"sitzung" => 1})

      assert t =~ "## Sitzung 1 — Gedächtnis beim Lesen des Mitschnitts"
      assert t =~ "### FIGUREN\nMira — Spielfigur, kennt Wappen"
      assert t =~ "### ABLAUF\n0-9 — Besuch in der Werkstatt"
      assert t =~ "## Sitzung 1 — Notizen zum Resümee\n\n(keine abgelegt)"

      # Die Ablage eines früheren Resümee-Laufs (B4) — String-Schlüssel.
      s = stand()
      [g] = s.vorige_gedanken
      ablage = %{"notizen" => [m(e("FORM", "Form", "Stichpunkte"))]}
      s = %{s | vorige_gedanken: [%{g | fakten_jack: nil, resuemee_jack: ablage}]}

      {_s, {:ok, t}} = Lesen.vorige_gedanken(s, %{"sitzung" => 1})
      assert t =~ "Mitschnitts\n\n(keins abgelegt)"
      assert t =~ "## FORM\nForm — Stichpunkte"

      assert {_s, {:error, t}} = Lesen.vorige_gedanken(stand(), %{"sitzung" => 2})
      assert t =~ "Früher sind: 1."
    end

    test "der Mitschnitt läuft über die Werkzeuge des Fakten-Jack" do
      defs = Map.new(Lesen.werkzeuge(stand()), &{&1.name, &1})

      {s, {:ok, t}} = defs["bloecke"].ausfuehren.(stand(), %{"von" => 0, "bis" => 2})
      assert t =~ "1\tMira\tIch klopfe zweimal"
      assert s.mitschnitt.gelesen == [{0, 2}]
      assert defs["bloecke"].beschreibung =~ "zum Verstehen der Fakten"

      # E0 (#1210): an Stelle von `suche` sucht `suche_sitzung` in Fakten,
      # Mitschnitt und Bögen dieser Sitzung.
      refute Map.has_key?(defs, "suche")
      {_s, {:ok, t}} = defs["suche_sitzung"].ausfuehren.(stand(), %{"begriff" => "Wappen"})
      assert t =~ "## Mitschnitt — 2 Treffer, hier 1 bis 2, keine weiteren"
      assert t =~ "## Fakten — 2 Treffer"

      assert {_s, {:ok, "Mira\nBrann\nTess"}} = defs["cast"].ausfuehren.(stand(), %{})
      refute defs["cast"].beschreibung =~ "cast_match"
    end
  end

  describe "notiz: FORM vor GLIEDERUNG" do
    test "eine GLIEDERUNG ohne FORM wird abgelehnt" do
      {s, {:error, a}} = notiz(stand(), [e("GLIEDERUNG", "1", "Werkstatt", ["S2-F1"])])

      assert [f] = m(a)["fehler"]
      assert f =~ "GLIEDERUNG/1: erst die FORM"
      assert f =~ "„Resümee“"
      assert s.notizen == []
    end

    test "FORM und GLIEDERUNG in einem Aufruf; gespeichert wird die Schreibweise des Bestands" do
      {s, {:ok, a}} =
        notiz(stand(), [
          form(),
          e("GLIEDERUNG", "1", "Werkstatt", ["s2-f1", "S2-F3", "S2-F1"], [
            "der verschwundene  uhrmacher"
          ])
        ])

      assert %{"neu" => 2, "eintraege_gesamt" => 2} = m(a)
      refute Map.has_key?(m(a), "es_fehlt")

      assert [%{fakten: ["S2-F1", "S2-F3"], boegen: [@uhrmacher]}] =
               Stand.abschnitt(s, "GLIEDERUNG")
    end

    test "die FORM ist genau ein Eintrag; derselbe Schlüssel ersetzt" do
      {s, {:ok, a}} = notiz(stand(), [form()])
      assert m(a)["es_fehlt"] == ["GLIEDERUNG"]

      {s, {:error, a}} = notiz(s, [e("FORM", "Zweite", "Stichpunkte")])
      assert [f] = m(a)["fehler"]
      assert f =~ "FORM hat schon einen Eintrag unter „Form“"

      {s, {:ok, a}} = notiz(s, [e("FORM", "Form", "Stichpunkte")])
      assert m(a)["ersetzt"] == 1
      assert Stand.form(s).zeile == "Stichpunkte"
    end

    test "unbekannte Fakten und Bögen werden abgelehnt; Stränge der Kampagne gelten" do
      {s, {:ok, _}} = notiz(stand(), [form()])

      {_s, {:error, a}} = notiz(s, [e("GLIEDERUNG", "1", "Werkstatt", ["S2-F9"])])
      assert [f] = m(a)["fehler"]
      assert f =~ "Fakten gibt es nicht: [\"S2-F9\"]"

      {_s, {:error, a}} =
        notiz(s, [e("GLIEDERUNG", "1", "Werkstatt", ["S2-F1"], ["Die Drachenhöhle"])])

      assert [f] = m(a)["fehler"]
      assert f =~ "Bögen gibt es nicht: [\"Die Drachenhöhle\"]"
      assert f =~ "boegen() oder straenge()"

      # Ein Strang der Kampagne, den diese Sitzung nicht berührt, ist bekannt.
      assert {_s, {:ok, _}} =
               notiz(s, [e("GLIEDERUNG", "1", "Salzmine", ["S2-F5"], ["Die Salzmine"])])

      # Frühere Fakten dürfen genannt werden.
      assert {_s, {:ok, _}} = notiz(s, [e("OFFEN", "Auftrag", "Wer zahlt?", ["S1-F1"])])
    end

    test "ein Gliederungspunkt nennt mindestens einen Fakt" do
      {s, {:ok, _}} = notiz(stand(), [form()])
      {_s, {:error, a}} = notiz(s, [e("GLIEDERUNG", "1", "Werkstatt", [], [@uhrmacher])])
      assert [f] = m(a)["fehler"]
      assert f =~ "nennt keinen Fakt"
    end

    test "zeile null streicht; ein Aufruf ohne Änderung ist ein Fehler" do
      s = bereit()

      {s, {:ok, a}} = notiz(s, [e("GLIEDERUNG", "1", nil)])
      assert m(a)["gestrichen"] == 1
      assert Stand.abschnitt(s, "GLIEDERUNG") == []

      assert {_s, {:error, _}} = notiz(s, [e("GLIEDERUNG", "1", nil)])
      assert {_s, {:error, a}} = notiz(s, [form()])
      assert m(a)["unveraendert"] == 1
    end

    test "notizen_lesen: Stand, Einträge mit Schlüssel, Notizen als Text" do
      {_s, {:ok, a}} = Notizen.notizen_lesen(bereit(), %{})
      a = m(a)

      assert a["stand"] =~ "Das Resümee hat das Ziel von 150 Wörtern, höchstens 300."
      assert a["stand"] =~ "Fakten dieser Sitzung: 5 von 5 gelesen."
      assert a["stand"] =~ "FORM: chronologische Zusammenfassung"

      assert a["stand"] =~
               "GLIEDERUNG (der Weg der Gruppe): 1 von höchstens 12 Stationen; sie nennen 2 " <>
                 "von 5 Fakten dieser Sitzung."

      # Die Spanne: S2-F1 steht in Block 0, S2-F3 in Block 2, die Sitzung reicht bis 4.
      assert a["stand"] =~
               "Die Fakten deiner GLIEDERUNG reichen von Block 0 bis 2, die Fakten dieser " <>
                 "Sitzung von Block 0 bis 4. Nach Block 2 liegen Fakten, die keine Station nennt"

      # #1209: keine Liste der Handlungsbögen ohne Punkt — die Gliederung wählt aus.
      refute a["stand"] =~ "ohne Gliederungspunkt"

      assert [%{"abschnitt" => "FORM"}, %{"abschnitt" => "GLIEDERUNG", "schluessel" => "1"}] =
               a["eintraege"]

      assert a["notizen"] =~
               "## GLIEDERUNG\n1 — Werkstatt und Spieldose  [Fakten: S2-F1, S2-F3 · Bögen: #{@uhrmacher}]"
    end
  end

  describe "Länge und Gliederungsdeckel (#1209)" do
    test "ohne Länge gilt der Standard, eine ungültige Länge ebenso; die Obergrenze ist das Doppelte" do
      assert stand().max_woerter == 150
      assert stand(max_woerter: 5).max_woerter == 150
      assert stand(max_woerter: "viel").max_woerter == 150
      assert stand(max_woerter: 120).max_woerter == 120
      assert Stand.obergrenze(stand()) == 300
      assert Stand.obergrenze(stand(max_woerter: 120)) == 240
    end

    test "der Deckel folgt der Länge: max(3, round(2 * max_woerter / 25))" do
      assert Stand.max_gliederung(150) == 12
      assert Stand.max_gliederung(75) == 6
      assert Stand.max_gliederung(30) == 3
      assert Stand.max_gliederung(40) == 3
      assert Stand.max_gliederung(100) == 8
      assert Stand.max_gliederung(1000) == 80
      assert Stand.max_gliederung(stand(max_woerter: 120)) == 10

      defs = Map.new(Notizen.werkzeuge(stand(max_woerter: 100)), &{&1.name, &1})

      assert defs["notiz"].beschreibung =~
               "höchstens 8 Stationen — das Resümee hat das Ziel von 100 Wörtern, höchstens 200"

      assert defs["notiz"].beschreibung =~ "Weg der Gruppe durch die Sitzung"
    end

    test "ein Punkt über dem Deckel wird abgelehnt; ersetzen und streichen gehen" do
      # Ziel 30: höchstens drei Stationen.
      {s, {:ok, _}} =
        notiz(alles_gelesen(stand(max_woerter: 30)), [
          form(),
          e("GLIEDERUNG", "1", "Werkstatt", ["S2-F1"], [@uhrmacher]),
          e("GLIEDERUNG", "2", "Wappen", ["S2-F4"], [@arnheim]),
          e("GLIEDERUNG", "3", "Reise", ["S2-F5"], [@uhrmacher])
        ])

      {s2, {:error, a}} = notiz(s, [e("GLIEDERUNG", "4", "Klopfen", ["S2-F2"])])
      assert [f] = m(a)["fehler"]
      assert f =~ "GLIEDERUNG/4: die Gliederung hat schon 3 Stationen"
      assert f =~ "höchstens 60 Wörtern"
      assert f =~ "Die übrigen Fakten bleiben im Faktenbestand."
      assert length(Stand.abschnitt(s2, "GLIEDERUNG")) == 3

      # Derselbe Schlüssel ersetzt — auch bei voller Gliederung.
      {s, {:ok, a}} = notiz(s, [e("GLIEDERUNG", "3", "Klopfen", ["S2-F2"])])
      assert m(a)["ersetzt"] == 1

      # Nach dem Streichen ist wieder Platz.
      {s, {:ok, _}} = notiz(s, [e("GLIEDERUNG", "3", nil)])
      assert {_s, {:ok, a}} = notiz(s, [e("GLIEDERUNG", "4", "Reise", ["S2-F5"])])
      assert m(a)["neu"] == 1
    end

    test "Abbild und Zusammenfassung zeigen die Grenze" do
      a = Stand.abbild(stand())

      assert %{
               "max_woerter" => 150,
               "obergrenze" => 300,
               "max_gliederung" => 12,
               "gliederung" => 0
             } = a

      refute Map.has_key?(a, "arc_ohne_gliederung")

      t = Zusammenfassung.text(stand())
      assert t =~ "mit dem Ziel von 150 Wörtern (höchstens 300)"
      assert t =~ "Das Resümee hat das Ziel von 150 Wörtern, höchstens 300."
      assert t =~ "die GLIEDERUNG ist der Weg der Gruppe durch die Sitzung"
    end
  end

  # #1209: die Gliederung ist der Weg der Gruppe, Station für Station.
  describe "Der Weg der Gruppe (#1209)" do
    test "eine Station nennt einen Fakt dieser Sitzung; frühere dürfen dazukommen" do
      {s, {:ok, _}} = notiz(stand(), [form()])

      {_s, {:error, a}} =
        notiz(s, [e("GLIEDERUNG", "1", "Der Auftrag", ["S1-F1"], [@uhrmacher])])

      assert [f] = m(a)["fehler"]
      assert f =~ "GLIEDERUNG/1: der Punkt nennt keinen Fakt dieser Sitzung"
      assert f =~ "Weg der Gruppe durch Sitzung 2"

      assert {_s, {:ok, _}} =
               notiz(s, [e("GLIEDERUNG", "1", "Der Auftrag", ["S1-F1", "S2-F1"], [@uhrmacher])])
    end

    test "Spanne und Reihenfolge: ein Hinweis in notiz, notizen_lesen und fertig, keine Ablehnung" do
      # Station 1 beginnt bei Block 3 (S2-F4), Station 2 bei Block 0 (S2-F1).
      {s, {:ok, a}} =
        notiz(alles_gelesen(stand()), [
          form(),
          e("GLIEDERUNG", "1", "Das Wappen", ["S2-F4"]),
          e("GLIEDERUNG", "2", "Vor der Werkstatt", ["S2-F1"])
        ])

      w = m(a)["weg"]

      assert w =~
               "Die Fakten deiner GLIEDERUNG reichen von Block 0 bis 3, die Fakten dieser " <>
                 "Sitzung von Block 0 bis 4."

      assert w =~ "Nach Block 3 liegen Fakten, die keine Station nennt"
      assert w =~ "nicht in Blockreihenfolge: „2“ beginnt bei Block 0, vor „1“ (Block 3)"

      assert %{gliederung: {0, 3}, sitzung: {0, 4}, reihenfolge: {:nein, _, _}} = Weg.spanne(s)

      {_s, {:ok, l}} = Notizen.notizen_lesen(s, %{})
      assert m(l)["stand"] =~ "nicht in Blockreihenfolge"

      # Ein Hinweis, kein Hindernis: fertig nimmt den Überblick an und nennt ihn.
      {s2, {:halt, f}} = fertig(s, 5, 2)
      assert m(f)["weg"] == w

      assert {"abschluss.jsonl", %{"abschluss" => true, "lauf" => "ueberblick", "weg" => ^w}} =
               List.last(Stand.journal_liste(s2))

      # In der Ablehnung steht er ebenso.
      {u, {:ok, _}} = notiz(stand(), [form(), e("GLIEDERUNG", "1", "Wappen", ["S2-F4"])])
      {_u, {:error, r}} = fertig(u, 0, 1)
      assert m(r)["weg"] =~ "reichen von Block 3 bis 3"

      # In Reihenfolge und bis an beide Enden.
      {s, {:ok, a}} =
        notiz(s, [
          e("GLIEDERUNG", "1", "Vor der Werkstatt", ["S2-F1"]),
          e("GLIEDERUNG", "2", "Das Dorf", ["S2-F4", "S2-F5"])
        ])

      w = m(a)["weg"]
      assert w =~ "reichen von Block 0 bis 4"
      refute w =~ "liegen Fakten"
      assert w =~ "Die Stationen stehen in Blockreihenfolge."
      assert Weg.spanne(s) == %{gliederung: {0, 4}, sitzung: {0, 4}, reihenfolge: :ja}
    end

    test "ohne Gliederung kein Hinweis" do
      {s, {:ok, a}} = notiz(stand(), [form()])
      refute Map.has_key?(m(a), "weg")
      assert Weg.hinweis(s) == nil
    end
  end

  describe "fertig" do
    test "lehnt ab, solange Fakten ungelesen sind, FORM fehlt, GLIEDERUNG leer ist" do
      {s, {:error, a}} = fertig(stand(), 0, 0)
      offen = m(a)["offen"]

      assert length(offen) == 3
      assert Enum.at(offen, 0) =~ "noch nicht gelesen: 1-5"
      assert Enum.at(offen, 1) =~ "Die FORM fehlt"
      assert Enum.at(offen, 2) =~ "Die GLIEDERUNG ist leer"
      assert Enum.at(offen, 2) =~ "höchstens 12 Stationen"
      refute Enum.any?(offen, &(&1 =~ @uhrmacher))
      assert s.abschluss_zahlversuche == 0
    end

    # #1209: bis dahin musste jeder arc-Bogen in die Gliederung, und sie wuchs
    # mit jedem Bogen. Jetzt wählt sie aus; die Pflicht hat das Schreiben.
    test "die Gliederung wählt aus: ein Bogen der Art arc ohne Punkt hindert fertig nicht" do
      {s, {:ok, _}} =
        notiz(alles_gelesen(stand()), [
          form(),
          e("GLIEDERUNG", "1", "Das Wappen", ["S2-F4"], [@arnheim])
        ])

      assert {_s, {:halt, _}} = fertig(s, 5, 1)
    end

    test "falsche Zahlen: die Ablehnung NENNT die gezählten, der dritte Versuch geht durch" do
      s = bereit()

      {s, {:error, a}} = fertig(s, 4, 1)

      assert m(a)["abweichung"] == [
               "fakten: du sagst 4 — gezählt sind 5"
             ]

      # Seit 18.09.2026 nennt die Ablehnung die gezählte Zahl: die Arbeit ist
      # durch, nur der Zähler stimmt nicht — sie zu verschweigen kostete nur
      # Runden (an einem echten Chronik-Lauf gesehen).
      assert Jason.encode!(a) =~ "gezählt sind 5"

      {s, {:error, _}} = fertig(s, 4, 1)
      {s, {:halt, a}} = fertig(s, 4, 1)

      assert m(a)["zahlen"] == %{"fakten" => 5, "gliederung" => 1}

      assert Enum.any?(Stand.journal_liste(s), fn
               {"abschluss.jsonl", %{"abschluss" => true, "zahlen_stimmten" => "nein"}} -> true
               _ -> false
             end)
    end

    test "richtige Zahlen: abgeschlossen" do
      assert {_s, {:halt, a}} = fertig(bereit(), 5, 1)
      assert %{"ok" => true, "fertig" => true} = m(a)
    end
  end

  describe "Werkzeuge, Halter, Zusammenfassung" do
    test "alle Werkzeuge des Überblicks, streng angelegt; jedes ruft den Halter" do
      {:ok, h} = Halter.start_link(stand())
      ws = Werkzeuge.fuer(h)
      by = Map.new(ws, &{&1.name, &1})

      # `hilfe` steht in JEDEM Lauf vorne und wird nicht in `namen/1` geführt —
      # es braucht keine Definition, es liest die der anderen (18.09.2026).
      assert Enum.map(ws, & &1.name) == ["hilfe", "jetzt_kompaktieren" | Werkzeuge.namen(stand())]
      assert by["fakten"].parameter["required"] == ["bis", "von"]
      assert by["vorige_gedanken"].parameter["required"] == ["sitzung"]
      assert by["fertig"].parameter["required"] == ["fakten", "gliederung", "offen_geblieben"]

      assert by["notiz"].parameter["properties"]["eintraege"]["items"]["required"] ==
               ~w(abschnitt boegen fakten schluessel zeile)

      assert {:ok, _} = by["fakten"].ausfuehren.(%{"von" => 1, "bis" => 1})
      assert MapSet.to_list(Halter.stand(h).gelesen) == ["S2-F1"]
      Agent.stop(h)
    end

    test "der Halter meldet den Stand; ein Werkzeug, das wirft, lässt ihn stehen" do
      {:ok, h} = Halter.start_link(stand(), beobachter: self())

      assert_receive {:jack_resuemee_stand,
                      %{"gelesen" => 0, "fakten" => 5, "lauf" => "ueberblick"}}

      assert {:error, "kaputt"} = Halter.aufrufen(h, fn _s, _a -> raise "kaputt" end, %{})
      assert Halter.stand(h) == stand()
      Agent.stop(h)
    end

    test "die Zusammenfassung trägt Überschrift, Lesestand und den nächsten Schritt" do
      {s, _} = Lesen.fakten(stand(ueberschrift: "Rückblick"), %{"von" => 1, "bis" => 2})
      t = Zusammenfassung.text(s)

      assert t =~ "„Rückblick“"
      assert t =~ "Fakten dieser Sitzung: 2 von 5 gelesen. Noch nicht gelesen: 3-5."
      assert t =~ "Lies weiter: fakten(von, bis) ab Fakt 3."

      assert Zusammenfassung.text(bereit()) =~
               "Prüf deine Gliederung mit notizen_lesen() und schließ mit fertig() ab."
    end

    test "die Ablage der Notizen liest sich als Text zurück" do
      ablage = Stand.ablage(bereit())

      assert [
               %{"abschnitt" => "FORM"},
               %{"abschnitt" => "GLIEDERUNG", "fakten" => ["S2-F1", "S2-F3"]}
             ] =
               ablage["notizen"]

      assert Notizen.text_aus(ablage) == Notizen.notizen_text(bereit())
      assert Notizen.text_aus(nil) == ""
    end
  end
end
