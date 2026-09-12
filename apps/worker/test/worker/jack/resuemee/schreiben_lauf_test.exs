defmodule Worker.Jack.Resuemee.SchreibenLaufTest do
  # J5 (#1209, B2): das Schreiben als Lauf der Laufzeit, allein und nach dem
  # Überblick, mit einem Stub-Modell (Muster `lauf_test.exs`). Kein Ollama,
  # kein Mnesia.
  use ExUnit.Case, async: true

  alias Worker.Jack.Resuemee
  alias Worker.Jack.Resuemee.{Eingabe, Stand}

  @uhrmacher "Der verschwundene Uhrmacher"

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

  defp eingabe(flavor \\ %{base: nil, summary: nil}) do
    roh = [
      %{"id" => "f_a", "claim" => "Die Gruppe steht vor der Werkstatt.", "source_refs" => ["b0"]},
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
        %{text: "Ihr steht vor der Werkstatt.", sprecher: "SL", block_id: "b0"},
        %{text: "Ich klopfe an.", sprecher: "Mira", block_id: "b1"}
      ],
      cast: ["Mira"],
      straenge: [@uhrmacher],
      ueberschrift: "Rückblick",
      flavor: flavor
    }
  end

  defp notiz(abschnitt, schluessel, zeile, fakten, boegen),
    do: %{
      "abschnitt" => abschnitt,
      "schluessel" => schluessel,
      "zeile" => zeile,
      "fakten" => fakten,
      "boegen" => boegen
    }

  defp ablage do
    %{
      "notizen" => [
        notiz("FORM", "Form", "chronologische Nacherzählung", [], []),
        notiz("GLIEDERUNG", "1", "vor der Werkstatt", ["S2-F1", "S2-F2"], [@uhrmacher])
      ]
    }
  end

  # Überblick: lesen, notieren, fertig.
  defp ueberblick_schritte do
    [
      antwort([aufruf("fakten", %{"von" => 1, "bis" => 2})]),
      antwort([aufruf("notiz", %{"eintraege" => ablage()["notizen"]})]),
      antwort([
        aufruf("fertig", %{"fakten" => 2, "gliederung" => 1, "offen_geblieben" => ""})
      ])
    ]
  end

  # Schreiben: Entwurf ansehen, einen Absatz, fertig.
  defp schreib_schritte do
    [
      antwort([aufruf("entwurf", %{})]),
      antwort([
        aufruf("absatz", %{
          "titel" => "Vor der Werkstatt",
          "saetze" => [
            %{"text" => "Die Gruppe steht vor der Werkstatt.", "fakten" => ["S2-F1"]},
            %{"text" => "Mira klopft an die Tür.", "fakten" => ["S2-F2"]}
          ]
        })
      ]),
      antwort([
        aufruf("fertig", %{
          "absaetze" => 1,
          "saetze" => 2,
          "ausgelassen" => [],
          "offen_geblieben" => ""
        })
      ])
    ]
  end

  @markdown "**Vor der Werkstatt**\nDie Gruppe steht vor der Werkstatt. Mira klopft an die Tür."

  test "Ton, dann Notizen, dann Auftrag; heraus kommt der Entwurf als Markdown" do
    assert {:ok, %{stand: s, markdown: @markdown, runden: runden}} =
             Resuemee.laufen_schreiben(
               eingabe(%{base: "Knapp und trocken.", summary: nil}),
               ablage(),
               modell: skript(schreib_schritte()),
               kontext_fenster: 20_000
             )

    assert is_integer(runden)
    assert s.lauf == :schreiben
    assert Stand.form(s).zeile == "chronologische Nacherzählung"
    assert s.gelesen == MapSet.new()

    assert_received {:sitzung, auftrag}
    refute auftrag =~ "{{"
    assert auftrag =~ "**Sitzung 2**"
    assert auftrag =~ "**„Rückblick“**"

    ton = :binary.match(auftrag, "**Grundton der Kampagne:** Knapp und trocken.") |> elem(0)
    form = :binary.match(auftrag, "### FORM\nForm — chronologische Nacherzählung") |> elem(0)
    gliederung = :binary.match(auftrag, "### GLIEDERUNG") |> elem(0)
    aufgabe = :binary.match(auftrag, "## Deine Aufgabe") |> elem(0)
    assert ton < form and form < gliederung and gliederung < aufgabe
  end

  test "ohne fertig: ein Fehler" do
    assert {:error, {:schreiben_ohne_abschluss, _}} =
             Resuemee.laufen_schreiben(eingabe(), ablage(),
               modell:
                 skript([antwort([aufruf("entwurf", %{})]) | List.duplicate(ohne_aufruf(), 4)]),
               kontext_fenster: 20_000
             )
  end

  test "ohne Fakten: Fehler vor dem ersten Modellaufruf" do
    assert {:error, :keine_fakten} =
             Resuemee.laufen_schreiben(%{eingabe() | fakten: []}, ablage(), modell: skript([]))

    refute_received {:sitzung, _}
  end

  test "Überblick und Schreiben nacheinander: das Schreiben bekommt die Notizen des Überblicks" do
    assert {:ok,
            %{ueberblick: u, schreiben: sch, durchsicht: :uebersprungen, markdown: @markdown}} =
             Resuemee.laufen(eingabe(),
               modell: skript(ueberblick_schritte() ++ schreib_schritte()),
               kontext_fenster: 20_000,
               auftrag: "gilt hier nicht",
               durchsicht: false,
               stand_beobachter: self()
             )

    assert u.stand.lauf == :ueberblick
    assert MapSet.size(u.stand.gelesen) == 2
    assert sch.stand.lauf == :schreiben
    assert sch.stand.notizen == u.stand.notizen

    assert_received {:sitzung, erster}
    assert_received {:sitzung, zweiter}
    assert erster =~ "Die Fakten einer Sitzung überblicken"
    assert zweiter =~ "### GLIEDERUNG\n1 — vor der Werkstatt"
    assert zweiter =~ "Für diese Kampagne ist kein Ton vorgegeben."

    assert_received {:jack_resuemee_stand,
                     %{"lauf" => "schreiben", "entwurf" => %{"absaetze" => 1, "saetze" => 2}}}
  end
end
