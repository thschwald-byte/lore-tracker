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

  # #1209: die Länge des Resümees — ohne Angabe der Standard 75, daraus drei
  # Gliederungspunkte; die Pflicht, jeden Handlungsbogen in die Gliederung zu
  # nehmen, steht nicht mehr im Überblick.
  test "die Resümee-Vorlagen nennen die Länge und den Gliederungsdeckel" do
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
    assert u =~ "höchstens **75\nWörtern**"
    assert u =~ "höchstens **3 Punkte**"
    refute u =~ "gehört in mindestens einen Gliederungspunkt"

    assert {:ok, u} = Worker.Jack.Resuemee.auftrag(Map.put(eingabe, :max_woerter, 120), @dir)
    assert u =~ "höchstens **120\nWörtern**"
    assert u =~ "höchstens **5 Punkte**"

    assert {:ok, s} = Worker.Jack.Resuemee.auftrag_schreiben(eingabe, nil, @dir)
    assert s =~ "in höchstens 75\nWörtern**"
    assert s =~ "`ausgelassen`"

    entwurf = [%{"saetze" => [%{"text" => "Satz.", "fakten" => ["S4-F1"]}]}]
    assert {:ok, d} = Worker.Jack.Resuemee.auftrag_durchsicht(eingabe, nil, entwurf, @dir)
    assert d =~ "höchstens **75 Wörter**"

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
    assert t =~ "Absatz 1 — Die Werkstatt\n  1. Der Alte zeigt die {{sitzung}}.  [S4-F1]"
    assert t =~ "Absatz 2 (Fließtext)\n  1. Weiter.  [Übergang]"

    [ton, form, entwurf_pos, aufgabe] =
      for m <- ["## Der Ton", "### FORM", "Absatz 1 — Die Werkstatt", "## Deine Aufgabe"],
          do: t |> :binary.match(m) |> elem(0)

    assert ton < form and form < entwurf_pos and entwurf_pos < aufgabe
  end

  test "keine Begriffe aus der gemessenen Runde in den Vorlagen" do
    for datei <-
          ~w(phase1.md phase2.md folgelauf.md resuemee_ueberblick.md resuemee_schreiben.md
             resuemee_durchsicht.md),
        text = File.read!(Path.join(@dir, datei)),
        wort <- @verboten do
      refute String.contains?(text, wort), "#{datei} enthält „#{wort}“"
    end
  end
end
