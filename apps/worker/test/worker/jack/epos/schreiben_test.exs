defmodule Worker.Jack.Epos.SchreibenTest do
  # J6 (#1210, E2): das Schreiben des Epos-Jack, rein auf dem Stand — kein
  # Mnesia, kein Modell. Der Epos-Jack schreibt frei (Maintainer, 13.09.2026):
  # Absätze aus freier Prosa, optional mit Szene; keine Prüfung je Satz, keine
  # Länge, keine Pflicht, jede Szene zu erzählen. Beispiele aus der Demo-Welt.
  use ExUnit.Case, async: true

  alias Worker.Agent.Schema
  alias Worker.Jack.Epos.{Abschluss, Entwurf, Ergebnis, Notizen, Werkzeuge, Zusammenfassung}
  alias Worker.Jack.Resuemee.{Eingabe, Halter, Stand}

  @uhrmacher "Der verschwundene Uhrmacher"

  # 18 Wörter.
  @regen "Der Regen hing wie ein grauer Vorhang über dem Hafen. Tess schob den Brief unter " <>
           "der Tür hindurch."

  defp roh(id, claim, refs),
    do: %{
      "id" => id,
      "claim" => claim,
      "source_refs" => refs,
      "fact_type" => "ereignis",
      "narration_time" => "present",
      "verified?" => true
    }

  defp eingabe do
    arc = [%{titel: @uhrmacher, kind: "arc"}]
    zuordnung = %{"f_a" => arc, "f_c" => arc, "f_frueh" => arc}

    fakten =
      Eingabe.fakten(
        [
          roh("f_a", "Die Gruppe steht im Regen vor der Werkstatt am Hafen.", ["b0"]),
          roh("f_b", "Der Alte öffnet, als Tess den Brief zeigt.", ["b1"]),
          roh("f_c", "Der Alte zeigt eine Spieldose mit einem Wappen.", ["b2"])
        ],
        2,
        zuordnung,
        %{"b0" => 0, "b1" => 1, "b2" => 2}
      )

    frueh =
      Eingabe.fakten(
        [roh("f_frueh", "Tess nimmt den Brief des Uhrmachers an.", ["x"])],
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
        %{text: "Der Alte zeigt euch eine Spieldose.", sprecher: "SL", block_id: "b2"}
      ],
      cast: ["Mira", "Tess"],
      straenge: [@uhrmacher],
      ueberschrift: "Heldenlied",
      flavor: %{base: "Düster", epos: "Nah an der Gruppe."}
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
        n("OFFEN", "Anschluss", "das vorige Kapitel endet mit dem Brief")
      ]
    }
  end

  defp stand(a \\ ablage()), do: Stand.fuer_schreiben(eingabe(), a)

  defp j(o), do: o |> Jason.encode!() |> Jason.decode!()

  defp absatz(s, p), do: Entwurf.absatz(s, p)

  defp mit_regen(s \\ stand()) do
    {s, {:ok, _}} = absatz(s, %{"text" => @regen, "szene" => "Regen am Hafen"})
    s
  end

  defp woerter(n), do: 1..n |> Enum.map(fn _ -> "Wort" end) |> Enum.join(" ")

  defp fertig(s, absaetze),
    do: Abschluss.fertig(s, %{"absaetze" => absaetze, "offen_geblieben" => ""})

  describe "Stand und Werkzeuge" do
    test "der Stand des Schreibens: frisch, mit den Notizen des Überblicks" do
      s = stand()

      assert s.art == :epos
      assert s.lauf == :schreiben
      assert s.entwurf == []
      assert s.gelesen == MapSet.new()
      assert Stand.form(s).zeile == "Heldenlied in Szenen, nah an der Gruppe"
      assert length(Stand.abschnitt(s, "SZENEN")) == 2
    end

    test "streng: text Pflicht, titel und szene optional, keine Markierungen" do
      s = stand()

      assert Werkzeuge.namen(s) ==
               Worker.Jack.Resuemee.Werkzeuge.lesend() ++
                 ~w(resuemee notizen_lesen entwurf absatz absatz_ersetzen absatz_streichen fertig)

      {:ok, h} = Halter.start_link(s)
      by = h |> Werkzeuge.fuer() |> Map.new(&{&1.name, &1})

      refute Map.has_key?(by, "notiz")
      assert by["absatz"].parameter["required"] == ["text"]
      assert Enum.sort(Map.keys(by["absatz"].parameter["properties"])) == ~w(szene text titel)
      assert Enum.sort(by["absatz_ersetzen"].parameter["required"]) == ~w(nummer text)
      assert by["absatz_streichen"].parameter["required"] == ["nummer"]
      assert Enum.sort(by["fertig"].parameter["required"]) == ~w(absaetze offen_geblieben)
      assert by["entwurf"].wiederholung == :frei
      assert by["fertig"].wiederholung == :frei
      assert by["absatz"].aendert_bestand
      assert by["notizen_lesen"].beschreibung =~ "wo das Kapitel steht"
      assert by["resuemee"].beschreibung =~ "Zum Nachlesen"

      # Markierungen gibt es nicht: ein fremdes Feld scheitert am Schema, der
      # Text ist Pflicht.
      assert {:error, fehler} =
               Schema.pruefen(by["absatz"].parameter, %{"text" => "x", "farbe" => true})

      assert Enum.any?(fehler, &(&1 =~ "farbe"))

      assert {:error, fehler} = Schema.pruefen(by["absatz"].parameter, %{"titel" => "x"})
      assert Enum.any?(fehler, &(&1 =~ "text"))

      # Über den Halter landet der Absatz im Stand.
      assert {:ok, _} =
               by["absatz"].ausfuehren.(%{"text" => "Regen.", "szene" => "Die Spieldose"})

      assert [%{titel: nil, text: "Regen.", szene: "Die Spieldose"}] = Halter.stand(h).entwurf
      Agent.stop(h)
    end
  end

  describe "absatz" do
    test "freie Prosa, Leerraum zusammengezogen, Szene in der Schreibweise der Notiz" do
      {s, {:ok, a}} =
        absatz(stand(), %{
          "text" => "  Der Regen hing\n über dem Hafen.  \n\n Tess klopfte. ",
          "titel" => " Am  Hafen ",
          "szene" => " regen AM hafen "
        })

      assert [
               %{
                 titel: "Am Hafen",
                 text: "Der Regen hing über dem Hafen. Tess klopfte.",
                 szene: "Regen am Hafen"
               }
             ] = s.entwurf

      a = j(a)
      assert a["ok"] == true
      assert a["absatz"] == 1
      assert a["szene"] == "Regen am Hafen"
      assert a["entwurf"] == "1 Absatz"
      assert a["woerter"] == "10 Wörter"
      assert a["woerter_je_absatz"] == ["Absatz 1: 10 Wörter"]

      assert a["hinweis_szenen"] ==
               "Noch keinem Absatz zugeordnet — ein Hinweis, keine Pflicht: „Die Spieldose“ " <>
                 "— im Licht der Lampe."

      assert a["hinweis"] == "Eingetragen als Absatz 1."

      # Keine Länge, kein Anteil, keine Warnung.
      refute Map.has_key?(a, "warnung")
      refute Jason.encode!(a) =~ "mindestens"

      assert [{"entwurf_verlauf.jsonl", %{"art" => "+", "neu" => %{"szene" => "Regen am Hafen"}}}] =
               Stand.journal_liste(s)
    end

    test "ohne Szene geht es auch; ist jeder Szene ein Absatz zugeordnet, fällt der Hinweis weg" do
      {s, {:ok, a}} = absatz(mit_regen(), %{"text" => "Die Lampe flackerte."})
      assert j(a)["hinweis_szenen"] =~ "„Die Spieldose“"
      assert List.last(s.entwurf).szene == nil
      refute Map.has_key?(j(a), "szene")

      {_s, {:ok, a}} =
        absatz(s, %{"text" => "Der Alte zog die Spieldose auf.", "szene" => "Die Spieldose"})

      refute Map.has_key?(j(a), "hinweis_szenen")
    end

    test "abgelehnt: leer, leerer Titel, unbekannte Szene — alle Gründe auf einmal, nichts eingetragen" do
      s = stand()

      {s2, {:error, a}} = absatz(s, %{"text" => "   ", "titel" => "  ", "szene" => "Der Keller"})
      a = j(a)

      assert a["ok"] == false
      assert a["hinweis"] =~ "Nichts eingetragen."
      [leer, titel, szene] = a["gruende"]
      assert leer =~ "Der Absatz ist leer."
      assert titel =~ "Der Titel ist leer."

      assert szene =~
               "Eine Szene „Der Keller“ gibt es in deinen Notizen nicht. Deine Szenen heißen: " <>
                 "„Regen am Hafen“, „Die Spieldose“."

      assert s2.entwurf == []

      assert [{"entwurf_verlauf.jsonl", %{"art" => "abgelehnt", "gruende" => gruende}}] =
               Stand.journal_liste(s2)

      assert gruende == ~w(leer titel_leer szene_unbekannt)
    end

    test "höchstens 400 Wörter je Absatz und 12 je Titel" do
      s = stand()
      assert {_s, {:ok, _}} = absatz(s, %{"text" => woerter(400), "titel" => woerter(12)})

      {_s, {:error, a}} = absatz(s, %{"text" => woerter(401), "titel" => woerter(13)})
      [text, titel] = j(a)["gruende"]
      assert text =~ "Der Absatz hat 401 Wörter, ein Absatz hat höchstens 400."
      assert titel =~ "Der Titel hat 13 Wörter, eine Überschrift hat höchstens 12."
    end

    test "ohne SZENEN in den Notizen: keine Szene zuzuordnen, und kein Hinweis" do
      ohne = stand(%{"notizen" => [n("FORM", "Form", "Epos")]})

      {_s, {:error, a}} = absatz(ohne, %{"text" => "Regen.", "szene" => "Regen"})
      assert hd(j(a)["gruende"]) =~ "in deinen Notizen stehen keine SZENEN"

      {_s, {:ok, a}} = absatz(ohne, %{"text" => "Regen."})
      refute Map.has_key?(j(a), "hinweis_szenen")
    end
  end

  describe "absatz_ersetzen, absatz_streichen" do
    test "ersetzen, gleich bleiben, streichen — die Nummern rücken nach" do
      s = mit_regen()
      {s, {:ok, _}} = absatz(s, %{"text" => "Die Lampe flackerte."})

      {_s, {:error, t}} =
        Entwurf.absatz_ersetzen(s, %{
          "nummer" => 1,
          "text" => @regen,
          "szene" => "regen am hafen"
        })

      assert t =~ "Absatz 1 steht bereits genau so"

      # Ersetzt wird der ganze Absatz: die weggelassene Szene ist danach weg.
      {s, {:ok, a}} =
        Entwurf.absatz_ersetzen(s, %{"nummer" => 1, "text" => "Der Regen ließ nach."})

      assert j(a)["hinweis"] == "Absatz 1 ersetzt."
      assert %{text: "Der Regen ließ nach.", szene: nil} = hd(s.entwurf)

      {_s, {:error, t}} = Entwurf.absatz_ersetzen(s, %{"nummer" => 3, "text" => "x"})
      assert t =~ "Das Kapitel hat die Absätze 1 bis 2"

      {s, {:ok, a}} = Entwurf.absatz_streichen(s, %{"nummer" => 1})
      a = j(a)
      assert a["gestrichen"] == 1
      assert a["entwurf"] == "1 Absatz"
      assert a["hinweis"] =~ "der bisherige Absatz 2 ist jetzt Absatz 1"
      assert [%{text: "Die Lampe flackerte."}] = s.entwurf

      {s, {:ok, a}} = Entwurf.absatz_streichen(s, %{"nummer" => 1})
      assert j(a)["woerter"] == "0 Wörter"
      refute Map.has_key?(j(a), "woerter_je_absatz")

      {s, {:error, t}} = Entwurf.absatz_streichen(s, %{"nummer" => 1})
      assert t =~ "das Kapitel ist noch leer"

      assert for({"entwurf_verlauf.jsonl", e} <- Stand.journal_liste(s), do: e["art"]) ==
               ~w(+ + ~ - -)
    end
  end

  describe "entwurf und notizen_lesen" do
    test "leer: ein Satz dazu und die Szenen als Hinweis" do
      assert Entwurf.entwurf_text(stand()) ==
               "Das Kapitel ist noch leer. Erzähl die erste Szene mit absatz().\n" <>
                 "Szenen: 0 von 2 Szenen deiner Notizen ist ein Absatz zugeordnet. Noch ohne " <>
                 "Absatz — ein Hinweis, keine Pflicht: „Regen am Hafen“ — Nacht, Regen, vor der " <>
                 "Werkstatt; „Die Spieldose“ — im Licht der Lampe."
    end

    test "jeder Absatz mit Titel, Wortzahl, Szene und Text; der Stand vorn" do
      s = mit_regen()
      {s, {:ok, _}} = absatz(s, %{"text" => "Die Lampe flackerte.", "titel" => "Die Werkstatt"})

      {_s, {:ok, t}} = Entwurf.entwurf(s, %{})

      assert t =~
               "Kapitel: 2 Absätze, 23 Wörter. Je Absatz: Absatz 1: 18 Wörter, Absatz 2: " <>
                 "5 Wörter."

      assert t =~
               "Szenen: 1 von 2 Szenen deiner Notizen ist ein Absatz zugeordnet. Noch ohne " <>
                 "Absatz — ein Hinweis, keine Pflicht: „Die Spieldose“ — im Licht der Lampe."

      assert t =~ "Absatz 1 (Fließtext) · 18 Wörter · Szene „Regen am Hafen“\n" <> @regen
      assert t =~ "Absatz 2 — Die Werkstatt · 5 Wörter · ohne Szene\nDie Lampe flackerte."

      {_s, {:ok, a}} = Notizen.notizen_lesen(s, %{})
      a = j(a)

      assert a["stand"] =~
               "Sitzung 2. Die Epos-Spalte heißt „Heldenlied“.\nKapitel: 2 Absätze, 23 Wörter."

      assert a["notizen"] =~ "## FORM\nForm — Heldenlied in Szenen, nah an der Gruppe"

      assert a["notizen"] =~
               "## SZENEN\nRegen am Hafen — Nacht, Regen, vor der Werkstatt  [Fakten: S2-F1, " <>
                 "S2-F2, S1-F1]"
    end

    test "jede Szene mit Absatz: die Zeile sagt es" do
      s = mit_regen()
      {s, {:ok, _}} = absatz(s, %{"text" => "Die Spieldose.", "szene" => "Die Spieldose"})

      assert Entwurf.stand_zeilen(s) =~
               "Szenen: jeder der 2 Szenen deiner Notizen ist ein Absatz zugeordnet."
    end
  end

  describe "fertig" do
    test "lehnt nur ein Kapitel ohne Absatz ab — keine Länge, keine Szenen-Pflicht" do
      {s, {:error, a}} = fertig(stand(), 0)
      assert [h] = j(a)["offen"]
      assert h =~ "Das Kapitel hat noch keinen Absatz."

      # Ein kurzer Absatz ohne Szene genügt; keine Szene ist erzählt.
      {s, {:ok, _}} = absatz(s, %{"text" => "Kurz."})
      assert Abschluss.hindernisse(s) == []
      assert {_s, {:halt, a}} = fertig(s, 1)
      assert j(a)["zahlen"] == %{"absaetze" => 1}
    end

    test "Zahlenabgleich: welche Zahl nicht stimmt und wie sie gezählt ist; der dritte geht durch" do
      s = mit_regen()

      {s, {:error, a}} = fertig(s, 3)
      a = j(a)

      assert a["abweichung"] == [
               "absaetze: du sagst 3 — gezählt sind 1"
             ]

      refute Map.has_key?(a, "zahlen")

      {s, {:error, _}} = fertig(s, 3)
      {s, {:halt, a}} = fertig(s, 3)
      assert j(a)["zahlen"] == %{"absaetze" => 1}

      [eintrag] =
        for {"abschluss.jsonl", %{"abschluss" => true} = x} <- Stand.journal_liste(s), do: x

      assert eintrag["zahlen_stimmten"] == "nein"
      assert eintrag["abweichung"] == ["absaetze: du sagst 3, gezaehlt sind 1"]
      assert eintrag["lauf"] == "schreiben"
      assert eintrag["jack"] == "epos"
      assert eintrag["woerter"] == 18
      assert eintrag["absaetze_mit_szene"] == 1
      assert eintrag["szenen_ohne_absatz"] == ["Die Spieldose"]
    end
  end

  describe "Ergebnis" do
    test "Markdown, Quellen je Absatz über die Szene, Zählwerte" do
      {s, {:ok, _}} =
        absatz(stand(), %{
          "text" => "3. Mai: Regen am Hafen.",
          "titel" => "Der *erste* Abend",
          "szene" => "Regen am Hafen"
        })

      {s, {:ok, _}} = absatz(s, %{"text" => "Die Lampe flackerte."})

      # Titel fett und maskiert, der Anfang geschützt — ohne Kapitelkopf.
      assert Ergebnis.markdown(s) ==
               "**Der \\*erste\\* Abend**\n3\\. Mai: Regen am Hafen.\n\nDie Lampe flackerte."

      assert Ergebnis.quellen(s) == [
               %{
                 absatz: 1,
                 titel: "Der *erste* Abend",
                 szene: "Regen am Hafen",
                 fakten: ["S2-F1", "S2-F2", "S1-F1"],
                 fakt_ids: ["f_a", "f_b", "f_frueh"]
               },
               %{absatz: 2, titel: nil, szene: nil, fakten: [], fakt_ids: []}
             ]

      assert Ergebnis.zaehlwerte(s) == %{
               "absaetze" => 2,
               "woerter" => 11,
               "absaetze_mit_szene" => 1,
               "absaetze_ohne_szene" => 1,
               "szenen" => 2,
               "szenen_ohne_absatz" => 1
             }

      assert is_binary(Jason.encode!(Ergebnis.zaehlwerte(s)))
    end
  end

  describe "Abbild und Zusammenfassung" do
    test "das Abbild trägt das Kapitel" do
      a = Notizen.abbild(mit_regen())

      assert %{
               "jack" => "epos",
               "lauf" => "schreiben",
               "entwurf" => %{"absaetze" => 1, "mit_szene" => 1, "woerter" => 18},
               "woerter" => 18,
               "markdown" => @regen,
               "szenen_ohne_absatz" => [
                 %{"schluessel" => "Die Spieldose", "zeile" => "im Licht der Lampe"}
               ]
             } = a

      assert is_binary(Jason.encode!(a))
    end

    test "die Zusammenfassung trägt Stil, Stand, Notizen, das Kapitel und den nächsten Schritt" do
      s = mit_regen()
      t = Zusammenfassung.text(s)

      assert t =~ "Du erzählst das Epos-Kapitel von Sitzung 2 für die Spalte"
      assert t =~ "## Stil\nÜberschrift der Epos-Spalte: „Heldenlied“"
      assert t =~ "**Grundton der Kampagne:** Düster\n\n**Ton des Epos:** Nah an der Gruppe."

      assert t =~
               "## Wo du stehst\nSitzung 2. Die Epos-Spalte heißt „Heldenlied“.\n" <>
                 "Kapitel: 1 Absatz, 18 Wörter."

      assert t =~ "## Deine Notizen aus dem Überblick\n## FORM\nForm — Heldenlied in Szenen"

      assert t =~
               "## Dein Kapitel (gekürzt; vollständig mit entwurf())\n1. (Fließtext) · Szene " <>
                 "„Regen am Hafen“: Der Regen hing"

      assert t =~
               "## Nächster Schritt\nErzähl weiter, Szene für Szene. Noch keinem Absatz " <>
                 "zugeordnet — ein Hinweis, keine Pflicht: „Die Spieldose“"

      assert Zusammenfassung.text(stand()) =~ "## Nächster Schritt\nErzähl die erste Szene"

      {s, {:ok, _}} = absatz(s, %{"text" => "Die Spieldose.", "szene" => "Die Spieldose"})
      assert Zusammenfassung.text(s) =~ "## Nächster Schritt\nLies dein Kapitel mit entwurf()"
    end
  end
end
