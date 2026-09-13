defmodule Worker.Jack.Resuemee.SchreibenTest do
  # J5 (#1209, B2): das Schreiben, rein auf dem Stand — kein Mnesia, kein
  # Modell. Beispiele aus der Demo-Welt (Werkstatt am Hafen).
  use ExUnit.Case, async: true

  alias Worker.Agent.Schema

  alias Worker.Jack.Resuemee.{
    Abschluss,
    Eingabe,
    Entwurf,
    Ergebnis,
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
  @salz "Die Salzmine"

  defp roh(id, claim, refs),
    do: %{"id" => id, "claim" => claim, "source_refs" => refs, "verified?" => true}

  defp eingabe(opts \\ []) do
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
          roh("f_c", "Mira erkennt das Wappen der Familie von Arnheim.", ["b2"]),
          roh("f_d", "Die Gruppe erreicht das Dorf an den Salzminen.", ["b3"])
        ],
        2,
        zuordnung,
        %{"b0" => 0, "b1" => 1, "b2" => 2, "b3" => 3}
      )

    frueh =
      Eingabe.fakten(
        [roh("f_frueh", "Tess nimmt den Auftrag an, den Uhrmacher zu finden.", ["x"])],
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
      cast: ["Mira", "Tess"],
      straenge: [@uhrmacher, @arnheim, @salz],
      ueberschrift: "Rückblick",
      flavor: Keyword.get(opts, :flavor, %{base: nil, summary: nil}),
      max_woerter: Keyword.get(opts, :max_woerter)
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
        },
        %{
          "abschnitt" => "GLIEDERUNG",
          "schluessel" => "1",
          "zeile" => "Werkstatt und Spieldose",
          "fakten" => ["S2-F1", "S2-F2"],
          "boegen" => [@uhrmacher]
        }
      ]
    }
  end

  defp stand(opts \\ []), do: Stand.fuer_schreiben(eingabe(opts), ablage())

  defp m(o), do: o |> Jason.encode!() |> Jason.decode!()

  defp satz(text, fakten, extra \\ %{}),
    do: Map.merge(%{"text" => text, "fakten" => fakten}, extra)

  defp absatz(s, saetze, titel \\ nil) do
    p = %{"saetze" => saetze}
    Entwurf.absatz(s, if(titel, do: Map.put(p, "titel", titel), else: p))
  end

  defp gruende(roh) do
    assert {:abgelehnt, g} = Entwurf.satz_pruefen(stand(), roh)
    Enum.map(g, &elem(&1, 0))
  end

  defp woerter(n), do: 1..n |> Enum.map(fn _ -> "Wort" end) |> Enum.join(" ")

  # Ein Entwurf mit einem Absatz, der beide Handlungsbögen erzählt.
  defp geschrieben do
    {s, {:ok, _}} =
      absatz(
        stand(),
        [
          satz("Der Alte zeigt der Gruppe eine Spieldose.", ["S2-F1"]),
          satz("Danach geht es nach Norden.", ["S2-F4"])
        ],
        "In der Werkstatt"
      )

    s
  end

  defp fertig(s, absaetze, saetze, ausgelassen \\ [], begruendung \\ ""),
    do:
      Abschluss.fertig(s, %{
        "absaetze" => absaetze,
        "saetze" => saetze,
        "ausgelassen" => ausgelassen,
        "laenge_begruendung" => begruendung,
        "offen_geblieben" => ""
      })

  # Drei Stationen: „1“ und „2“ mit Fakten dieser Sitzung, „3“ nur mit einem
  # früheren — die lässt sich nie tragen und zählt nicht.
  defp weg_ablage do
    %{
      "notizen" =>
        ablage()["notizen"] ++
          [
            %{
              "abschnitt" => "GLIEDERUNG",
              "schluessel" => "2",
              "zeile" => "Reise nach Norden",
              "fakten" => ["S2-F4"],
              "boegen" => [@salz]
            },
            %{
              "abschnitt" => "GLIEDERUNG",
              "schluessel" => "3",
              "zeile" => "Der Auftrag",
              "fakten" => ["S1-F1"],
              "boegen" => []
            }
          ]
    }
  end

  describe "der Stand des Schreibens" do
    test "frisch aus der Eingabe, nur die Notizen des Überblicks kommen mit" do
      s = stand()

      assert s.lauf == :schreiben
      assert s.gelesen == MapSet.new()
      assert s.entwurf == []
      assert Stand.form(s).zeile == "chronologische Nacherzählung"

      assert [%{schluessel: "1", fakten: ["S2-F1", "S2-F2"], boegen: [@uhrmacher]}] =
               Stand.abschnitt(s, "GLIEDERUNG")

      # Die Ablage liest sich zurück wie die des Überblicks.
      assert Stand.ablage(s) == ablage()
      assert Stand.fuer_schreiben(eingabe(), nil).notizen == []
    end

    test "Ton: neutral ohne Vorgabe, sonst Grundton und Resümee-Ton je als Absatz" do
      assert Stand.ton(%{base: nil, summary: "  "}) ==
               "Für diese Kampagne ist kein Ton vorgegeben."

      assert Stand.ton(nil) == "Für diese Kampagne ist kein Ton vorgegeben."
      assert Stand.ton(%{base: " Düster. ", summary: nil}) == "**Grundton der Kampagne:** Düster."

      assert Stand.ton(%{base: "Düster.", summary: "Knapp."}) ==
               "**Grundton der Kampagne:** Düster.\n\n**Ton des Resümees:** Knapp."
    end
  end

  describe "Satzprüfung" do
    test "ein Fakt dieser Sitzung reicht, frühere dürfen dazu; IDs in der Schreibweise des Bestands" do
      assert {:ok, satz} =
               Entwurf.satz_pruefen(
                 stand(),
                 satz("  Der Alte\n zeigt   die Spieldose. ", ["s2-f1", "S1-F1", " S2-F1 "])
               )

      assert satz == %{
               text: "Der Alte zeigt die Spieldose.",
               fakten: ["S2-F1", "S1-F1"],
               uebergang: false,
               rueckblick: false
             }
    end

    test "nur Fakten früherer Sitzungen: als Rückblick markiert" do
      assert gruende(satz("Tess nahm den Auftrag an.", ["S1-F1"])) == ["rueckblick_fehlt"]

      assert {:ok, %{rueckblick: true}} =
               Entwurf.satz_pruefen(
                 stand(),
                 satz("Tess nahm den Auftrag an.", ["S1-F1"], %{"rueckblick" => true})
               )
    end

    test "ohne Fakten: als Übergang markiert" do
      assert gruende(satz("So viel zur Vorgeschichte.", [])) == ["uebergang_fehlt"]

      assert {:ok, %{uebergang: true, fakten: []}} =
               Entwurf.satz_pruefen(
                 stand(),
                 satz("So viel zur Vorgeschichte.", [], %{"uebergang" => true})
               )
    end

    test "Markierungen, die den Fakten widersprechen, werden abgelehnt" do
      assert gruende(satz("x", ["S2-F1"], %{"uebergang" => true})) == ["uebergang_mit_fakten"]

      assert gruende(satz("x", ["S2-F1", "S1-F1"], %{"rueckblick" => true})) ==
               ["rueckblick_mit_fakt_dieser_sitzung"]

      assert gruende(satz("x", [], %{"rueckblick" => true, "uebergang" => true})) ==
               ["rueckblick_ohne_fakten"]

      assert gruende(satz("x", ["S1-F1"], %{"rueckblick" => true, "uebergang" => true})) ==
               ["uebergang_mit_fakten"]

      assert gruende(satz("x", ["S2-F1"], %{"rueckblick" => true, "uebergang" => true})) ==
               ["uebergang_mit_fakten", "rueckblick_mit_fakt_dieser_sitzung"]

      # Die Erklärung nennt die Regel.
      {:abgelehnt, [{_, text}]} =
        Entwurf.satz_pruefen(stand(), satz("x", ["S2-F1"], %{"rueckblick" => true}))

      assert text =~ "nur Fakten früherer Sitzungen"
    end

    test "unbekannte Fakten werden genannt; die Markierungen prüft dann niemand" do
      {:abgelehnt, g} =
        Entwurf.satz_pruefen(stand(), satz("x", ["S2-F9", "S2-F1"], %{"rueckblick" => true}))

      assert [{"fakt_unbekannt", text}] = g
      assert text =~ ~s(["S2-F9"])
    end

    test "ein leerer Satz und ein zu langer werden abgelehnt, 80 Wörter gehen durch" do
      assert gruende(satz("   ", ["S2-F1"])) == ["leer"]
      assert gruende(satz(woerter(81), ["S2-F1"])) == ["zu_lang"]
      assert {:ok, _} = Entwurf.satz_pruefen(stand(), satz(woerter(80), ["S2-F1"]))
      assert Entwurf.max_woerter() == 80
    end

    test "keine Namensprüfung: ein Name, den kein Fakt nennt, geht durch" do
      assert {:ok, _} =
               Entwurf.satz_pruefen(
                 stand(),
                 satz("Der alte Brann zeigt die Spieldose.", ["S2-F1"])
               )
    end
  end

  describe "absatz" do
    test "hängt an; die Antwort nennt Handlungsbögen ohne Satz" do
      {s, {:ok, a}} =
        absatz(stand(), [satz("Der Alte zeigt die Spieldose.", ["S2-F1"])], "In der Werkstatt")

      assert %{"ok" => true, "absatz" => 1, "saetze" => 1, "entwurf" => "1 Absätze, 1 Sätze"} =
               m(a)

      assert m(a)["handlungsboegen_ohne_satz"] == [@salz]

      {s, {:ok, a}} = absatz(s, [satz("Dann geht es nach Norden.", ["S2-F4"])])
      assert m(a)["absatz"] == 2
      refute Map.has_key?(m(a), "handlungsboegen_ohne_satz")

      assert [%{titel: "In der Werkstatt"}, %{titel: nil}] = s.entwurf
    end

    test "ein abgelehnter Satz: der ganze Absatz bleibt draußen, mit Nummer, Anfang und Grund" do
      {s, {:error, a}} =
        absatz(stand(), [
          satz("Der Alte zeigt die Spieldose.", ["S2-F1"]),
          satz("Eins zwei drei vier fünf sechs sieben acht neun zehn.", [])
        ])

      assert s.entwurf == []
      a = m(a)

      assert a["hinweis"] =~ "Nichts eingetragen"

      assert [%{"satz" => 2, "anfang" => "Eins zwei drei vier fünf sechs sieben acht …"} = f] =
               a["abgelehnt"]

      assert [grund] = f["gruende"]
      assert grund =~ "uebergang: true"

      assert [{"entwurf_verlauf.jsonl", eintrag}] = Stand.journal_liste(s)

      assert %{
               "art" => "abgelehnt",
               "werkzeug" => "absatz",
               "saetze" => [%{"satz" => 2, "gruende" => ["uebergang_fehlt"]}]
             } = eintrag
    end

    test "der Titel ist optional; ein leerer und ein zu langer werden abgelehnt" do
      {_s, {:error, a}} = absatz(stand(), [satz("x", ["S2-F1"])], "   ")
      assert [t] = m(a)["titel"]
      assert t =~ "Der Titel ist leer"

      {s, {:error, a}} = absatz(stand(), [satz("x", ["S2-F1"])], woerter(13))
      assert [t] = m(a)["titel"]
      assert t =~ "höchstens 12"
      assert s.entwurf == []

      assert {_s, {:ok, _}} = absatz(stand(), [satz("x", ["S2-F1"])], woerter(12))
    end

    test "absatz_ersetzen: gleiche Prüfung, der Platz bleibt" do
      s = geschrieben()
      {s, {:ok, _}} = absatz(s, [satz("Mira erkennt das Wappen.", ["S2-F3"])])

      neu = %{
        "nummer" => 1,
        "saetze" => [satz("Die Spieldose gehörte dem Uhrmacher.", ["S2-F2"])]
      }

      {s, {:ok, a}} = Entwurf.absatz_ersetzen(s, neu)

      assert m(a)["hinweis"] == "Absatz 1 ersetzt."

      assert [%{titel: nil, saetze: [%{fakten: ["S2-F2"]}]}, %{saetze: [%{fakten: ["S2-F3"]}]}] =
               s.entwurf

      assert {^s, {:error, t}} = Entwurf.absatz_ersetzen(s, neu)
      assert t =~ "steht bereits genau so"

      assert {^s, {:error, t}} = Entwurf.absatz_ersetzen(s, %{neu | "nummer" => 5})
      assert t =~ "Einen Absatz 5 gibt es nicht. Der Entwurf hat die Absätze 1 bis 2"

      {s2, {:error, a}} =
        Entwurf.absatz_ersetzen(s, %{"nummer" => 2, "saetze" => [satz("x", ["S2-F9"])]})

      assert s2.entwurf == s.entwurf
      assert [%{"satz" => 1}] = m(a)["abgelehnt"]

      assert {"entwurf_verlauf.jsonl", %{"werkzeug" => "absatz_ersetzen", "absatz" => 2}} =
               List.last(Stand.journal_liste(s2))
    end

    test "absatz_streichen: die Absätze dahinter rücken auf" do
      s = geschrieben()
      {s, {:ok, _}} = absatz(s, [satz("Mira erkennt das Wappen.", ["S2-F3"])])

      {s, {:ok, a}} = Entwurf.absatz_streichen(s, %{"nummer" => 1})
      assert m(a)["hinweis"] =~ "der bisherige Absatz 2 ist jetzt Absatz 1"
      assert [%{saetze: [%{fakten: ["S2-F3"]}]}] = s.entwurf

      assert {_s, {:error, t}} = Entwurf.absatz_streichen(stand(), %{"nummer" => 1})
      assert t =~ "der Entwurf ist noch leer"
    end

    test "entwurf(): Nummern, Titel, Fakten und Markierungen" do
      assert {_s, {:ok, "Der Entwurf ist noch leer. Leg den ersten Absatz mit absatz() an."}} =
               Entwurf.entwurf(stand(), %{})

      {s, {:ok, _}} =
        absatz(stand(), [
          satz("Tess nahm den Auftrag an.", ["S1-F1"], %{"rueckblick" => true}),
          satz("So viel zur Vorgeschichte.", [], %{"uebergang" => true}),
          satz("Der Alte zeigt die Spieldose.", ["S2-F1", "S2-F2"])
        ])

      {s, {:ok, _}} = absatz(s, [satz("Mira erkennt das Wappen.", ["S2-F3"])], "Das Wappen")
      {_s, {:ok, t}} = Entwurf.entwurf(s, %{})

      assert t =~ "Entwurf: 2 Absätze, 4 Sätze (davon 1 Übergänge, 1 Rückblicke)"
      assert t =~ "sie nennen 3 von 4 Fakten dieser Sitzung."

      assert t =~
               "Handlungsbögen, von denen noch kein Satz einen Fakt dieser Sitzung nennt: #{@salz}"

      assert t =~
               "Absatz 1 (Fließtext) · 14 Wörter\n  1. Tess nahm den Auftrag an.  [Rückblick: S1-F1]"

      assert t =~ "  2. So viel zur Vorgeschichte.  [Übergang]"
      assert t =~ "  3. Der Alte zeigt die Spieldose.  [S2-F1, S2-F2]"
      assert t =~ "Absatz 2 — Das Wappen · 6 Wörter\n  1. Mira erkennt das Wappen.  [S2-F3]"
    end
  end

  describe "Länge (#1209): Ziel und Obergrenze" do
    test "Titel und Sätze zählen; das Ziel kommt aus der Eingabe, die Obergrenze ist das Doppelte" do
      s = geschrieben()

      # „In der Werkstatt“ (3) + 7 + 5 Wörter.
      assert Stand.woerter(s) == 15
      assert Stand.woerter_text(s) == "15 Wörter — Ziel 150, höchstens 300"
      refute Stand.ueber_ziel?(s)
      refute Stand.ueber_obergrenze?(s)
      assert stand(max_woerter: 120).max_woerter == 120
      assert Stand.obergrenze(stand(max_woerter: 120)) == 240
    end

    test "jede Antwort des Schreibens nennt den Wortstand" do
      {s, {:ok, a}} =
        absatz(stand(), [satz("Der Alte zeigt die Spieldose.", ["S2-F1"])], "In der Werkstatt")

      assert m(a)["woerter"] == "8 Wörter — Ziel 150, höchstens 300"
      assert m(a)["woerter_je_absatz"] == ["Absatz 1: 8 Wörter"]
      refute Map.has_key?(m(a), "warnung")

      {s, {:ok, a}} = absatz(s, [satz("Dann geht es nach Norden.", ["S2-F4"])])
      assert m(a)["woerter"] == "13 Wörter — Ziel 150, höchstens 300"
      assert m(a)["woerter_je_absatz"] == ["Absatz 1: 8 Wörter", "Absatz 2: 5 Wörter"]

      {s, {:ok, a}} =
        Entwurf.absatz_ersetzen(s, %{
          "nummer" => 2,
          "saetze" => [satz("Dann reist sie nach Norden.", ["S2-F4"])]
        })

      assert m(a)["woerter"] == "13 Wörter — Ziel 150, höchstens 300"

      {_s, {:ok, t}} = Entwurf.entwurf(s, %{})

      assert t =~
               "Länge: 13 Wörter — Ziel 150, höchstens 300. Je Absatz: Absatz 1: 8 Wörter, " <>
                 "Absatz 2: 5 Wörter."

      assert t =~ "Absatz 2 (Fließtext) · 5 Wörter\n"

      {_s, {:ok, a}} = Entwurf.absatz_streichen(s, %{"nummer" => 2})
      assert m(a)["woerter"] == "8 Wörter — Ziel 150, höchstens 300"
      assert m(a)["woerter_je_absatz"] == ["Absatz 1: 8 Wörter"]
    end

    test "über dem Ziel: absatz warnt, fertig verlangt die laenge_begruendung, mit ihr geht es durch" do
      s = stand(max_woerter: 30)

      {s, {:ok, a}} =
        absatz(s, [satz(woerter(20), ["S2-F1"]), satz(woerter(15), ["S2-F4"])])

      assert m(a)["woerter"] == "35 Wörter — Ziel 30, höchstens 60"
      assert m(a)["warnung"] =~ "35 Wörter — Ziel 30, höchstens 60 — über dem Ziel"
      assert m(a)["warnung"] =~ "laenge_begruendung"
      refute m(a)["warnung"] =~ "OBERGRENZE"

      {_s, {:ok, t}} = Entwurf.entwurf(s, %{})

      assert t =~
               "Länge: 35 Wörter — Ziel 30, höchstens 60 — über dem Ziel; bis 60 nur, wenn " <>
                 "der Weg der Gruppe es braucht"

      assert Zusammenfassung.text(s) =~ "nenn beim Abschluss die laenge_begruendung"

      # Beide Handlungsbögen und die Station sind erzählt — es fehlt die Begründung.
      {s, {:error, a}} = fertig(s, 1, 2)
      assert [h] = m(a)["offen"]
      assert h =~ "liegt über dem Ziel"
      assert h =~ "laenge_begruendung"

      # Leerraum ist keine Begründung.
      {s, {:error, _}} = fertig(s, 1, 2, [], "   ")

      {s, {:halt, _}} = fertig(s, 1, 2, [], " Sieben Stationen, jede braucht ihren Satz. ")
      assert s.laenge_begruendung == "Sieben Stationen, jede braucht ihren Satz."

      assert {"abschluss.jsonl",
              %{
                "abschluss" => true,
                "laenge_begruendung" => "Sieben Stationen, jede braucht ihren Satz.",
                "woerter" => 35,
                "max_woerter" => 30,
                "obergrenze" => 60
              }} = List.last(Stand.journal_liste(s))

      assert %{
               "woerter" => 35,
               "max_woerter" => 30,
               "obergrenze" => 60,
               "laenge_begruendung" => "Sieben Stationen, jede braucht ihren Satz."
             } = Ergebnis.zaehlwerte(s)

      assert Stand.abbild(s)["laenge_begruendung"] == "Sieben Stationen, jede braucht ihren Satz."
    end

    test "über der Obergrenze: absatz trägt ein und warnt deutlich, fertig lehnt auch mit Begründung ab" do
      s = stand(max_woerter: 30)

      {s, {:ok, a}} =
        absatz(s, [satz(woerter(40), ["S2-F1"]), satz(woerter(25), ["S2-F4"])])

      # Eingetragen — sonst ließe sich nie umformulieren —, aber laut.
      assert length(s.entwurf) == 1
      assert m(a)["woerter"] == "65 Wörter — Ziel 30, höchstens 60"
      assert m(a)["warnung"] =~ "65 Wörter — Ziel 30, höchstens 60 — ÜBER DER OBERGRENZE"
      assert m(a)["warnung"] =~ "fertig() lehnt ab"

      {_s, {:ok, t}} = Entwurf.entwurf(s, %{})
      assert t =~ "Länge: 65 Wörter — Ziel 30, höchstens 60 — über der Obergrenze, kürze ihn."

      assert Zusammenfassung.text(s) =~
               "Der Entwurf hat 65 Wörter — Ziel 30, höchstens 60. Kürze ihn"

      {s, {:error, a}} = fertig(s, 1, 2, [], "Der Weg ist lang.")
      assert [h] = m(a)["offen"]
      assert h =~ "Über 60 Wörter geht es nicht"
      assert h =~ "ausgelassen"

      {s, {:ok, a}} =
        Entwurf.absatz_ersetzen(s, %{
          "nummer" => 1,
          "saetze" => [satz(woerter(20), ["S2-F1"]), satz(woerter(5), ["S2-F4"])]
        })

      refute Map.has_key?(m(a), "warnung")
      assert {_s, {:halt, _}} = fertig(s, 1, 2)
    end

    test "genau am Ziel geht fertig ohne Begründung durch; der Titel zählt mit" do
      s = stand(max_woerter: 30)

      {s, {:ok, _}} =
        absatz(s, [satz(woerter(10), ["S2-F1"]), satz(woerter(10), ["S2-F4"])], woerter(10))

      assert Stand.woerter(s) == 30
      assert {_s, {:halt, _}} = fertig(s, 1, 2)

      {s, {:ok, a}} =
        Entwurf.absatz_ersetzen(s, %{
          "nummer" => 1,
          "titel" => woerter(11),
          "saetze" => [satz(woerter(10), ["S2-F1"]), satz(woerter(10), ["S2-F4"])]
        })

      assert m(a)["warnung"] =~ "31 Wörter — Ziel 30, höchstens 60 — über dem Ziel"
      assert {_s, {:error, _}} = fertig(s, 1, 2)
      assert {_s, {:halt, _}} = fertig(s, 1, 2, [], "Der Weg braucht das eine Wort.")
    end

    test "fertig nennt Ziel und Obergrenze in seiner Beschreibung; das Abbild den Wortstand" do
      [f] = Abschluss.werkzeuge(stand())
      assert f.beschreibung =~ "mehr als 300 Wörter"
      assert f.beschreibung =~ "Ziel von 150 Wörtern ohne laenge_begruendung"

      assert %{
               "woerter" => 15,
               "max_woerter" => 150,
               "obergrenze" => 300,
               "laenge_begruendung" => nil,
               "gliederung_ohne_satz" => [],
               "entwurf" => %{"woerter" => 15}
             } = Stand.abbild(geschrieben())
    end
  end

  # #1209: der Weg der Gruppe muss aus dem Resümee ersichtlich sein.
  describe "Der Weg der Gruppe (#1209)" do
    test "jede Station braucht einen Satz mit einem ihrer Fakten dieser Sitzung" do
      s = Stand.fuer_schreiben(eingabe(), weg_ablage())

      # „3“ nennt nur einen früheren Fakt und zählt nicht.
      assert Enum.map(Weg.ohne_satz(s), & &1.schluessel) == ["1", "2"]

      # Ein Rückblick trägt keine Station.
      {s, {:ok, a}} =
        absatz(s, [
          satz("Der Alte zeigt die Spieldose.", ["S2-F1"]),
          satz("Tess nahm den Auftrag an.", ["S1-F1"], %{"rueckblick" => true})
        ])

      assert m(a)["stationen_ohne_satz"] == ["2 — Reise nach Norden"]

      {_s, {:ok, t}} = Entwurf.entwurf(s, %{})

      assert t =~
               "Weg der Gruppe: 1 von 2 Stationen deiner GLIEDERUNG haben einen Satz. Noch " <>
                 "ohne Satz: „2“ — Reise nach Norden."

      {_s, {:error, f}} = fertig(s, 1, 2)
      assert [h, _bogen] = m(f)["offen"]

      assert h =~
               "Diese Stationen deiner GLIEDERUNG erzählt noch kein Satz: „2“ — Reise nach Norden."

      assert Zusammenfassung.text(s) =~
               "Diese Stationen haben noch keinen Satz: „2“ — Reise nach Norden."

      station = [%{"schluessel" => "2", "zeile" => "Reise nach Norden"}]
      assert Stand.abbild(s)["gliederung_ohne_satz"] == station
      assert Ergebnis.zaehlwerte(s)["gliederung_ohne_satz"] == station

      # Ein Satz darf zwei Stationen tragen, wenn er ihre Fakten nennt.
      {s, {:ok, a}} =
        Entwurf.absatz_ersetzen(s, %{
          "nummer" => 1,
          "saetze" => [
            satz("Der Alte zeigt die Spieldose, dann reist die Gruppe nach Norden.", [
              "S2-F1",
              "S2-F4"
            ])
          ]
        })

      refute Map.has_key?(m(a), "stationen_ohne_satz")

      {_s, {:ok, t}} = Entwurf.entwurf(s, %{})
      assert t =~ "Weg der Gruppe: jede der 2 Stationen deiner GLIEDERUNG hat einen Satz."
      assert {_s, {:halt, _}} = fertig(s, 1, 1)
    end

    test "leerer Entwurf: das Hindernis ist der leere Entwurf, nicht jede Station einzeln" do
      {_s, {:error, a}} = fertig(Stand.fuer_schreiben(eingabe(), weg_ablage()), 0, 0)
      refute Enum.any?(m(a)["offen"], &(&1 =~ "Stationen"))
    end

    test "fertig ist streng: laenge_begruendung ist Pflicht, leer erlaubt" do
      {:ok, h} = Halter.start_link(stand())
      by = h |> Werkzeuge.fuer() |> Map.new(&{&1.name, &1})

      assert {:error, [f]} =
               Schema.pruefen(by["fertig"].parameter, %{
                 "absaetze" => 0,
                 "saetze" => 0,
                 "ausgelassen" => [],
                 "offen_geblieben" => ""
               })

      assert f =~ "laenge_begruendung: fehlt"

      assert {:ok, _} =
               Schema.pruefen(by["fertig"].parameter, %{
                 "absaetze" => 0,
                 "saetze" => 0,
                 "ausgelassen" => [],
                 "laenge_begruendung" => "",
                 "offen_geblieben" => ""
               })

      Agent.stop(h)
    end
  end

  describe "fertig im Schreiben" do
    test "lehnt ab, solange der Entwurf leer ist, und nennt die Handlungsbögen ohne Satz" do
      {s, {:error, a}} = fertig(stand(), 0, 0)
      offen = m(a)["offen"]

      assert [leer, boegen] = offen
      assert leer =~ "Der Entwurf ist leer"
      assert boegen =~ "#{@uhrmacher}, #{@salz}"
      refute boegen =~ @arnheim
      assert s.abschluss_zahlversuche == 0
    end

    test "ein Handlungsbogen fehlt: erzählen oder begründet auslassen" do
      {s, {:ok, _}} = absatz(stand(), [satz("Der Alte zeigt die Spieldose.", ["S2-F1"])])

      {_s, {:error, a}} = fertig(s, 1, 1)
      assert [h] = m(a)["offen"]
      assert h =~ "kein Satz nennt einen ihrer Fakten dieser Sitzung: #{@salz}."

      assert {s, {:halt, _}} =
               fertig(s, 1, 1, [%{"bogen" => "die salzmine", "grund" => "Nur ein Satz Reise."}])

      assert {"abschluss.jsonl", %{"abschluss" => true, "lauf" => "schreiben"} = e} =
               List.last(Stand.journal_liste(s))

      assert e["ausgelassen"] == [%{"bogen" => "die salzmine", "grund" => "Nur ein Satz Reise."}]
    end

    test "ein Rückblick auf einen früheren Fakt desselben Bogens erzählt ihn nicht" do
      {s, {:ok, _}} =
        absatz(stand(), [
          satz("Tess nahm den Auftrag an.", ["S1-F1"], %{"rueckblick" => true}),
          satz("Dann geht es nach Norden.", ["S2-F4"])
        ])

      assert Stand.arc_ohne_satz(s) == [@uhrmacher]
    end

    test "ausgelassen: nur Handlungsbögen dieser Sitzung, jeder mit Grund" do
      s = geschrieben()

      {_s, {:error, a}} =
        fertig(s, 1, 2, [
          %{"bogen" => @arnheim, "grund" => "Hintergrund"},
          %{"bogen" => "Die Drachenhöhle", "grund" => "gibt es nicht"},
          %{"bogen" => @salz, "grund" => "   "}
        ])

      assert [art, unbekannt, grund] = m(a)["offen"]
      assert art =~ "„#{@arnheim}“ hat die Art context"
      assert unbekannt =~ "„Die Drachenhöhle“ ist kein Bogen dieser Sitzung"
      assert grund =~ "für „#{@salz}“ fehlt der Grund"
    end

    test "falsche Zahlen: die Ablehnung verrät die richtigen nicht, der dritte Versuch geht durch" do
      s = geschrieben()

      {s, {:error, a}} = fertig(s, 1, 3)

      assert m(a)["abweichung"] == [
               "saetze: du sagst 3 — das stimmt nicht mit der Buchhaltung überein"
             ]

      refute Jason.encode!(a) =~ "2"

      {s, {:error, _}} = fertig(s, 1, 3)
      {s, {:halt, a}} = fertig(s, 1, 3)

      assert m(a)["zahlen"] == %{"absaetze" => 1, "saetze" => 2}

      assert {"abschluss.jsonl", %{"zahlen_stimmten" => "nein", "abweichung" => [abw]}} =
               List.last(Stand.journal_liste(s))

      assert abw == "saetze: du sagst 3, gezaehlt sind 2"
    end

    test "richtige Zahlen: abgeschlossen" do
      assert {_s, {:halt, a}} = fertig(geschrieben(), 1, 2)
      assert %{"ok" => true, "fertig" => true} = m(a)
    end
  end

  describe "Werkzeuge, Halter, Zusammenfassung im Schreiben" do
    test "der Werkzeugsatz: Lesen, notizen_lesen, Entwurf, fertig — kein notiz" do
      assert Werkzeuge.namen(stand()) ==
               ~w(fakten fakt boegen boegen_kampagne vorige_resuemees vorige_kapitel
                  vorige_gedanken bloecke block suche_sitzung suche_bisher cast straenge
                  notizen_lesen entwurf absatz absatz_ersetzen absatz_streichen fertig)

      # Der Überblick bleibt, wie er war (E0, #1210: dieselbe Lesebasis).
      assert Werkzeuge.namen(Stand.neu(eingabe())) ==
               ~w(fakten fakt boegen boegen_kampagne vorige_resuemees vorige_kapitel
                  vorige_gedanken bloecke block suche_sitzung suche_bisher cast straenge
                  notiz notizen_lesen fertig)
    end

    test "streng angelegt: Pflichtfelder, optional nur Titel und Markierungen" do
      {:ok, h} = Halter.start_link(stand())
      by = h |> Werkzeuge.fuer() |> Map.new(&{&1.name, &1})

      assert by["absatz"].parameter["required"] == ["saetze"]

      assert by["absatz"].parameter["properties"]["saetze"]["items"]["required"] ==
               ~w(fakten text)

      assert by["absatz_ersetzen"].parameter["required"] == ~w(nummer saetze)
      assert by["absatz_streichen"].parameter["required"] == ["nummer"]

      assert by["fertig"].parameter["required"] ==
               ~w(absaetze ausgelassen laenge_begruendung offen_geblieben saetze)

      assert by["fertig"].parameter["properties"]["ausgelassen"]["items"]["required"] ==
               ~w(bogen grund)

      assert by["entwurf"].wiederholung == :frei
      assert by["absatz"].aendert_bestand

      # Ein Satz ohne fakten und ein leerer Titel scheitern schon am Schema.
      assert {:error, [f]} =
               Schema.pruefen(by["absatz"].parameter, %{"saetze" => [%{"text" => "x"}]})

      assert f =~ "saetze.0.fakten: fehlt"

      assert {:error, [f]} =
               Schema.pruefen(by["absatz"].parameter, %{
                 "titel" => "",
                 "saetze" => [satz("x", ["S2-F1"])]
               })

      assert f =~ "titel: mindestens 1"

      # Über den Halter: der Absatz landet im Stand, der Beobachter bekommt ihn.
      assert {:ok, _} = by["absatz"].ausfuehren.(%{"saetze" => [satz("x", ["S2-F1"])]})
      assert [%{saetze: [_]}] = Halter.stand(h).entwurf
      Agent.stop(h)
    end

    test "der Halter meldet den Entwurf" do
      {:ok, h} = Halter.start_link(stand(), beobachter: self())

      assert_receive {:jack_resuemee_stand,
                      %{"lauf" => "schreiben", "entwurf" => %{"absaetze" => 0}} = abbild}

      assert abbild["arc_ohne_satz"] == [@uhrmacher, @salz]

      Halter.aufrufen(h, &Entwurf.absatz/2, %{
        "saetze" => [
          satz("So viel zur Vorgeschichte.", [], %{"uebergang" => true}),
          satz("Der Alte zeigt die Spieldose.", ["S2-F1"])
        ]
      })

      assert_receive {:jack_resuemee_stand,
                      %{
                        "entwurf" => %{
                          "absaetze" => 1,
                          "saetze" => 2,
                          "uebergaenge" => 1,
                          "rueckblicke" => 0
                        },
                        "arc_ohne_satz" => [@salz]
                      }}

      Agent.stop(h)
    end

    test "notizen_lesen und boegen sprechen vom Schreiben" do
      {_s, {:ok, a}} = Notizen.notizen_lesen(geschrieben(), %{})
      a = m(a)

      assert a["stand"] =~ "Entwurf: 1 Absätze, 2 Sätze"
      assert a["notizen"] =~ "## FORM\nForm — chronologische Nacherzählung"

      defs = Map.new(Notizen.werkzeuge(stand()), &{&1.name, &1})
      assert defs["notizen_lesen"].beschreibung =~ "aus dem Überblick"

      {_s, {:ok, t}} = Lesen.boegen(stand(), %{})
      assert t =~ "fertig(ausgelassen)"
      refute t =~ "GLIEDERUNG"
    end

    test "die Zusammenfassung trägt Ton, Notizen, den gekürzten Entwurf und den nächsten Schritt" do
      t = Zusammenfassung.text(stand(flavor: %{base: "Düster.", summary: nil}))

      assert t =~ "## Ton\n**Grundton der Kampagne:** Düster."
      assert t =~ "## Deine Notizen aus dem Überblick\n## FORM"
      assert t =~ "(noch kein Absatz)"
      assert t =~ "Schreib den ersten Absatz nach deiner GLIEDERUNG mit absatz()."

      {s, {:ok, _}} =
        absatz(stand(), [satz(woerter(40), ["S2-F1"])], "In der Werkstatt")

      t = Zusammenfassung.text(s)
      assert t =~ "1. — In der Werkstatt: #{woerter(30)} … (1 Sätze)"
      assert t =~ "noch keinen Satz mit einem ihrer Fakten: #{@salz}"

      assert Zusammenfassung.text(geschrieben()) =~ "schließ mit fertig() ab."
    end
  end

  describe "Ergebnis" do
    test "markdown: Absätze durch Leerzeile, der Titel als fette Zeile davor" do
      {s, {:ok, _}} = absatz(geschrieben(), [satz("Mira erkennt das Wappen.", ["S2-F3"])])

      assert Ergebnis.markdown(s) ==
               "**In der Werkstatt**\nDer Alte zeigt der Gruppe eine Spieldose. " <>
                 "Danach geht es nach Norden.\n\nMira erkennt das Wappen."

      assert Ergebnis.markdown(stand()) == ""
    end

    test "markdown: Titel maskiert, ein Absatz beginnt nie als Liste oder Überschrift" do
      {s, {:ok, _}} =
        absatz(stand(), [satz("3. Mai: die Gruppe reist.", ["S2-F4"])], "Der *Plan*")

      {s, {:ok, _}} = absatz(s, [satz("# Kein Kopf.", ["S2-F1"])])
      {s, {:ok, _}} = absatz(s, [satz("- auch keine Liste.", ["S2-F2"])])

      assert Ergebnis.markdown(s) ==
               "**Der \\*Plan\\***\n3\\. Mai: die Gruppe reist.\n\n\\# Kein Kopf.\n\n" <>
                 "\\- auch keine Liste."
    end

    test "satzquellen: je Satz die echten Fakt-IDs" do
      {s, {:ok, _}} =
        absatz(stand(), [
          satz("Tess nahm den Auftrag an.", ["S1-F1"], %{"rueckblick" => true}),
          satz("So viel dazu.", [], %{"uebergang" => true}),
          satz("Der Alte zeigt die Spieldose.", ["S2-F1", "S2-F2"])
        ])

      assert [
               %{absatz: 1, satz: 1, fakt_ids: ["f_frueh"], rueckblick: true, uebergang: false},
               %{absatz: 1, satz: 2, fakt_ids: [], fakten: [], uebergang: true},
               %{
                 absatz: 1,
                 satz: 3,
                 text: "Der Alte zeigt die Spieldose.",
                 fakten: ["S2-F1", "S2-F2"],
                 fakt_ids: ["f_a", "f_b"]
               }
             ] = Ergebnis.satzquellen(s)
    end

    test "zaehlwerte: Sätze, Übergänge, Rückblicke und die abgelehnten Sätze je Grund" do
      {s, {:error, _}} =
        absatz(stand(), [
          satz("x", ["S1-F1"]),
          satz("y", ["S2-F1"], %{"uebergang" => true, "rueckblick" => true})
        ])

      {s, {:error, _}} = absatz(s, [satz("z", ["S2-F1"])], "   ")

      {s, {:ok, _}} =
        absatz(s, [
          satz("So viel dazu.", [], %{"uebergang" => true}),
          satz("Der Alte zeigt die Spieldose.", ["S2-F1"])
        ])

      assert Ergebnis.zaehlwerte(s) == %{
               "absaetze" => 1,
               "saetze" => 2,
               "uebergaenge" => 1,
               "rueckblicke" => 0,
               "woerter" => 8,
               "max_woerter" => 150,
               "obergrenze" => 300,
               "laenge_begruendung" => nil,
               "gliederung_ohne_satz" => [],
               "fakten" => 4,
               "fakten_im_text" => 1,
               "abgelehnte_absaetze" => 2,
               "abgelehnte_saetze" => 2,
               "gruende" => %{
                 "rueckblick_fehlt" => 1,
                 "uebergang_mit_fakten" => 1,
                 "rueckblick_mit_fakt_dieser_sitzung" => 1,
                 "titel_leer" => 1
               }
             }
    end
  end
end
