defmodule Worker.Jack.Resuemee.LaufTest do
  # J5 (#1209, B1): der Überblick als ein Lauf der Laufzeit, mit einem
  # Stub-Modell (Muster `pipeline_lauf_test.exs`). Kein Ollama, kein Mnesia.
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

  defp eingabe(fruehere \\ []) do
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
      fruehere: fruehere,
      boegen: Eingabe.boegen(fakten, []),
      bloecke: [
        %{text: "Ihr steht vor der Werkstatt.", sprecher: "SL", block_id: "b0"},
        %{text: "Ich klopfe an.", sprecher: "Mira", block_id: "b1"}
      ],
      cast: ["Mira"],
      straenge: [@uhrmacher],
      ueberschrift: "Rückblick",
      flavor: %{base: nil, summary: nil}
    }
  end

  defp lesen, do: antwort([aufruf("fakten", %{"von" => 1, "bis" => 2})])

  defp notieren do
    antwort([
      aufruf("notiz", %{
        "eintraege" => [
          %{
            "abschnitt" => "FORM",
            "schluessel" => "Form",
            "zeile" => "chronologische Nacherzählung",
            "fakten" => [],
            "boegen" => []
          },
          %{
            "abschnitt" => "GLIEDERUNG",
            "schluessel" => "1",
            "zeile" => "vor der Werkstatt",
            "fakten" => ["S2-F1", "S2-F2"],
            "boegen" => [@uhrmacher]
          }
        ]
      })
    ])
  end

  defp fertig,
    do:
      antwort([
        aufruf("fertig", %{"fakten" => 2, "gliederung" => 1, "offen_geblieben" => ""})
      ])

  test "lesen, FORM und GLIEDERUNG notieren, fertig: der Stand mit den Notizen" do
    assert {:ok, %{stand: s, runden: runden}} =
             Resuemee.laufen_ueberblick(eingabe(),
               modell: skript([lesen(), notieren(), fertig()]),
               kontext_fenster: 20_000
             )

    assert is_integer(runden)
    assert Stand.form(s).zeile == "chronologische Nacherzählung"

    assert [%{fakten: ["S2-F1", "S2-F2"], boegen: [@uhrmacher]}] =
             Stand.abschnitt(s, "GLIEDERUNG")

    assert MapSet.size(s.gelesen) == 2

    # Der Auftrag aus der Vorlage, mit den Angaben der Sitzung.
    assert_received {:sitzung, auftrag}
    assert auftrag =~ "**Sitzung 2**"
    assert auftrag =~ "heißt **„Rückblick“**"
    assert auftrag =~ Stand.keine_frueheren()
    refute auftrag =~ "{{"
  end

  test "eine Antwort ohne Werkzeugaufruf kostet nicht den Lauf" do
    assert {:ok, _} =
             Resuemee.laufen_ueberblick(eingabe(),
               modell: skript([lesen(), ohne_aufruf(), notieren(), fertig()]),
               kontext_fenster: 20_000,
               auftrag: "GLIEDERN"
             )

    assert_received {:sitzung, "GLIEDERN"}
  end

  test "ohne fertig: ein Fehler" do
    # erst nach der vierten Antwort ohne Aufruf in Folge gibt die Laufzeit auf
    assert {:error, {:ueberblick_ohne_abschluss, _}} =
             Resuemee.laufen_ueberblick(eingabe(),
               modell: skript([lesen() | List.duplicate(ohne_aufruf(), 4)]),
               kontext_fenster: 20_000
             )
  end

  test "ohne Fakten oder mit zu kleinem Fenster: Fehler vor dem ersten Modellaufruf" do
    assert {:error, :keine_fakten} =
             Resuemee.laufen_ueberblick(%{eingabe() | fakten: []}, modell: skript([]))

    assert {:error, {:kontext_fenster_ungueltig, 100, _}} =
             Resuemee.laufen_ueberblick(eingabe(), modell: skript([]), kontext_fenster: 100)

    refute_received {:sitzung, _}
  end

  test "Beobachter: das Protokoll mit dem Kontextfenster, der Stand nach jedem Aufruf" do
    assert {:ok, _} =
             Resuemee.laufen_ueberblick(eingabe([%{nummer: 1, name: "S1", fakten: []}]),
               modell: skript([lesen(), notieren(), fertig()]),
               kontext_fenster: 20_000,
               beobachter: self(),
               stand_beobachter: self()
             )

    assert_received {:agent, %{"ereignis" => "start", "kontext_fenster" => 20_000}}
    assert_received {:jack_resuemee_stand, %{"gelesen" => 2, "form" => nil}}

    assert_received {:jack_resuemee_stand,
                     %{"form" => "chronologische Nacherzählung", "gliederung" => 1}}

    assert_received {:sitzung, auftrag}
    assert auftrag =~ "Vor dieser Sitzung liegt Sitzung 1."
  end
end
