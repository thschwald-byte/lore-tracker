defmodule Worker.Jack.Zeit.FrueherTest do
  @moduledoc """
  #1247: **der Zeit-Jack liest die früheren Sitzungen** — und kann dort NICHT
  ankern.

  Maintainer, 25.09.2026: „er muss die Sachen, die vor vorherigen Sessions
  erarbeitet wurden, lesen/bearbeiten können."

  Die Falle ist die Adressierung. Jacks Zeilennummer n ist Position n in
  **seiner** Liste — nur so zeigt sie auf die richtige Utterance. Eine fremde
  Zeile mit derselben Nummer setzte einen Anker an die falsche Stelle, und zwar
  lautlos. Deshalb tragen fremde Zeilen ein Präfix (`S2/45`) und sind über die
  setzenden Werkzeuge nicht erreichbar.
  """
  use ExUnit.Case, async: true

  alias Worker.Agent.Aufruf
  alias Worker.Jack.Resuemee.Halter
  alias Worker.Jack.Zeit.{Stand, Werkzeuge}

  defp zeile(nr, text \\ nil),
    do: %{
      nr: nr,
      utterance_id: "u#{nr}",
      sprecher: "SL",
      text: text || "Zeile #{nr}",
      block_id: "b#{nr}",
      block_text: nil,
      ooc?: false
    }

  defp fremd(nr),
    do: %{
      nr: nr,
      utterance_id: "v#{nr}",
      sprecher: "Kodex",
      text: "Damals in Sitzung 1, Zeile #{nr}",
      block_id: "a#{nr}",
      block_text: nil,
      ooc?: false
    }

  defp halter(opts \\ []) do
    stand =
      Stand.neu(
        :einsortieren,
        Enum.map(1..3, &zeile/1),
        Keyword.merge(
          [
            sitzung_nr: 2,
            sitzungen: [
              %{nummer: 1, zeilen: 40, glieder: 5, notizen?: true, eigene?: false},
              %{nummer: 2, zeilen: 3, glieder: 0, notizen?: false, eigene?: true}
            ],
            lader: fn
              1 -> {:ok, Enum.map(1..40, &fremd/1)}
              _ -> {:error, :keine_sitzung}
            end,
            vorige_notizen: %{1 => %{"ABLAUF" => %{"text" => "Die Gruppe kam in Seattle an."}}}
          ],
          opts
        )
      )

    {:ok, h} = Halter.start_link(stand, abbild: &Stand.abbild/1)
    h
  end

  defp ruf(h, name, felder \\ %{}) do
    werkzeuge = Werkzeuge.fuer(h) |> Map.new(&{&1.name, &1})
    Aufruf.ausfuehren(%{name: name, argumente: {:ok, felder}}, werkzeuge)
  end

  describe "die Übersicht" do
    test "nennt Zeilen, Glieder, Notizen — und welche die eigene ist" do
      assert {:ok, text} = ruf(halter(), "sitzungen")

      assert text =~ "S1: 40 Zeilen, 5 Kettenglied(er), Notizen vorhanden"
      assert text =~ "← deine"
    end

    test "ohne frühere Sitzungen sagt sie das" do
      assert {:ok, text} = ruf(halter(sitzungen: []), "sitzungen")
      assert text =~ "keine früheren"
    end
  end

  describe "der Mitschnitt einer früheren Sitzung" do
    test "kommt mit Präfix und dem Hinweis, dass er nicht zum Ankern ist" do
      assert {:ok, text} = ruf(halter(), "lies_frueher", %{"sitzung" => 1, "ab" => 1})

      assert text =~ "S1/1  Kodex:"
      assert text =~ "ankern kannst"
      refute text =~ "\nu1", "keine nackten Nummern, die in ein setzendes Werkzeug führen"
    end

    test "wird beim ersten Zugriff geladen und dann behalten" do
      # Vorgeladen wären bei seattleV5 rund 12.000 Zeilen im Stand, meist
      # ungelesen — deshalb der Lader. Zweimal laden wäre Verschwendung.
      h = halter()
      ruf(h, "lies_frueher", %{"sitzung" => 1, "ab" => 1})

      assert map_size(Halter.stand(h).mitschnitte) == 1
      assert {:ok, _} = ruf(h, "lies_frueher", %{"sitzung" => 1, "ab" => 20})
    end

    test "die eigene Sitzung wird abgewiesen — mit dem Weg dorthin" do
      # Sonst läse er seine eigenen Zeilen unter Präfix und könnte sie danach
      # nicht adressieren.
      assert {:error, text} = ruf(halter(), "lies_frueher", %{"sitzung" => 2, "ab" => 1})
      assert text =~ "deine eigene Sitzung"
      assert text =~ "lies_sprechlinie"
    end

    test "eine unbekannte Sitzung ebenso" do
      assert {:error, text} = ruf(halter(), "lies_frueher", %{"sitzung" => 7, "ab" => 1})
      assert text =~ "kenne ich nicht"
      assert text =~ "sitzungen()"
    end

    test "ohne Lader bleibt es eine Aussage, kein Absturz" do
      assert {:error, text} =
               ruf(halter(lader: nil), "lies_frueher", %{"sitzung" => 1, "ab" => 1})

      assert text =~ "kein Lader"
    end
  end

  describe "die Gedanken früherer Läufe" do
    test "kommen mit ihrer Sitzung" do
      assert {:ok, text} = ruf(halter(), "vorige_gedanken")
      assert text =~ "— S1 —"
      assert text =~ "Die Gruppe kam in Seattle an."
    end

    test "gezielt nach Sitzung" do
      assert {:ok, text} = ruf(halter(), "vorige_gedanken", %{"sitzung" => 1})
      assert text =~ "Seattle"
    end

    test "und sagen es, wenn keine da sind" do
      assert {:ok, text} = ruf(halter(vorige_notizen: %{}), "vorige_gedanken")
      assert text =~ "Kein früherer Lauf"
    end
  end

  describe "ein Fehler in einer fremden Sitzung hat einen Weg" do
    # Am Lauf vom 25.09.2026 gefunden. Jack fand im Prüf-Lauf einen falschen
    # Anker in S1 und schrieb: „Both point to the same S1/85 anchor being wrong
    # (it's the year 2010, not a time). But I can't anchor in S1. So what can I
    # do?" — Die Antwort war bis dahin: nichts.
    alias Worker.Timeline.Kette

    defp mit_fremdem_glied do
      {:ok, k, _} = Kette.anhaengen(Kette.neu(), ["v1", "v2"], grund: "S1: die Anreise")
      {:ok, k, _} = Kette.anhaengen(k, ["u1", "u2"], grund: "S4: die Rückkehr")

      {:ok, h} =
        Halter.start_link(
          Stand.neu(:pruefen, Enum.map(1..3, &zeile/1), kette: k, sitzung_nr: 4),
          abbild: &Stand.abbild/1
        )

      h
    end

    test "melde_konflikt nimmt die Glied-Nummer aus lies_kette — auch für ein fremdes" do
      h = mit_fremdem_glied()

      assert {:ok, text} =
               ruf(h, "melde_konflikt", %{
                 "glied" => 1,
                 "befund" => "Der Anker ist das Jahr 2010, nicht 10 Uhr",
                 "beleg" => "um 10"
               })

      assert text =~ "Glied 1"
      assert text =~ "S1: die Anreise"
      assert text =~ "ändert sich nichts", "melden heisst nicht ändern"
      assert length(Halter.stand(h).konflikte) == 1
    end

    test "der Konflikt trägt die Glied-Kennung, nicht nur Utterances" do
      # Ohne sie wäre für einen Menschen nicht auffindbar, WELCHES Glied gemeint
      # ist — die Utterances einer fremden Sitzung sagen ihm nichts.
      h = mit_fremdem_glied()
      ruf(h, "melde_konflikt", %{"glied" => 1, "befund" => "b", "beleg" => "z"})

      [k] = Halter.stand(h).konflikte
      assert is_binary(k.glied_id)
      assert k.utterance_ids == ~w(v1 v2)
    end

    test "eine Nummer, die es nicht gibt, sagt wie viele es sind" do
      assert {:error, text} =
               ruf(mit_fremdem_glied(), "melde_konflikt", %{
                 "glied" => 99,
                 "befund" => "b",
                 "beleg" => "z"
               })

      assert text =~ "Nummer 99 gibt es nicht"
      assert text =~ "hat 2"
    end

    test "der Weg über eigene Zeilen bleibt unverändert" do
      h = mit_fremdem_glied()

      assert {:ok, text} =
               ruf(h, "melde_konflikt", %{"zeilen" => [1], "befund" => "b", "beleg" => "z"})

      assert text =~ "Konflikt eingetragen"
    end
  end

  describe "die Werkzeuge stehen in allen drei Läufen" do
    test "auch im Gedächtnis-Lauf — dort soll er den Ablauf verstehen" do
      for lauf <- [:gedaechtnis, :einsortieren, :pruefen] do
        namen = Werkzeuge.namen(Stand.neu(lauf, []))

        for w <- ~w(sitzungen lies_frueher vorige_gedanken) do
          assert w in namen, "#{w} fehlt im #{lauf}-Lauf"
        end
      end
    end
  end
end
