defmodule Worker.Jack.Zeit.StandTest do
  @moduledoc """
  #1247 (Z2): der Stand eines Zeit-Jack-Laufs — Buchführung über Gelesenes,
  Gesetztes und offene Kennungen.
  """
  use ExUnit.Case, async: true

  alias Worker.Jack.Zeit.{Setzen, Stand}

  defp zeile(nr, id),
    do: %{
      nr: nr,
      utterance_id: id,
      sprecher: "x",
      text: "t",
      block_id: "b",
      block_text: nil,
      ooc?: false
    }

  defp mitschnitt(n), do: for(i <- 1..n, do: zeile(i, "u#{i}"))

  defp anker(ids, art, wert) do
    Setzen.bauen(%{utterance_ids: ids, art: art, wert: wert, welt: "spielwelt", beleg: "b"})
  end

  describe "Gelesenes" do
    test "wird beim Lesen gezählt, nicht in einem zweiten Schritt" do
      s = Stand.neu(:einsortieren, mitschnitt(10))
      assert Stand.zahlen(s).gelesen == 0
      assert Stand.zahlen(s).offen == 10

      s = Stand.gelesen(s, Enum.take(s.mitschnitt, 3))
      assert Stand.zahlen(s).gelesen == 3
      assert Stand.zahlen(s).offen == 7
    end

    test "dieselbe Zeile zweimal zählt einmal" do
      s = Stand.neu(:einsortieren, mitschnitt(5))
      z = Enum.take(s.mitschnitt, 2)

      s = s |> Stand.gelesen(z) |> Stand.gelesen(z)
      assert Stand.zahlen(s).gelesen == 2
    end

    test "offen/1 nennt alle offenen Zeilen — gedeckelt wird erst bei der Ausgabe" do
      # Die Ausgabe fasst sie zu Bereichen zusammen
      # (`Abschluss.bereiche/1`); eine vorab gekürzte Liste könnte das nicht.
      s = Stand.neu(:einsortieren, mitschnitt(100))
      o = Stand.offen(s)

      assert o.anzahl == 100
      assert length(o.zeilen) == 100
    end
  end

  describe "Anker" do
    test "an/2 findet, was an einer Utterance hängt" do
      s =
        Stand.neu(:einsortieren, mitschnitt(5))
        |> Stand.setzen(anker(["u1"], :zeitpunkt, "elf Uhr"))
        |> Stand.setzen(anker(["u3", "u4"], :spanne, "zwei Stunden"))

      assert [a] = Stand.an(s, ["u1"])
      assert a.wert == "elf Uhr"

      assert [b] = Stand.an(s, ["u4"])
      assert b.art == :spanne

      assert Stand.an(s, ["u2"]) == []
    end

    test "mehrere Anker an derselben Utterance kommen beide" do
      s =
        Stand.neu(:einsortieren, mitschnitt(3))
        |> Stand.setzen(anker(["u1"], :spanne, "eine Stunde"))
        |> Stand.setzen(anker(["u1"], :zeitpunkt, "kurz nach zwölf"))

      assert length(Stand.an(s, ["u1"])) == 2
    end

    test "ein gelöster Anker hängt nicht mehr dort" do
      a = anker(["u1"], :zeitpunkt, "elf Uhr")

      s =
        Stand.neu(:einsortieren, mitschnitt(3))
        |> Stand.setzen(a)
        |> Stand.setzen(Setzen.loesche_kettenplatz(a, "Tischgespräch"))

      assert Stand.an(s, ["u1"]) == []
      # Die Zeile steht aber noch — kein Delete.
      assert map_size(s.anker) == 1
      assert Stand.zahlen(s).geloest == 1
    end
  end

  describe "Kennungen" do
    test "ausgegeben → offen, eingelöst → eingeloest, unbekannt → nil" do
      s = Stand.neu(:einsortieren, mitschnitt(3))

      assert Stand.schicksal(s, "g1") == nil

      s = Stand.ausgeben(s, "g1", %{was: :egal})
      assert Stand.schicksal(s, "g1") == :offen

      s = Stand.verbrauchen(s, "g1")
      assert Stand.schicksal(s, "g1") == :eingeloest
    end

    test "eine nicht genannte Kennung verfällt" do
      # Sie gilt für den NÄCHSTEN Aufruf — sonst könnte eine Entscheidung
      # versehentlich auf einen anderen Anker wirken.
      s =
        Stand.neu(:einsortieren, mitschnitt(3))
        |> Stand.ausgeben("g1", %{})
        |> Stand.ausgeben("g2", %{})
        |> Stand.verfallen("g2")

      assert Map.keys(s.offene) == ["g2"]
      # Das Schicksal bleibt bekannt: „abgelaufen" ist etwas anderes als
      # „erfunden", und die Antwort muss beides unterscheiden können.
      assert Stand.schicksal(s, "g1") == :offen
    end
  end

  describe "Abbild für die Laufsicht" do
    test "trägt die Marke und die Zählwerte" do
      s =
        Stand.neu(:pruefen, mitschnitt(4))
        |> Stand.gelesen([zeile(1, "u1")])
        |> Stand.setzen(anker(["u1"], :zeitpunkt, "elf"))
        |> Stand.konflikt(%{art: :test})

      a = Stand.abbild(s)

      # Ohne eigene Marke fiele die Seite auf das Abbild des Resümee-Jack
      # zurück und zeigte Wörter und Gliederung, die es hier nicht gibt —
      # dieselbe Klasse, die beim Chronik-Jack die Durchsicht abstürzen liess.
      assert a["jack"] == "zeit"
      assert a["lauf"] == "pruefen"
      assert a["utterances"] == 4
      assert a["gelesen"] == 1
      assert a["offen"] == 3
      assert a["zeitpunkte"] == 1
      assert a["konflikte"] == 1
    end
  end

  describe "der geteilte Halter trägt auch diesen Stand" do
    test "start_link nimmt ihn an und meldet sein Abbild" do
      s = Stand.neu(:einsortieren, mitschnitt(2))

      {:ok, halter} =
        Worker.Jack.Resuemee.Halter.start_link(s,
          beobachter: self(),
          abbild: &Stand.abbild/1
        )

      assert_receive {:jack_resuemee_stand, %{"jack" => "zeit"}}
      assert %Stand{} = Worker.Jack.Resuemee.Halter.stand(halter)
    end

    test "OHNE :abbild findet er das eigene des Stands" do
      # Der Fund aus dem Review (19.09.2026): Der Guard `%Stand{} = s` war
      # nicht bloss eine Typprüfung, sondern die Schranke, die den Default
      # `&Resuemee.Stand.abbild/1` gültig machte. Mit `is_struct/1` fiele sie.
      s = Stand.neu(:pruefen, mitschnitt(2))

      {:ok, _} = Worker.Jack.Resuemee.Halter.start_link(s, beobachter: self())

      # Nicht das Abbild des Resümee-Jack, sondern das eigene.
      assert_receive {:jack_resuemee_stand, %{"jack" => "zeit", "lauf" => "pruefen"}}
    end

    test "ein Stand OHNE abbild/1 scheitert beim Start, nicht beim ersten Melden" do
      # Die Stelle ist der Punkt: `melden/1` ist ohne Beobachter ein `:ok` —
      # in Tests und Messläufen würde das Abbild NIE gerufen und alles bliebe
      # grün. Erst im Betrieb, wenn die Laufsicht zusieht, stürbe der Halter
      # beim ersten Melden und der ganze Lauf mit ihm.
      ohne = %URI{}

      assert_raise ArgumentError, ~r/abbild\/1/, fn ->
        Worker.Jack.Resuemee.Halter.start_link(ohne)
      end

      # Auch ohne Beobachter — sonst hinge der Fehler daran, ob jemand zusieht.
      assert_raise ArgumentError, fn ->
        Worker.Jack.Resuemee.Halter.start_link(ohne, beobachter: nil)
      end
    end
  end
end
