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

  test "keine Begriffe aus der gemessenen Runde in den Vorlagen" do
    for datei <- ~w(phase1.md phase2.md folgelauf.md),
        text = File.read!(Path.join(@dir, datei)),
        wort <- @verboten do
      refute String.contains?(text, wort), "#{datei} enthält „#{wort}“"
    end
  end
end
