defmodule Worker.Jack.Zeit.SperreTest do
  @moduledoc """
  #1247: die Wiederholungssperre zählt `offen()` nur, **solange Jack nichts
  einträgt**.

  Der Anlass ist ein verlorener Lauf vom 24.09.2026: 62 Minuten, alle 2168
  Zeilen gelesen, 1992 eingeordnet, 25 Glieder gebaut — abgebrochen mit
  `{:abbruch, {:wiederholung, "offen"}}` beim sechsten `offen()`. Drei
  Sekunden davor hatte Jack noch ein Glied erweitert.

  Die Ursache war ein fehlendes Feld: `offen()`, `lies_kette()`, `zahlen()`
  und `notizen_lesen()` haben `wiederholung: :bis_aenderung`, und
  zurückgesetzt wird diese Zählung nur von Werkzeugen mit
  `aendert_bestand: true`. Der Zeit-Jack hatte davon **kein einziges** —
  Epos, Resümee und Chronik setzen es an jedem schreibenden Werkzeug.

  **Geprüft wird über `Worker.Agent.Aufruf.beobachtet/2`**, nicht über
  `ausfuehren/2`. Die Buchhaltung der Sperre sitzt dort; ein Test, der die
  Werkzeuge direkt ruft, läuft an ihr vorbei und ist immer grün — genau das
  ist mir beim ersten Anlauf passiert.
  """
  use ExUnit.Case, async: true

  alias Worker.Agent.{Aufruf, Wiederholung}
  alias Worker.Jack.Resuemee.Halter
  alias Worker.Jack.Zeit.{Stand, Werkzeuge}

  defp zeile(nr),
    do: %{
      nr: nr,
      utterance_id: "u#{nr}",
      sprecher: "SL",
      text: "Zeile #{nr}",
      block_id: "b#{nr}",
      block_text: nil,
      ooc?: false
    }

  defp aufbau do
    {:ok, h} =
      Halter.start_link(Stand.neu(:einsortieren, Enum.map(1..20, &zeile/1)),
        abbild: &Stand.abbild/1
      )

    {:ok, w} = Wiederholung.neu([])
    %{werkzeuge: Map.new(Werkzeuge.fuer(h), &{&1.name, &1}), wiederholung: w, abbruch: nil}
  end

  defp ruf(s, name, felder) do
    {{art, _text}, s, _status} =
      Aufruf.beobachtet(s, %{id: "i", name: name, argumente: {:ok, felder}})

    {art, s}
  end

  describe "offen() nach getaner Arbeit" do
    test "acht Runden mit einer Eintragung dazwischen laufen durch" do
      # Der echte Lauf hat genau das gemacht: fragen, arbeiten, fragen. Vor
      # dem Fix war beim sechsten Mal Schluss.
      ergebnis =
        Enum.reduce_while(1..8, {:ok, aufbau()}, fn i, {_, s} ->
          case ruf(s, "offen", %{}) do
            {:ok, s} ->
              {_, s} = ruf(s, "haenge_an_kette", %{"zeilen" => [i]})
              {:cont, {:ok, s}}

            {art, s} ->
              {:halt, {{:abgebrochen_in_runde, i, art}, s}}
          end
        end)

      assert {:ok, _} = ergebnis
    end

    test "auch lies_kette und zahlen, die dieselbe Zählung teilen" do
      ergebnis =
        Enum.reduce_while(1..8, {:ok, aufbau()}, fn i, {_, s} ->
          {a1, s} = ruf(s, "lies_kette", %{})
          {a2, s} = ruf(s, "zahlen", %{})

          if a1 == :ok and a2 == :ok do
            {_, s} = ruf(s, "nicht_in_die_kette", %{"zeilen" => [i], "grund" => "Tisch"})
            {:cont, {:ok, s}}
          else
            {:halt, {{:abgebrochen_in_runde, i, a1, a2}, s}}
          end
        end)

      assert {:ok, _} = ergebnis
    end
  end

  describe "offen() ohne jede Arbeit" do
    test "wird weiterhin gesperrt — die Sperre ist nicht abgeschaltet" do
      # Die Gegenrichtung gehört dazu: Der Fix darf die Sperre nicht
      # entschärfen, sondern nur richtig zählen lassen. Wer sechsmal
      # dasselbe fragt, ohne etwas zu tun, hängt wirklich fest.
      ergebnis =
        Enum.reduce_while(1..8, {:ok, aufbau()}, fn i, {_, s} ->
          case ruf(s, "offen", %{}) do
            {:ok, s} -> {:cont, {:ok, s}}
            {art, s} -> {:halt, {{:gesperrt_in_runde, i, art}, s}}
          end
        end)

      assert {{:gesperrt_in_runde, runde, art}, _} = ergebnis
      assert art in [:error, :abbruch]
      assert runde <= 6, "spätestens beim sechsten gleichen Aufruf muss die Sperre greifen"
    end
  end

  describe "die Werkzeuge sind vollständig ausgezeichnet" do
    test "jedes schreibende Zeit-Werkzeug setzt aendert_bestand" do
      # Ohne diese Liste fällt ein neues Werkzeug still durch: Es schreibt,
      # aber die Zählung von offen() läuft weiter — und der Lauf stirbt
      # Stunden später an einer Stelle, die nichts damit zu tun hat.
      s = Stand.neu(:einsortieren, Enum.map(1..5, &zeile/1))
      defs = Map.new(Werkzeuge.definitionen(s), &{&1.name, &1})

      schreibend =
        ~w(haenge_an_kette unterhaenge_kettenglied erweitere_kettenglied
           versetze_kettenglied loesche_kettenglied nicht_in_die_kette
           setz_zeitpunkt setz_spanne setz_frist anker_dazu anker_ersetzen
           melde_konflikt kettenplatz_unklar lies_sprechlinie)

      for name <- schreibend do
        assert Map.get(defs, name)[:aendert_bestand] == true,
               "#{name} ändert den Stand, setzt aber kein aendert_bestand — " <>
                 "damit läuft die Zählung von offen() weiter"
      end
    end

    test "lesende Werkzeuge setzen es NICHT" do
      s = Stand.neu(:einsortieren, Enum.map(1..5, &zeile/1))
      defs = Map.new(Werkzeuge.definitionen(s), &{&1.name, &1})

      for name <- ~w(lies_kette offen zahlen) do
        refute Map.get(defs, name)[:aendert_bestand] == true,
               "#{name} liest nur — es darf die Zählung nicht zurücksetzen"
      end
    end
  end
end
