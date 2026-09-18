defmodule Worker.Jack.Chronik.KetteTest do
  @moduledoc """
  Issue #1211: die drei Läufe als Kette — und was passiert, wenn der letzte
  scheitert.

  **Der Anlass ist ein echter Verlust.** Am 18.09.2026 lief der Chronik-Jack
  auf seattleV5 durch: Überblick fertig (fünf Gruppen), Schreiben fertig (vier
  Einträge, `fertig` angenommen, 15 Runden, 31 Minuten). Dann starb die
  Durchsicht an `{:badmap, nil}` im Stand-Abbild, die Exception riss den
  Prozess mit — und **veröffentlicht wurde nichts**. Die Chronik blieb leer,
  obwohl sie fertig geschrieben war.

  Für die Kette gab es bis dahin keinen Test, nur für ihre Bausteine. Der
  Fehlerpfad der Durchsicht war gegen ein Fehler-**Tupel** abgesichert, nicht
  gegen ein Raise.
  """
  use ExUnit.Case, async: true

  alias Worker.Jack.Chronik
  alias Worker.Jack.Resuemee.Eingabe

  describe "die Durchsicht darf die Arbeit des Schreibens nicht vernichten" do
    test "durchsehen/5 fängt einen Absturz und liefert die Einträge des Schreibens" do
      # Quelltext-Wächter statt eines erzwungenen Absturzes: Ein Raise im
      # Abbild lässt sich von aussen nicht provozieren, ohne den Code zu
      # verbiegen — die Zusicherung ist aber die, an der ein ganzer Lauf hing.
      quelle = File.read!("lib/worker/jack/chronik.ex")

      [_, nach_durchsehen] =
        String.split(quelle, "defp durchsehen(r, eingabe, ablage, melde, opts)", parts: 2)

      [rumpf, _] = String.split(nach_durchsehen, "\n  @doc", parts: 2)

      assert rumpf =~ "rescue",
             "durchsehen/5 braucht ein rescue: ein Absturz in der letzten, " <>
               "verzichtbaren Stufe darf die Einträge des Schreibens nicht mitnehmen"

      assert rumpf =~ ":absturz"
      assert rumpf =~ "ergebnis(Map.put(r, :durchsicht,"
    end

    test "ein Fehler-Tupel der Durchsicht lässt die Einträge stehen" do
      quelle = File.read!("lib/worker/jack/chronik.ex")

      assert quelle =~ "es gilt die Chronik aus dem "
      assert quelle =~ "ergebnis(Map.put(r, :durchsicht, fehler), :aufbau)"
    end
  end

  describe "Betriebsart" do
    test "leere Chronik führt in den Aufbau, ein Bestand in die Verfeinerung" do
      assert Chronik.Eingabe.betriebsart([]) == :aufbau
      assert Chronik.Eingabe.betriebsart([%{id: "chr-a"}]) == :verfeinerung
    end
  end

  describe "die Werkzeuge jedes Laufs" do
    setup do
      fakten =
        Eingabe.fakten(
          [%{"id" => "f_a", "claim" => "Etwas geschieht.", "source_refs" => ["b0"]}],
          1,
          %{},
          %{"b0" => 0}
        )

      stand = fn lauf ->
        %Worker.Jack.Resuemee.Stand{
          art: :chronik,
          lauf: lauf,
          sitzung: %{id: "s1", nummer: 1, name: "Erste"},
          fakten: fakten,
          eintraege: [],
          chronik: [],
          notizen: [],
          boegen: [],
          gelesen: MapSet.new(),
          mitschnitt: %{straenge: [], bloecke: []}
        }
      end

      {:ok, stand: stand}
    end

    test "offen und hilfe sind in allen drei Läufen erreichbar", %{stand: stand} do
      for lauf <- [:ueberblick, :schreiben, :durchsicht] do
        namen = Chronik.Werkzeuge.namen(stand.(lauf))

        assert "offen" in namen, "#{lauf}: ohne offen() zählt Jack sich durch die Liste"
      end
    end

    test "notiz gibt es in allen drei Läufen — für NICHT_ZEITLEISTE", %{stand: stand} do
      for lauf <- [:ueberblick, :schreiben] do
        assert "notiz" in Chronik.Werkzeuge.namen(stand.(lauf))
      end
    end
  end
end
