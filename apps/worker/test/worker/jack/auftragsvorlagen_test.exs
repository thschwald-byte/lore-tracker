defmodule Worker.Jack.AuftragsvorlagenTest do
  # J4 (#1207): Jacks Aufträge im Repo (priv/jack/auftraege) — Vorlagen mit
  # Platzhaltern für die Blockzahlen, Beispiele aus der Demo. Aus der
  # gemessenen Session darf nichts ins Repo (Tom, 11.09.2026): die Messfassung
  # liegt nur lokal.
  use ExUnit.Case, async: true

  alias Worker.Jack.Pipeline

  @dir Path.expand("../../../priv/jack/auftraege", __DIR__)

  # Begriffe aus der gemessenen Runde, die in den Vorlagen nie stehen dürfen.
  @verboten ~w(Lucky Kodex Deadman Telestrian Romeo Johnson Barghest Bargäst Villa Matrix
               Spinne Bärbel Seattle Magier Drohne Hintertür Fahndungsstufe 2081 1801 1802)

  test "die drei Vorlagen laden und bekommen die Blockzahlen der Sitzung" do
    assert {:ok, a} = Pipeline.auftraege(40, @dir)

    for {_art, text} <- a do
      refute text =~ "{{"
      refute text =~ "1801"
    end

    assert a.phase1 =~ "**0 bis 39**"
    assert a.phase1 =~ "40 Blöcke sind keine Aufgabe"
    assert a.phase2 =~ "bei Block 39 angekommen bist."
    assert a.folgelauf =~ "Wenn Block 39 vollständig verarbeitet ist:"
  end

  # J5 (#1209, B1): der Auftrag des Resümee-Überblicks.
  test "die Resümee-Vorlage lädt und bekommt die Angaben der Sitzung" do
    eingabe = %{
      sitzung: %{nummer: 4},
      fakten: [%{}, %{}, %{}],
      fruehere: [%{nummer: 2}, %{nummer: 3}],
      bloecke: List.duplicate(%{}, 40),
      ueberschrift: "Rückblick"
    }

    assert {:ok, t} = Worker.Jack.Resuemee.auftrag(eingabe, @dir)

    refute t =~ "{{"
    assert t =~ "**Sitzung 4**"
    assert t =~ "heißt **„Rückblick“**"
    assert t =~ "durchnummeriert **1 bis 3**"
    assert t =~ "Blöcke **0 bis 39**"
    assert t =~ "Vor dieser Sitzung liegen die Sitzungen 2, 3."
    assert t =~ "Ein Werkzeug wird gerufen, nicht beschrieben."

    assert {:ok, t} = Worker.Jack.Resuemee.auftrag(%{eingabe | fruehere: []}, @dir)
    assert t =~ "Es gibt keine früheren Sitzungen — mit dieser Sitzung beginnt die Aufzeichnung."
  end

  # #1209: Ziel und Obergrenze — ohne Angabe der Standard 150, höchstens das
  # Doppelte, daraus zwölf Stationen; die Gliederung ist der Weg der Gruppe,
  # das Schreiben erzählt jede Station. Die Pflicht, jeden Handlungsbogen in
  # die Gliederung zu nehmen, steht nicht mehr im Überblick.
  test "die Resümee-Vorlagen nennen Ziel, Obergrenze, den Weg der Gruppe und den Deckel" do
    eingabe = %{
      sitzung: %{nummer: 4},
      fakten: [%{id: "S4-F1", fakt_id: nil, sitzung: 4, aussage: "Aussage", figur: nil}],
      fruehere: [],
      bloecke: List.duplicate(%{}, 10),
      ueberschrift: "Resümee",
      flavor: %{base: nil, summary: nil}
    }

    assert {:ok, u} = Worker.Jack.Resuemee.auftrag(eingabe, @dir)
    assert u =~ "„Was bisher geschah“"
    assert u =~ ~r/Das Ziel sind \*\*150\s+Wörter\*\*/
    assert u =~ "bis **300 Wörter**"
    assert u =~ ~r/höchstens\s+\*\*12 Stationen\*\*/
    assert u =~ "Station für Station, vom Anfang bis zum Ende"
    refute u =~ "gehört in mindestens einen Gliederungspunkt"

    assert {:ok, u} = Worker.Jack.Resuemee.auftrag(Map.put(eingabe, :max_woerter, 120), @dir)
    assert u =~ ~r/Das Ziel sind \*\*120\s+Wörter\*\*/
    assert u =~ "bis **240 Wörter**"
    assert u =~ ~r/höchstens\s+\*\*10 Stationen\*\*/

    assert {:ok, s} = Worker.Jack.Resuemee.auftrag_schreiben(eingabe, nil, @dir)
    assert s =~ "**Das Ziel sind 150 Wörter**"
    assert s =~ "bis **300 Wörter**"
    assert s =~ ~r/Jede\s+Station bekommt mindestens einen Satz/
    assert s =~ "laenge_begruendung: \"\""
    assert s =~ "`ausgelassen`"

    entwurf = [%{"saetze" => [%{"text" => "Satz.", "fakten" => ["S4-F1"]}]}]
    assert {:ok, d} = Worker.Jack.Resuemee.auftrag_durchsicht(eingabe, nil, entwurf, @dir)
    assert d =~ ~r/höchstens\s+\*\*300 Wörter\*\*/
    assert d =~ "Der Weg der Gruppe bleibt vollständig."

    for t <- [u, s, d], do: refute(t =~ "{{")
  end

  # J5 (#1209, B2): der Auftrag des Schreibens — Ton, dann Notizen, dann die
  # Aufgabe.
  test "die Vorlage des Schreibens lädt und bekommt Ton, Notizen und die Angaben der Sitzung" do
    eingabe = %{
      sitzung: %{nummer: 4},
      fakten: [%{}, %{}, %{}],
      fruehere: [%{nummer: 2}, %{nummer: 3}],
      bloecke: List.duplicate(%{}, 40),
      ueberschrift: "Rückblick",
      flavor: %{base: "Düster, mit {{sitzung}} als Wort.", summary: "Knapp."}
    }

    ablage = %{
      "notizen" => [
        %{"abschnitt" => "GLIEDERUNG", "schluessel" => "1", "zeile" => "Werkstatt"},
        %{"abschnitt" => "FORM", "schluessel" => "Form", "zeile" => "Stichpunkte"}
      ]
    }

    assert {:ok, t} = Worker.Jack.Resuemee.auftrag_schreiben(eingabe, ablage, @dir)

    refute t =~ ~r/\{\{(?!sitzung\}\} als Wort)/
    assert t =~ "# Das Resümee von Sitzung 4"
    assert t =~ "**Sitzung 4**"
    assert t =~ "**„Rückblick“**"
    assert t =~ "`S4-F1` bis `S4-F3`"
    assert t =~ "durchnummeriert **1 bis 3**"
    assert t =~ "Blöcke **0 bis 39**"
    assert t =~ "Vor dieser Sitzung liegen die Sitzungen 2, 3."
    assert t =~ "Ein Werkzeug wird gerufen, nicht beschrieben."

    # Der Ton wird eingesetzt, aber nicht selbst als Vorlage gelesen.
    assert t =~ "**Grundton der Kampagne:** Düster, mit {{sitzung}} als Wort."
    assert t =~ "**Ton des Resümees:** Knapp."

    # Die Notizen eine Ebene tiefer, FORM zuerst — egal in welcher Reihenfolge sie liegen.
    assert t =~ "### FORM\nForm — Stichpunkte\n\n### GLIEDERUNG\n1 — Werkstatt"

    [ton, form, aufgabe] =
      for m <- ["## Der Ton", "### FORM", "## Deine Aufgabe"],
          do: t |> :binary.match(m) |> elem(0)

    assert ton < form and form < aufgabe

    # Ohne Ton und ohne Notizen: neutrale Sätze statt Lücken.
    assert {:ok, t} =
             Worker.Jack.Resuemee.auftrag_schreiben(
               %{eingabe | flavor: %{base: nil, summary: nil}, fruehere: []},
               nil,
               @dir
             )

    refute t =~ "{{"
    assert t =~ "Für diese Kampagne ist kein Ton vorgegeben."
    assert t =~ "(Aus dem Überblick liegen keine Notizen vor.)"
    assert t =~ "Es gibt keine früheren Sitzungen — mit dieser Sitzung beginnt die Aufzeichnung."
  end

  # J5 (#1209, B3): der Auftrag der Durchsicht — Ton, Notizen, Entwurf, dann
  # die Aufgabe.
  test "die Vorlage der Durchsicht lädt und bekommt Ton, Notizen, Entwurf und die Angaben" do
    fakt = fn i ->
      %{id: "S4-F#{i}", fakt_id: nil, sitzung: 4, aussage: "Aussage #{i}", figur: nil}
    end

    eingabe = %{
      sitzung: %{nummer: 4},
      fakten: Enum.map(1..3, fakt),
      fruehere: [%{nummer: 2}, %{nummer: 3}],
      bloecke: List.duplicate(%{}, 40),
      ueberschrift: "Rückblick",
      flavor: %{base: "Düster, mit {{sitzung}} als Wort.", summary: nil}
    }

    ablage = %{
      "notizen" => [%{"abschnitt" => "FORM", "schluessel" => "Form", "zeile" => "Stichpunkte"}]
    }

    entwurf = [
      %{
        "titel" => "Die Werkstatt",
        "saetze" => [%{"text" => "Der Alte zeigt die {{sitzung}}.", "fakten" => ["S4-F1"]}]
      },
      %{"saetze" => [%{"text" => "Weiter.", "fakten" => [], "uebergang" => true}]}
    ]

    assert {:ok, t} = Worker.Jack.Resuemee.auftrag_durchsicht(eingabe, ablage, entwurf, @dir)

    refute t =~ ~r/\{\{(?!sitzung\}\})/
    assert t =~ "# Die Durchsicht des Resümees von Sitzung 4"
    assert t =~ "**„Rückblick“**"
    assert t =~ "**2 Absätze**"
    assert t =~ "**3 Durchgängen**"
    assert t =~ "**1 bis 3**"
    assert t =~ "Blöcke **0 bis 39**"
    assert t =~ "Vor dieser Sitzung liegen die Sitzungen 2, 3."
    assert t =~ "Ein Werkzeug wird gerufen, nicht beschrieben."
    assert t =~ "**Grundton der Kampagne:** Düster, mit {{sitzung}} als Wort."
    assert t =~ "### FORM\nForm — Stichpunkte"

    # Der Entwurf in der Form von entwurf(), nicht selbst als Vorlage gelesen.
    assert t =~
             "Absatz 1 — Die Werkstatt · 7 Wörter\n  1. Der Alte zeigt die {{sitzung}}.  [S4-F1]"

    assert t =~ "Absatz 2 (Fließtext) · 1 Wort\n  1. Weiter.  [Übergang]"

    [ton, form, entwurf_pos, aufgabe] =
      for m <- ["## Der Ton", "### FORM", "Absatz 1 — Die Werkstatt", "## Deine Aufgabe"],
          do: t |> :binary.match(m) |> elem(0)

    assert ton < form and form < entwurf_pos and entwurf_pos < aufgabe
  end

  # J6 (#1210, E1): der Auftrag des Epos-Überblicks — zuerst der Stil, dann
  # die Aufgabe mit dem Weg aus dem Resümee.
  test "die Epos-Vorlage lädt und bekommt Stil, Weg und die Angaben der Sitzung" do
    station = fn k -> %{schluessel: k, zeile: "Station #{k}", fakten: ["S4-F1"], boegen: []} end

    eingabe = %{
      sitzung: %{nummer: 4},
      fakten: [%{}, %{}, %{}],
      fruehere: [%{nummer: 2}, %{nummer: 3}],
      bloecke: List.duplicate(%{}, 40),
      ueberschrift: "Heldenlied",
      flavor: %{base: "Düster, mit {{sitzung}} als Wort.", epos: "Nah an der Gruppe."},
      resuemee_weg: [station.("1"), station.("2")]
    }

    assert {:ok, t} = Worker.Jack.Epos.auftrag(eingabe, @dir)

    refute t =~ ~r/\{\{(?!sitzung\}\} als Wort)/
    assert t =~ "**Sitzung 4**"
    assert t =~ "heißt **„Heldenlied“**"
    # Eine Länge des Kapitels gibt es nicht (Maintainer, 13.09.2026).
    refute t =~ "mindestens"
    assert t =~ "durchnummeriert **1 bis 3**"
    assert t =~ "Blöcke **0 bis 39**"
    assert t =~ "`S4-F1`"
    assert t =~ "Vor dieser Sitzung liegen die Sitzungen 2, 3."
    assert t =~ "Ein Werkzeug wird gerufen, nicht beschrieben."
    assert t =~ "in 2 Stationen fest"
    assert t =~ "(Stationen: 2)"

    # Der Ton wird eingesetzt, aber nicht selbst als Vorlage gelesen.
    assert t =~ "**Grundton der Kampagne:** Düster, mit {{sitzung}} als Wort."
    assert t =~ "**Ton des Epos:** Nah an der Gruppe."

    # Zuerst der Stil, dann die Aufgabe.
    [stil, ton, aufgabe] =
      for m <- ["## Zuerst der Stil", "**Ton des Epos:**", "## Deine Aufgabe hier"],
          do: t |> :binary.match(m) |> elem(0)

    assert stil < ton and ton < aufgabe

    # Ohne Weg, Ton, Überschrift und Vorgeschichte: neutrale Sätze statt Lücken.
    ohne = %{
      eingabe
      | resuemee_weg: [],
        flavor: %{base: nil, epos: nil},
        ueberschrift: nil,
        fruehere: []
    }

    assert {:ok, t} = Worker.Jack.Epos.auftrag(ohne, @dir)

    refute t =~ "{{"
    assert t =~ "heißt **„Epos“**"
    assert t =~ "Zu dieser Sitzung liegt kein Weg aus dem Resümee vor."
    assert t =~ "Für diese Kampagne ist kein Ton vorgegeben."
    assert t =~ "Es gibt keine früheren Sitzungen — mit dieser Sitzung beginnt die Aufzeichnung."
    refute t =~ "Ton des Resümees"
  end

  # J6 (#1210, E2): der Auftrag des Epos-Schreibens — ganz vorn der Stil
  # (Überschrift, Ton, FORM), dann die Szenen, dann die Aufgabe. Frei erzählt:
  # keine Satzarten, keine Prozente, keine Länge des Kapitels.
  test "die Vorlage des Epos-Schreibens lädt und bekommt Stil, FORM, Szenen und die Angaben" do
    eingabe = %{
      sitzung: %{nummer: 4},
      fakten: [%{}, %{}, %{}],
      fruehere: [%{nummer: 2}, %{nummer: 3}],
      bloecke: List.duplicate(%{}, 40),
      ueberschrift: "Heldenlied",
      flavor: %{base: "Düster, mit {{sitzung}} als Wort.", epos: "Nah an der Gruppe."}
    }

    n = fn a, k, z -> %{"abschnitt" => a, "schluessel" => k, "zeile" => z} end

    ablage = %{
      "notizen" => [
        n.("SZENEN", "Regen am Hafen", "Nacht, Regen, vor der Werkstatt"),
        n.("FORM", "Form", "Heldenlied in Szenen, mit {{sitzung}} im Text"),
        n.("SZENEN", "Die Spieldose", "im Licht der Lampe"),
        n.("OFFEN", "Anschluss", "das vorige Kapitel endet mit dem Brief")
      ]
    }

    assert {:ok, t} = Worker.Jack.Epos.auftrag_schreiben(eingabe, ablage, @dir)

    refute t =~ ~r/\{\{(?!sitzung\}\})/
    assert t =~ "# Das Epos-Kapitel von Sitzung 4"
    assert t =~ "Spalte **„Heldenlied“**"
    assert t =~ "**Ton des Epos:** Nah an der Gruppe."
    assert t =~ "**Grundton der Kampagne:** Düster, mit {{sitzung}} als Wort."
    assert t =~ "> Heldenlied in Szenen, mit {{sitzung}} im Text"
    assert t =~ "Im Überblick hast du 2 Szenen aufgestellt."
    assert t =~ "`S4-F1` bis `S4-F3`"
    assert t =~ "durchnummeriert **1 bis 3**"
    assert t =~ "Blöcke **0 bis 39**"
    assert t =~ "Vor dieser Sitzung liegen die Sitzungen 2, 3."
    assert t =~ ~r/höchstens\s+400 Wörter/
    assert t =~ "Ein Werkzeug wird gerufen, nicht beschrieben."
    assert t =~ "fertig(absaetze: <Zahl der Absätze>, offen_geblieben: \"…\")"

    # Die Szenen eine Ebene tiefer, ohne die FORM (die steht beim Stil).
    assert t =~
             "### SZENEN\nRegen am Hafen — Nacht, Regen, vor der Werkstatt\n" <>
               "Die Spieldose — im Licht der Lampe\n\n### OFFEN\nAnschluss — das vorige Kapitel"

    refute t =~ "### FORM"

    # Zuerst der Stil (Überschrift, Ton, FORM), dann die Szenen, dann die Aufgabe.
    [stil, ton, form, szenen, aufgabe] =
      for m <- [
            "## Zuerst der Stil",
            "**Ton des Epos:**",
            "> Heldenlied in Szenen",
            "### SZENEN",
            "## Deine Aufgabe"
          ],
          do: t |> :binary.match(m) |> elem(0)

    assert stil < ton and ton < form and form < szenen and szenen < aufgabe

    # Frei erzählt: keine Satzarten, keine Markierungen, keine Prozente, keine Länge.
    for wort <- ~w(rueckblick farbe uebergang Prozent % mindestens Satzart) do
      refute t =~ wort, "die Vorlage nennt „#{wort}“"
    end

    # Ohne Notizen, Ton und Überschrift: neutrale Sätze statt Lücken.
    assert {:ok, t} =
             Worker.Jack.Epos.auftrag_schreiben(
               %{eingabe | flavor: %{base: nil, epos: nil}, ueberschrift: nil, fruehere: []},
               nil,
               @dir
             )

    refute t =~ "{{"
    assert t =~ "Spalte **„Epos“**"
    assert t =~ "Für diese Kampagne ist kein Ton vorgegeben."
    assert t =~ "> Aus dem Überblick liegt keine FORM vor."
    assert t =~ "Im Überblick hast du keine Szene aufgestellt."
    assert t =~ "(Aus dem Überblick liegen keine Szenen vor."
    assert t =~ "Es gibt keine früheren Sitzungen — mit dieser Sitzung beginnt die Aufzeichnung."
  end

  # J6 (#1210, E3): der Auftrag der Epos-Durchsicht — Stil (Überschrift, Ton,
  # FORM), Szenen, Kapitel, dann die Aufgabe; stilistisch beauftragt, frei von
  # Länge und Satzarten.
  test "die Vorlage der Epos-Durchsicht lädt und bekommt Stil, Szenen, Kapitel und die Angaben" do
    fakt = fn i ->
      %{id: "S4-F#{i}", fakt_id: nil, sitzung: 4, aussage: "Aussage #{i}", figur: nil}
    end

    eingabe = %{
      sitzung: %{nummer: 4},
      fakten: Enum.map(1..3, fakt),
      fruehere: [%{nummer: 2}, %{nummer: 3}],
      bloecke: List.duplicate(%{}, 40),
      ueberschrift: "Heldenlied",
      flavor: %{base: "Düster, mit {{sitzung}} als Wort.", epos: "Nah an der Gruppe."}
    }

    n = fn a, k, z, f -> %{"abschnitt" => a, "schluessel" => k, "zeile" => z, "fakten" => f} end

    ablage = %{
      "notizen" => [
        n.("SZENEN", "Regen am Hafen", "Nacht, Regen, vor der Werkstatt", ["S4-F1"]),
        n.("FORM", "Form", "Heldenlied in Szenen, mit {{sitzung}} im Text", []),
        n.("OFFEN", "Anschluss", "das vorige Kapitel endet mit dem Brief", [])
      ]
    }

    entwurf = [
      %{
        "titel" => "Am Hafen",
        "text" => "Der Regen hing über der {{sitzung}}.",
        "szene" => "Regen am Hafen"
      },
      %{"text" => "Die Lampe flackerte."}
    ]

    assert {:ok, t} = Worker.Jack.Epos.auftrag_durchsicht(eingabe, ablage, entwurf, @dir)

    refute t =~ ~r/\{\{(?!sitzung\}\})/
    assert t =~ "# Die Durchsicht des Epos-Kapitels von Sitzung 4"
    assert t =~ "Spalte **„Heldenlied“**"
    assert t =~ "**Ton des Epos:** Nah an der Gruppe."
    assert t =~ "**Grundton der Kampagne:** Düster, mit {{sitzung}} als Wort."
    assert t =~ "> Heldenlied in Szenen, mit {{sitzung}} im Text"
    assert t =~ "Im Überblick hast du eine Szene aufgestellt."
    assert t =~ "**2 Absätze**"
    assert t =~ "**3 Durchgängen**"
    assert t =~ "**1 bis 3**"
    assert t =~ "Blöcke **0 bis 39**"
    assert t =~ ~r/höchstens\s+400\s+Wörter/
    assert t =~ "Vor dieser Sitzung liegen die Sitzungen 2, 3."
    assert t =~ "Ein Werkzeug wird gerufen, nicht beschrieben."
    assert t =~ "Gut zu lesen hat Vorrang."
    assert t =~ "Ein gelungener Absatz bleibt, wie er\nist"
    assert t =~ "fertig(bestaetigt: <"

    # Das Kapitel in der Form von entwurf(), nicht selbst als Vorlage gelesen.
    assert t =~
             "Absatz 1 — Am Hafen · 8 Wörter · Szene „Regen am Hafen“\n" <>
               "Der Regen hing über der {{sitzung}}."

    assert t =~ "Absatz 2 (Fließtext) · 3 Wörter · ohne Szene\nDie Lampe flackerte."

    # Zuerst der Stil (Ton, FORM), dann die Szenen, dann das Kapitel, dann die Aufgabe.
    [ton, form, szenen, kapitel, aufgabe] =
      for m <- [
            "**Ton des Epos:**",
            "> Heldenlied in Szenen",
            "### SZENEN",
            "Absatz 1 — Am Hafen",
            "## Deine Aufgabe"
          ],
          do: t |> :binary.match(m) |> elem(0)

    assert ton < form and form < szenen and szenen < kapitel and kapitel < aufgabe
    refute t =~ "### FORM"

    # Das Beispiel: eine Wortwiederholung, eine falsche Figur, ein bestätigter Absatz.
    assert t =~ "absatz_ersetzen(nummer: 1"
    assert t =~ "absatz_ersetzen(nummer: 2"
    assert t =~ "absatz_bestaetigen(nummer: 3)"

    # Frei erzählt: keine Satzarten, keine Markierungen, keine Prozente, keine Länge.
    for wort <- ~w(rueckblick farbe uebergang Prozent % mindestens Satzart) do
      refute t =~ wort, "die Vorlage nennt „#{wort}“"
    end

    # Ohne Notizen, Ton und Überschrift: neutrale Sätze statt Lücken.
    assert {:ok, t} =
             Worker.Jack.Epos.auftrag_durchsicht(
               %{eingabe | flavor: %{base: nil, epos: nil}, ueberschrift: nil, fruehere: []},
               nil,
               entwurf,
               @dir
             )

    refute t =~ ~r/\{\{(?!sitzung\}\})/
    assert t =~ "Spalte **„Epos“**"
    assert t =~ "Für diese Kampagne ist kein Ton vorgegeben."
    assert t =~ "> Aus dem Überblick liegt keine FORM vor."
    assert t =~ "Es gibt keine früheren Sitzungen — mit dieser Sitzung beginnt die Aufzeichnung."
  end

  # **Ohne Rücksicht auf Gross-/Kleinschreibung** (#850): Ein kleingeschriebenes
  # Vorkommen in einem Beispiel-Schlüssel (`tod-<name>`) war unsichtbar, obwohl
  # es derselbe echte Name ist — gefunden, als der Scan über das Verzeichnis
  # (#1247) die Chronik-Vorlagen erstmals ansah.
  test "keine Begriffe aus der gemessenen Runde in den Vorlagen" do
    for datei <- File.ls!(@dir),
        String.ends_with?(datei, ".md"),
        datei != "LIES_MICH.md",
        text = File.read!(Path.join(@dir, datei)) |> String.downcase(),
        wort <- @verboten do
      refute String.contains?(text, String.downcase(wort)), "#{datei} enthält „#{wort}“"
    end
  end

  # **Der Wächter zählt die Dateien NICHT mehr auf** (#1247). Die Liste war
  # eine Aufzählung, und sie ist genau so gealtert, wie Aufzählungen altern:
  # Die vier Chronik-Vorlagen (#1211) standen nie darin, und zwei von ihnen
  # trugen Namen der gemessenen Runde — unbemerkt, weil der Wächter sie nicht
  # ansah. Geprüft wird jetzt das Verzeichnis; wer eine Vorlage ergänzt,
  # bekommt sie ohne Zutun mitgeprüft. (`LIES_MICH.md` ist die Herkunftsnotiz
  # für Menschen, kein Auftrag.)
  test "der Wächter sieht jede Vorlage im Verzeichnis an" do
    geprueft =
      for datei <- File.ls!(@dir),
          String.ends_with?(datei, ".md"),
          datei != "LIES_MICH.md",
          do: datei

    assert length(geprueft) >= 16
    assert "chronik_ueberblick.md" in geprueft
    assert "zeit_einsortieren.md" in geprueft
  end

  # #1247 (Z2): die drei Aufträge des Zeit-Jack.
  test "jeder Lauf des Zeit-Jack hat seine Vorlage, und sie ist gefüllt" do
    zeilen =
      for i <- 1..40 do
        %{
          nr: i,
          utterance_id: "u#{i}",
          sprecher: "SL",
          text: "t",
          block_id: "b",
          block_text: nil,
          ooc?: false
        }
      end

    for lauf <- [:gedaechtnis, :einsortieren, :pruefen] do
      stand = Worker.Jack.Zeit.Stand.neu(lauf, zeilen)

      assert {:ok, text} = Worker.Jack.Zeit.Auftrag.fuer(stand, "Testrunde", @dir)

      refute text =~ "{{", "#{lauf}: ungefüllter Platzhalter"
      assert text =~ "Testrunde"
      assert text =~ "hilfe()"
    end
  end

  # Eine unbekannte Laufart darf NICHT auf eine fremde Vorlage zurückfallen —
  # das Modell läse einen Auftrag für eine andere Arbeit, und niemand sähe es
  # (die Klasse, die am 18.09.2026 die Chronik-Abschnitte still durch die des
  # Resümees ersetzte).
  test "eine unbekannte Laufart wirft, statt eine fremde Vorlage zu nehmen" do
    stand = %{Worker.Jack.Zeit.Stand.neu(:einsortieren, []) | lauf: :ausgedacht}

    assert_raise ArgumentError, ~r/:ausgedacht/, fn ->
      Worker.Jack.Zeit.Auftrag.fuer(stand, "Testrunde", @dir)
    end
  end

  # Der Einsortier-Auftrag trägt die Befunde aus der handgelesenen Referenz —
  # sie sind der Grund, warum er so aussieht, wie er aussieht.
  test "der Einsortier-Auftrag nennt die Befunde, die ihn begründen" do
    text = File.read!(Path.join(@dir, "zeit_einsortieren.md"))

    # Die Welt-Frage ist fast ein Münzwurf, keine Ausnahmebehandlung.
    assert text =~ "121"
    assert text =~ "90"

    # Zurücklesen BIS zur Frage, nicht einen Block zurück — und nicht bei der
    # ersten plausiblen Antwort aufhören.
    assert text =~ "lies zurück"
    assert text =~ "ersten plausiblen Antwort"

    # Beginn-Formen sind Zeitpunkte, keine Spannen; die Richtung zählt.
    assert text =~ "„seit“"
    assert text =~ "Richtung"

    # Ein Anker braucht keinen Kalender.
    assert text =~ "braucht keinen Kalender"

    # Der Halbtag gehört der Kette — ausser er steht da.
    assert text =~ "halbtag"

    # Weltgeschichte ist Spielwelt und bekommt einen Anker — samt der Folge,
    # dass die Zeile dorthin verschoben gehört (Maintainer, 19.09.2026).
    assert text =~ "Vergangenheit gehört auf die Linie"
    assert text =~ "Namibia", "auch die Vergangenheit der GRUPPE, nicht nur Weltgeschichte"
    assert text =~ "verschieb"

    # Die Frist zeigt nach vorn und verschiebt nichts.
    assert text =~ "`setz_frist`"

    # Seit dem Kettenumbau (20.09.2026) braucht JEDE Zeile eine Entscheidung:
    # in ein Kettenglied oder ausdrücklich heraus — „nicht angefasst" heisst
    # nicht „steht schon richtig".
    assert text =~ "Jede Zeile braucht eine Entscheidung"
    assert text =~ "`haenge_an_kette`"
    assert text =~ "`nicht_in_die_kette`"
    assert text =~ "Deine Zeilen beginnen ohne Einordnung"

    # **Und die Kette selbst ist ÄLTER als der Lauf** (#1247, 25.09.2026).
    # Der Auftrag sagte bis dahin „sie ist am Anfang leer" — das stimmte, als
    # jeder Lauf leer begann, und war danach eine Aufforderung, den Bestand zu
    # übersehen. Wer die Vorlage kürzt, muss diese Stelle mit ändern.
    assert text =~ "älter als dein Lauf"
    assert text =~ "Du ergänzt, du baust nicht neu"

    # Die zwei Achsen und die Reihenfolge der Arbeit.
    assert text =~ "Zwei Achsen"
    assert text =~ "Erst einreihen, dann datieren"
    assert text =~ "Ein Glied ist eine Zeiteinheit"

    # Der Rückblick am Sitzungsanfang ist ein Ritual, kein Einzelfall — und
    # der bösartige Fall steht dabei: Die neue Sitzung begänne sonst vor dem
    # Ende der vorigen (dave, 19.09.2026).
    assert text =~ "Rückblick"
    assert text =~ "Ritual"

    # Die Interpolation ist eine Warnung, keine Zusage: „je mehr Spannen, desto
    # weniger muss ich raten." An einer Sitzung mit 1591 Blöcken ohne eine
    # einzige Uhrzeit ist die lineare Verteilung nicht selten falsch, sondern
    # sicher.
    assert text =~ "desto weniger muss ich raten"
  end

  # Der Gedächtnis-Lauf liest seit dem 19.09.2026 die ÄUSSERUNGEN, nicht die
  # Fakten (Maintainer: „wir stellen den jacklauf ganz auf die utts um").
  test "der Gedächtnis-Auftrag liest den Mitschnitt und setzt nichts" do
    text = File.read!(Path.join(@dir, "zeit_gedaechtnis.md"))

    assert text =~ "Mitschnitt"
    refute text =~ "Fakten", "der Lauf hat keine Fakten-Werkzeuge mehr"

    # Er setzt nichts — das ist der Zweck der Trennung.
    assert text =~ "setzt in diesem Lauf **nichts**"

    # Die ZEITEN-Notizen tragen die Zeilennummer, sonst sucht der nächste Lauf
    # noch einmal.
    assert text =~ "mit der Zeilennummer"

    # `fertig()` verlangt gelesen, nicht notiert.
    assert text =~ "jede Zeile **gelesen**"
  end

  # Das sechste Symptom des Prüf-Laufs: läuft die Linie über eine
  # Sitzungsgrenze rückwärts, steckt fast immer ein nicht verschobener Recap
  # dahinter.
  test "der Prüf-Auftrag kennt die rückwärts laufende Sitzungsgrenze" do
    text = File.read!(Path.join(@dir, "zeit_pruefen.md"))

    assert text =~ "Sitzungsgrenze rückwärts"
    assert text =~ "Rückblick am Sitzungsanfang"
  end
end
