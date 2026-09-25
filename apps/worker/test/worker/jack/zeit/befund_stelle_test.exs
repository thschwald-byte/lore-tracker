defmodule Worker.Jack.Zeit.BefundStelleTest do
  @moduledoc """
  #1247: **ein Befund nennt seine Stelle** — und `sitzungen()` zählt die eigene
  Gliederzahl live.

  Beides am laufenden Prüf-Lauf gefunden (25.09.2026, seattleV5 S2):

    * Jack bekam sechs Befunde als reinen Text, konnte keinen einem Anker
      zuordnen und schrieb dreissig Mal denselben Absatz, um sie aus den Zahlen
      zurückzurechnen — sein Wort: „*The Befunde list doesn't indicate
      positions.*" Die Adresse war da (`anker_id` an jedem Befund) und wurde in
      der Anzeige weggeworfen.
    * `sitzungen()` nannte „S2: 2 Kettenglied(er)", während er sieben vor sich
      hatte (die Zahlen entstehen beim Bau der Eingabe, der Prüf-Lauf erbt
      sie). Er hat drei Absätze gerätselt und erwogen, seine Sitzung sei S4.

  Die Ankerwerte unten stammen wörtlich aus diesem Lauf.
  """
  use ExUnit.Case, async: true

  alias Worker.Agent.Aufruf
  alias Worker.Jack.Resuemee.Halter
  alias Worker.Jack.Zeit.{Stand, Werkzeuge}
  alias Worker.Timeline.{Befunde, Kette}

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

  defp anker(id, utts, wert, extra \\ %{}) do
    Map.merge(
      %{anker_id: id, utterance_ids: utts, art: "zeitpunkt", wert: wert, welt: "spielwelt"},
      extra
    )
  end

  defp ruf(h, name, felder \\ %{}) do
    werkzeuge = Werkzeuge.fuer(h) |> Map.new(&{&1.name, &1})
    Aufruf.ausfuehren(%{name: name, argumente: {:ok, felder}}, werkzeuge)
  end

  describe "mit_stellen/2 — die Adresse reist mit" do
    test "ein ankergebundener Befund bekommt Utterances und Wert" do
      a = anker("z_6fe4a3882a5289d0", ["u5"], "nachts um halb zwei")

      befund = %{
        art: :zweifel,
        anker_id: "z_6fe4a3882a5289d0",
        text: "Bezugspunkt ist der S3-Abend."
      }

      assert %{stellen: [stelle]} = Befunde.mit_stellen(befund, [a])
      assert stelle.utterance_ids == ["u5"]
      assert stelle.wert == "nachts um halb zwei"
    end

    test "der Strecken-Befund bekommt BEIDE Endpunkte" do
      # `spannen_ueberlauf` trägt bewusst `anker_id: nil` (er gilt der
      # Strecke) — genau der Befund, den Jack für unauflösbar hielt.
      befund = %{
        art: :spannen_ueberlauf,
        anker_id: nil,
        anker_ids: ["z_a", "z_b"],
        text: "Zwischen zwei Ankern liegen 10 Jahre, die genannten Dauern ergeben 60 Jahre."
      }

      anker = [anker("z_a", ["u1"], "2070"), anker("z_b", ["u9"], "2080")]
      assert %{stellen: [a, b]} = Befunde.mit_stellen(befund, anker)
      assert a.wert == "2070"
      assert b.wert == "2080"
    end

    test "zwei uneinige Zeitpunkte lösen beide auf" do
      # `uneinige_zeitpunkte` verkettet die IDs mit ", ".
      befund = %{art: :zeitpunkte_uneinig, anker_id: "z_x, z_y", text: "An derselben Stelle …"}
      anker = [anker("z_x", ["u3"], "halb neun"), anker("z_y", ["u3"], "20:30")]

      assert %{stellen: stellen} = Befunde.mit_stellen(befund, anker)
      assert length(stellen) == 2
    end

    test "ein Befund ohne auflösbaren Anker bleibt ohne Stelle, nicht kaputt" do
      assert %{stellen: []} = Befunde.mit_stellen(%{art: :zweifel, anker_id: "gibts_nicht"}, [])
      assert %{stellen: []} = Befunde.mit_stellen(%{art: :spannen_ueberlauf, anker_id: nil}, [])
    end

    test "aus/1 hängt sie an JEDEN Befund — auch an den der Strecke" do
      # Der Weg, den der Produktionspfad nimmt: über `Linie.aus_kette/3`
      # gebaut, nicht von Hand zusammengesetzt (die #1149-Lehre).
      reihe = for n <- 1..4, do: %{utterance_id: "u#{n}"}

      befunde =
        Befunde.aus(%{
          reihe: reihe,
          anker: [anker("z_1", ["u2"], "morgens um 10", %{zweifel: "mehrdeutig"})],
          feste: [],
          spannen: %{}
        })

      assert [%{stellen: [%{wert: "morgens um 10"}]}] = befunde
    end
  end

  describe "lies_kette(): die Stelle steht vor dem Text" do
    defp halter(anker, opts \\ []) do
      {:ok, kette, _} = Kette.anhaengen(Kette.neu(), ["u1", "u2", "u3"], grund: "Erste Szene")

      stand =
        Stand.neu(
          :pruefen,
          Enum.map(1..6, &zeile/1),
          Keyword.merge(
            [
              session_id: "sess",
              campaign_id: "camp",
              kette: kette,
              anker: anker,
              sitzung_nr: 2,
              sitzungen: [%{nummer: 2, zeilen: 6, glieder: 1, notizen?: false, eigene?: true}]
            ],
            opts
          )
        )

      {:ok, h} = Halter.start_link(stand, abbild: &Stand.abbild/1)
      h
    end

    test "Zeilennummer und Ausdruck stehen dabei" do
      h = halter([anker("z_1", ["u3"], "morgens um 10", %{zweifel: "für den Rechner mehrdeutig"})])

      assert {:ok, text} = ruf(h, "lies_kette")
      assert text =~ "Zeile 3"
      assert text =~ "morgens um 10"
      assert text =~ "mehrdeutig"
    end

    test "eine Stelle aus einer anderen Sitzung heisst so" do
      # Ihre Utterance steht nicht im eigenen Mitschnitt — ein Strich sagte
      # nicht, warum keine Nummer dasteht (dieselbe Entscheidung wie bei den
      # Gliedern).
      h = halter([anker("z_f", ["fremd-1"], "2070", %{zweifel: "unklar"})])

      assert {:ok, text} = ruf(h, "lies_kette")
      assert text =~ "andere Sitzung"
    end

    test "mehrere Utterances werden zur Spanne" do
      h = halter([anker("z_s", ["u2", "u3", "u4"], "zwei Stunden", %{art: "spanne", zweifel: "?"})])

      assert {:ok, text} = ruf(h, "lies_kette")
      assert text =~ "Zeilen 2–4"
    end
  end

  describe "die Klammer von lies_kette()" do
    test "trennt die Kampagne von der eigenen Sitzung" do
      # Maintainer, 25.09.2026: „lies_kette() muss über die ganze Kampagne
      # gehen." Sie mischte drei kampagnenweite Zahlen mit einer eigenen, ohne
      # Kennzeichnung — Jack hat in zwei Läufen darüber gerätselt, welche Zahl
      # seine ist („1978 lines were outside — hmm … Wait, total lines across
      # all se…"). Er arbeitete an 3.385 Zeilen und bekam Zahlen über 8.213.
      h = halter([])

      assert {:ok, text} = ruf(h, "lies_kette")
      assert text =~ "Kampagne:"
      assert text =~ "Deine Sitzung:"

      # `unentschieden` bleibt die eigene Zahl — sie MUSS es sein, Jack
      # entscheidet nur die Zeilen seiner Sitzung. Sie steht nur nicht mehr in
      # derselben Aufzählung wie die kampagnenweiten.
      assert text =~ ~r/Deine Sitzung: \d+ Zeilen, \d+ unentschieden/
    end

    test "und die kampagnenweiten Zahlen stehen unter Kampagne" do
      h = halter([])
      assert {:ok, text} = ruf(h, "lies_kette")
      assert text =~ ~r/Kampagne: \d+ Glieder, \d+ Zeilen drin, \d+ draussen/
    end
  end

  describe "sitzungen(): die eigene Gliederzahl ist aktuell" do
    test "gezählt wird die Kette, nicht die Zahl vom Lauf-Beginn" do
      {:ok, kette, _} = Kette.anhaengen(Kette.neu(), ["u1", "u2"], grund: "A")
      {:ok, kette, _} = Kette.anhaengen(kette, ["u3", "u4"], grund: "B")
      {:ok, kette, _} = Kette.anhaengen(kette, ["u5"], grund: "C")

      s =
        Stand.neu(:pruefen, Enum.map(1..6, &zeile/1),
          kette: kette,
          sitzung_nr: 2,
          sitzungen: [
            %{nummer: 1, zeilen: 100, glieder: 14, notizen?: true, eigene?: false},
            %{nummer: 2, zeilen: 6, glieder: 2, notizen?: true, eigene?: true}
          ]
        )

      assert Stand.eigene_glieder(s) == 3

      {:ok, h} = Halter.start_link(s, abbild: &Stand.abbild/1)
      assert {:ok, text} = ruf(h, "sitzungen")

      assert text =~ "S2: 6 Zeilen, 3 Kettenglied(er)"

      # Die fremde Zahl bleibt die vom Lauf-Beginn: Ihr Mitschnitt liegt nicht
      # im Stand, und dieser Lauf ändert fremde Glieder nicht.
      assert text =~ "S1: 100 Zeilen, 14 Kettenglied(er)"
      assert text =~ "deine Gliederzahl ist aktuell"
    end

    test "ohne eigene Glieder steht dort 0, nicht die alte Zahl" do
      s =
        Stand.neu(:einsortieren, Enum.map(1..3, &zeile/1),
          kette: Kette.neu(),
          sitzung_nr: 2,
          sitzungen: [%{nummer: 2, zeilen: 3, glieder: 9, notizen?: false, eigene?: true}]
        )

      {:ok, h} = Halter.start_link(s, abbild: &Stand.abbild/1)
      assert {:ok, text} = ruf(h, "sitzungen")
      assert text =~ "S2: 3 Zeilen, 0 Kettenglied(er)"
    end
  end
end
