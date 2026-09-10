defmodule Worker.Jack.WerkzeugeTest do
  use ExUnit.Case, async: true

  alias Worker.Jack.{Halter, Stand, Werkzeuge}

  @bloecke for i <- 0..9,
               do: %{text: "Satz #{i} im Mitschnitt.", sprecher: "Figur", block_id: "b#{i}"}

  # Ein Modell, das ein Skript abspielt.
  defmodule Skript do
    @moduledoc false
    @behaviour Worker.Agent.Modell

    @impl true
    def antworten(_nachrichten, _werkzeuge, opts) do
      {:ok,
       Agent.get_and_update(Keyword.fetch!(opts, :skript), fn [kopf | rest] -> {kopf, rest} end)}
    end
  end

  defp antwort(aufrufe),
    do: %{text: nil, denken: nil, aufrufe: aufrufe, stopp: :werkzeuge, nutzung: nil}

  defp aufruf(name, args),
    do: %{id: "id_#{name}", name: name, argumente: {:ok, args}}

  test "die Werkzeuge je Phase, in der Reihenfolge des Spikes" do
    assert Werkzeuge.namen(Stand.neu(phase: 1)) ==
             ~w(bloecke block suche cast straenge notiz notizen_lesen fertig)

    assert ["weiter" | _] = Werkzeuge.namen(Stand.neu(phase: 1, beppo: true))

    assert Werkzeuge.namen(Stand.neu(phase: 2)) |> Enum.take(-2) ==
             ~w(aussage aussage_entscheiden)
  end

  test "Markierungen für die Wiederholungssperre wie in #1196" do
    {:ok, h} = Halter.start_link(Stand.neu(bloecke: @bloecke, phase: 2, beppo: true))
    w = Werkzeuge.fuer(h)

    assert w |> Enum.filter(&(&1.wiederholung == :frei)) |> Enum.map(& &1.name) |> Enum.sort() ==
             ~w(cast fertig notizen_lesen straenge weiter)

    assert w |> Enum.filter(& &1.aendert_bestand) |> Enum.map(& &1.name) ==
             ~w(aussage aussage_entscheiden)
  end

  test "aussage antwortet mit outcome als erstem Schlüssel, im Eintrag status zuerst" do
    {:ok, h} = Halter.start_link(Stand.neu(bloecke: @bloecke, phase: 2))
    aussage = Enum.find(Werkzeuge.fuer(h), &(&1.name == "aussage"))

    {:error, antwort} =
      aussage.ausfuehren.(%{
        "claim" => "Satz null.",
        "beleg" => "Satz 0",
        "source_refs" => [0],
        "character" => "",
        "cast_match" => "",
        "narration_time" => "present",
        "time_anchor" => "session",
        "in_game_date" => "",
        "fact_type" => "ereignis",
        "threads" => []
      })

    assert Jason.encode!(antwort) =~
             ~r/^\{"outcome":"no_scaffold","aussagen":\[\{"status":"vorgelegt","claim":"Satz null\.","beleg"/
  end

  test "ein Formfehler bei aussage beantwortet das Werkzeug, nicht die Laufzeit" do
    {:ok, h} = Halter.start_link(Stand.neu(bloecke: @bloecke, phase: 2))

    {:ok, skript} =
      Agent.start_link(fn ->
        [
          antwort([aufruf("aussage", %{"claim" => "unvollständig"})]),
          %{text: "ende", denken: nil, aufrufe: [], stopp: :stop, nutzung: nil}
        ]
      end)

    assert {:ok, bericht} =
             Worker.Agent.laufen(
               modell: {Skript, skript: skript},
               system: "S",
               nachrichten: [%{role: :user, content: "Sammle."}],
               werkzeuge: Werkzeuge.fuer(h)
             )

    # ohne Gerüst geht no_scaffold vor, wie im Spike — und die Antwort ist die einheitliche
    assert [%{role: :tool, content: text}] = Enum.filter(bericht.nachrichten, &(&1.role == :tool))
    assert text =~ ~r/^\{"outcome":"no_scaffold"/
    assert Halter.stand(h).abgelehnt == 1
  end

  test "der vierte gleiche aussage-Aufruf: einheitliche Antwort mit outcome repeat" do
    {:ok, h} = Halter.start_link(Stand.neu(bloecke: @bloecke, phase: 2))
    gleich = antwort([aufruf("aussage", %{"claim" => "unvollständig"})])

    {:ok, skript} =
      Agent.start_link(fn ->
        List.duplicate(gleich, 4) ++
          [%{text: "ende", denken: nil, aufrufe: [], stopp: :stop, nutzung: nil}]
      end)

    assert {:ok, bericht} =
             Worker.Agent.laufen(
               modell: {Skript, skript: skript},
               system: "S",
               nachrichten: [%{role: :user, content: "Sammle."}],
               werkzeuge: Werkzeuge.fuer(h)
             )

    vierte = bericht.nachrichten |> Enum.filter(&(&1.role == :tool)) |> Enum.at(3)

    assert %{
             "outcome" => "repeat",
             "aussagen" => [%{"status" => "vorgelegt", "claim" => "unvollständig"}],
             "fehler" => [f],
             "hinweis" => "Verfolge diese Sache nicht weiter" <> _
           } = Jason.decode!(vierte.content)

    assert f =~ ~s|aussage({"claim":"unvollständig"}) ist dein 4. gleicher Aufruf|
    assert vierte.content =~ ~r/^\{"outcome":"repeat"/
    # drei Aufrufe liefen (je no_scaffold), der vierte nicht
    assert Halter.stand(h).abgelehnt == 3
  end

  test "suche mit einem Aussagesatz bekommt über Halter und Wrapper den Hinweis" do
    {:ok, h} = Halter.start_link(Stand.neu(bloecke: @bloecke, phase: 2))
    suche = Enum.find(Werkzeuge.fuer(h), &(&1.name == "suche"))

    assert {:ok, "HINWEIS: suche() durchsucht nur den Mitschnitt" <> rest} =
             suche.ausfuehren.(%{"begriff" => "Satz 3 im Mitschnitt steht hier"})

    assert rest =~ "Keine Fundstelle"
    assert {:ok, "1 Fundstelle(n):" <> _} = suche.ausfuehren.(%{"begriff" => "Satz 3"})

    assert [{"probieren.jsonl", %{"grund" => "lang"}}] = Stand.journal_liste(Halter.stand(h))
  end

  test "ein Werkzeug, das wirft, lässt den Stand stehen und liefert einen Fehler" do
    {:ok, h} = Halter.start_link(Stand.neu(bloecke: @bloecke))
    vorher = Halter.stand(h)
    assert {:error, "kaputt"} = Halter.aufrufen(h, fn _s, _a -> raise "kaputt" end, %{})

    assert {:error, "Werkzeug lieferte keinen Stand: :ok"} =
             Halter.aufrufen(h, fn _s, _a -> :ok end, %{})

    assert Halter.stand(h) == vorher
  end

  @tag :tmp_dir
  test "ein Lauf durch Phase 1 — lesen, notieren, fertig — mit Beobachter und Ablage", %{
    tmp_dir: dir
  } do
    {:ok, h} = Halter.start_link(Stand.neu(bloecke: @bloecke), beobachter: self(), ablage: dir)

    eintraege =
      for {a, k} <- [
            {"ABLAUF", "0-9"},
            {"FIGUREN", "a"},
            {"FIGUREN", "b"},
            {"AUFTRAG", "a"},
            {"AUFTRAG", "b"},
            {"THEMEN", "a"},
            {"THEMEN", "b"},
            {"OFFEN", "a"},
            {"OFFEN", "b"},
            {"OFFEN", "c"}
          ],
          do: %{"abschnitt" => a, "schluessel" => k, "zeile" => "Inhalt #{k}", "bloecke" => [0]}

    {:ok, skript} =
      Agent.start_link(fn ->
        [
          antwort([aufruf("bloecke", %{"von" => 0, "bis" => 9})]),
          antwort([aufruf("notiz", %{"eintraege" => eintraege})]),
          antwort([
            aufruf("fertig", %{"bereiche" => 1, "eintraege" => 10, "offen_geblieben" => ""})
          ])
        ]
      end)

    assert {:ok, %{ende: :halt, runden: 3}} =
             Worker.Agent.laufen(
               modell: {Skript, skript: skript},
               system: "S",
               nachrichten: [%{role: :user, content: "Lies den Mitschnitt."}],
               werkzeuge: Werkzeuge.fuer(h)
             )

    # beim Start und nach jedem der drei Aufrufe
    assert_received {:jack_stand, %{"gelesen" => []}}
    assert_received {:jack_stand, %{"gelesen" => [[0, 9]]}}
    assert_received {:jack_stand, %{"register" => [_ | _]}}
    assert_received {:jack_stand, %{"journal" => %{"abschluss.jsonl" => 1}}}

    assert File.read!(Path.join(dir, "notizen.txt")) =~ "## ABLAUF\n0-9 — Inhalt 0-9  [0]"

    assert %{"hindernisse" => [], "journal" => %{"notizen_verlauf.txt" => 10}} =
             dir |> Path.join("stand.json") |> File.read!() |> Jason.decode!()

    assert [%{"abschluss" => true, "zahlen_stimmten" => "ja"}] =
             dir
             |> Path.join("abschluss.jsonl")
             |> File.read!()
             |> String.split("\n", trim: true)
             |> Enum.map(&Jason.decode!/1)
  end
end
