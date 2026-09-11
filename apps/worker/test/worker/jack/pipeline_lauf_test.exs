defmodule Worker.Jack.PipelineLaufTest do
  # J4 (#1207): ein Durchgang im Betrieb — Gedächtnis, Extraktion, Iteration —
  # im Speicher, mit einem Stub-Modell. Kein Ollama, keine Dateien.
  use ExUnit.Case, async: true

  alias Worker.Jack.Pipeline

  @kontext for i <- 0..9,
               do: %{
                 id: "b#{i}",
                 discord_id: "1",
                 text: "Satz #{i} im Mitschnitt.",
                 quell_utterance_ids: ["u#{i}"]
               }

  @auftraege %{phase1: "LESEN\n", phase2: "SAMMELN\n", folgelauf: "VERIFIZIEREN\n"}

  # Spielt ein Skript ab und meldet den Auftrag jeder frischen Sitzung.
  defmodule Skript do
    @moduledoc false
    @behaviour Worker.Agent.Modell

    @impl true
    def antworten(nachrichten, _werkzeuge, opts) do
      case nachrichten do
        [%{role: :system}, %{role: :user, content: auftrag}] ->
          send(Keyword.fetch!(opts, :test), {:sitzung, auftrag})

        _ ->
          :ok
      end

      {:ok,
       Agent.get_and_update(Keyword.fetch!(opts, :skript), fn [kopf | rest] -> {kopf, rest} end)}
    end
  end

  defp antwort(aufrufe),
    do: %{text: nil, denken: nil, aufrufe: aufrufe, stopp: :werkzeuge, nutzung: nil}

  defp ohne_aufruf, do: %{text: "bin durch", denken: nil, aufrufe: [], stopp: :stop, nutzung: nil}

  defp aufruf(name, args), do: %{id: "id_#{name}", name: name, argumente: {:ok, args}}

  defp lesen, do: antwort([aufruf("bloecke", %{"von" => 0, "bis" => 9})])

  defp gedaechtnis do
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

    antwort([aufruf("notiz", %{"eintraege" => eintraege})])
  end

  defp aussage do
    antwort([
      aufruf("aussage", %{
        "claim" => "Satz drei steht im Mitschnitt.",
        "beleg" => "Satz 3 im Mitschnitt",
        "source_refs" => [3],
        "character" => "",
        "cast_match" => "",
        "narration_time" => "present",
        "time_anchor" => "session",
        "in_game_date" => "",
        "fact_type" => "zustand",
        "threads" => []
      })
    ])
  end

  defp fertig(zahlen), do: antwort([aufruf("fertig", Map.put(zahlen, "offen_geblieben", ""))])

  defp skript(schritte) do
    {:ok, s} = Agent.start_link(fn -> schritte end)
    {Skript, skript: s, test: self()}
  end

  defp durchgang_1,
    do: [
      lesen(),
      gedaechtnis(),
      fertig(%{"bereiche" => 1, "eintraege" => 10}),
      lesen(),
      aussage(),
      fertig(%{"aussagen" => 1})
    ]

  test "Gedächtnis, Extraktion, eine Iteration ohne Neues: Fakten mit Block-IDs" do
    modell = skript(durchgang_1() ++ [lesen(), fertig(%{"aussagen" => 1})])

    assert {:ok, [f], saw, bericht} =
             Pipeline.extrahieren(@kontext, %{"1" => "Figur"}, [], [],
               auftraege: @auftraege,
               modell: modell
             )

    assert f["claim"] == "Satz drei steht im Mitschnitt."
    assert f["source_refs"] == ["b3"]
    assert map_size(saw) == 10

    assert %{
             ende: :gesaettigt,
             durchgaenge: [
               %{nr: 1, vorher: 0, bestand: 1, neu: 1},
               %{nr: 2, vorher: 1, bestand: 1, neu: 0}
             ]
           } = bericht

    # drei frische Sitzungen, jede mit ihrem Auftrag; das Gedächtnis reist mit
    assert_received {:sitzung, "LESEN\n\nDer Mitschnitt hat die Blöcke 0 bis 9."}
    assert_received {:sitzung, "SAMMELN\n\n## Dein Gedächtnis\n\n" <> g}
    assert g =~ "## ABLAUF"
    assert_received {:sitzung, "VERIFIZIEREN\n\n## Dein Gedächtnis\n\n" <> _}
  end

  test "ohne Iteration: nur Gedächtnis und Extraktion" do
    modell = skript(durchgang_1())

    assert {:ok, [_], _saw, %{ende: :fertig, durchgaenge: [%{nr: 1}]}} =
             Pipeline.extrahieren(@kontext, %{"1" => "Figur"}, [], [],
               auftraege: @auftraege,
               modell: modell,
               iterationen: 0
             )
  end

  test "Phase 1 ohne fertig: keine Extraktion, ein Fehler" do
    modell = skript([lesen(), ohne_aufruf()])

    assert {:error, {:phase1_ohne_abschluss, _}} =
             Pipeline.extrahieren(@kontext, %{"1" => "Figur"}, [], [],
               auftraege: @auftraege,
               modell: modell
             )
  end
end
