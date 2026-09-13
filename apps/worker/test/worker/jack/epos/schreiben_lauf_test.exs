defmodule Worker.Jack.Epos.SchreibenLaufTest do
  # J6 (#1210, E2): das Schreiben des Epos-Jack als Lauf der Laufzeit, allein
  # und nach dem Überblick, mit einem Stub-Modell (Muster
  # `resuemee/schreiben_lauf_test.exs`). Kein Ollama, kein Mnesia.
  use ExUnit.Case, async: true

  alias Worker.Jack.Epos
  alias Worker.Jack.Resuemee.{Eingabe, Stand}

  @uhrmacher "Der verschwundene Uhrmacher"
  @text "Der Regen hing über dem Hafen, als Mira an die Tür der Werkstatt klopfte."

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

      case Agent.get_and_update(Keyword.fetch!(opts, :skript), fn
             [kopf | rest] -> {kopf, rest}
             [] -> {nil, []}
           end) do
        nil -> raise "Skript erschöpft; zuletzt: #{inspect(Enum.take(nachrichten, -4))}"
        schritt -> {:ok, schritt}
      end
    end
  end

  defp antwort(aufrufe),
    do: %{text: nil, denken: nil, aufrufe: aufrufe, stopp: :werkzeuge, nutzung: nil}

  defp ohne_aufruf, do: %{text: "bin durch", denken: nil, aufrufe: [], stopp: :stop, nutzung: nil}

  defp aufruf(name, args), do: %{id: "id_#{name}", name: name, argumente: {:ok, args}}

  defp skript(schritte) do
    {:ok, s} = Agent.start_link(fn -> schritte end)
    {Skript, skript: s, test: self()}
  end

  defp eingabe do
    roh = [
      %{
        "id" => "f_a",
        "claim" => "Die Gruppe steht im Regen vor der Werkstatt.",
        "source_refs" => ["b0"]
      },
      %{"id" => "f_b", "claim" => "Mira klopft an die Tür.", "source_refs" => ["b1"]}
    ]

    fakten =
      Eingabe.fakten(roh, 2, %{"f_a" => [%{titel: @uhrmacher, kind: "arc"}]}, %{
        "b0" => 0,
        "b1" => 1
      })

    %{
      sitzung: %{id: "s2", nummer: 2, name: "Nach Norden"},
      fakten: fakten,
      fruehere: [],
      boegen: Eingabe.boegen(fakten, []),
      bloecke: [
        %{text: "Ihr steht im Regen vor der Werkstatt.", sprecher: "SL", block_id: "b0"},
        %{text: "Ich klopfe an.", sprecher: "Mira", block_id: "b1"}
      ],
      cast: ["Mira"],
      straenge: [@uhrmacher],
      ueberschrift: "Heldenlied",
      flavor: %{base: nil, epos: "Nah an der Gruppe."},
      resuemee_diese: "Die Gruppe steht im Regen vor der Werkstatt.",
      resuemee_weg: [
        %{schluessel: "1", zeile: "vor der Werkstatt", fakten: ["S2-F1"], boegen: []},
        %{schluessel: "2", zeile: "Mira klopft", fakten: ["S2-F2"], boegen: []}
      ]
    }
  end

  defp notizen do
    [
      %{
        "abschnitt" => "FORM",
        "schluessel" => "Form",
        "zeile" => "Heldenlied in Szenen, nah an der Gruppe",
        "fakten" => [],
        "boegen" => []
      },
      %{
        "abschnitt" => "SZENEN",
        "schluessel" => "Regen",
        "zeile" => "Nacht, Regen, vor der Werkstatt",
        "fakten" => ["S2-F1", "S2-F2"],
        "boegen" => [@uhrmacher]
      }
    ]
  end

  defp ueberblick_schritte do
    [
      antwort([aufruf("fakten", %{"von" => 1, "bis" => 2})]),
      antwort([aufruf("notiz", %{"eintraege" => notizen()})]),
      antwort([aufruf("fertig", %{"fakten" => 2, "szenen" => 1, "offen_geblieben" => ""})])
    ]
  end

  defp absatz_schritt,
    do: antwort([aufruf("absatz", %{"text" => @text, "szene" => "Regen"})])

  defp fertig(absaetze),
    do: antwort([aufruf("fertig", %{"absaetze" => absaetze, "offen_geblieben" => ""})])

  defp schreib_schritte, do: [antwort([aufruf("entwurf", %{})]), absatz_schritt(), fertig(1)]

  test "Stil, dann Szenen, dann Aufgabe; heraus kommt das Kapitel als Markdown" do
    assert {:ok, %{stand: s, markdown: @text, runden: runden}} =
             Epos.laufen_schreiben(eingabe(), %{"notizen" => notizen()},
               modell: skript(schreib_schritte()),
               kontext_fenster: 20_000,
               stand_beobachter: self()
             )

    assert is_integer(runden)
    assert s.art == :epos
    assert s.lauf == :schreiben
    assert [%{titel: nil, text: @text, szene: "Regen"}] = s.entwurf

    assert_received {:sitzung, auftrag}
    refute auftrag =~ "{{"
    assert auftrag =~ "# Das Epos-Kapitel von Sitzung 2"

    [ton, form, szenen, aufgabe] =
      for m <- [
            "**Ton des Epos:** Nah an der Gruppe.",
            "> Heldenlied in Szenen, nah an der Gruppe",
            "### SZENEN\nRegen — Nacht, Regen, vor der Werkstatt",
            "## Deine Aufgabe"
          ],
          do: auftrag |> :binary.match(m) |> elem(0)

    assert ton < form and form < szenen and szenen < aufgabe

    assert_received {:jack_resuemee_stand,
                     %{"jack" => "epos", "lauf" => "schreiben", "entwurf" => %{"absaetze" => 1}}}
  end

  test "fertig auf einem leeren Kapitel wird abgelehnt, nach einem Absatz geht es" do
    assert {:ok, %{stand: s}} =
             Epos.laufen_schreiben(eingabe(), %{"notizen" => notizen()},
               modell: skript([fertig(0), absatz_schritt(), fertig(1)]),
               kontext_fenster: 20_000
             )

    [abgelehnt, abschluss] =
      for {"abschluss.jsonl", eintrag} <- Stand.journal_liste(s), do: eintrag

    assert abgelehnt["versuch"] == "abgelehnt"
    assert [h] = abgelehnt["hindernisse"]
    assert h =~ "Das Kapitel hat noch keinen Absatz."
    assert abschluss["abschluss"] == true
    assert abschluss["zahlen_stimmten"] == "ja"
  end

  test "ohne fertig: ein Fehler mit eigener Marke" do
    assert {:error, {:epos_schreiben_ohne_abschluss, _}} =
             Epos.laufen_schreiben(eingabe(), %{"notizen" => notizen()},
               modell:
                 skript([antwort([aufruf("entwurf", %{})]) | List.duplicate(ohne_aufruf(), 4)]),
               kontext_fenster: 20_000
             )
  end

  test "ohne Fakten: Fehler vor dem ersten Modellaufruf" do
    assert {:error, :keine_fakten} =
             Epos.laufen_schreiben(%{eingabe() | fakten: []}, nil, modell: skript([]))

    refute_received {:sitzung, _}
  end

  test "Überblick und Schreiben nacheinander: das Schreiben bekommt die Notizen des Überblicks" do
    assert {:ok, %{ueberblick: u, schreiben: sch, markdown: @text}} =
             Epos.laufen(eingabe(),
               modell: skript(ueberblick_schritte() ++ schreib_schritte()),
               kontext_fenster: 20_000,
               auftrag: "gilt hier nicht"
             )

    assert u.stand.lauf == :ueberblick
    assert MapSet.size(u.stand.gelesen) == 2
    assert sch.stand.lauf == :schreiben
    assert sch.stand.notizen == u.stand.notizen

    assert_received {:sitzung, erster}
    assert_received {:sitzung, zweiter}
    assert erster =~ "Das Epos-Kapitel einer Sitzung vorbereiten"
    assert zweiter =~ "> Heldenlied in Szenen, nah an der Gruppe"

    assert zweiter =~
             "### SZENEN\nRegen — Nacht, Regen, vor der Werkstatt  [Fakten: S2-F1, S2-F2 · " <>
               "Bögen: #{@uhrmacher}]"
  end
end
