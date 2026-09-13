defmodule Worker.Jack.Epos.LaufTest do
  # J6 (#1210, E1): der Überblick des Epos-Jack als ein Lauf der Laufzeit, mit
  # einem Stub-Modell (Muster `resuemee/lauf_test.exs`). Kein Ollama, kein Mnesia.
  use ExUnit.Case, async: true

  alias Worker.Jack.Epos
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

  defp lesen, do: antwort([aufruf("fakten", %{"von" => 1, "bis" => 2})])

  defp weg_lesen, do: antwort([aufruf("resuemee", %{})])

  defp notieren(szenen_fakten) do
    antwort([
      aufruf("notiz", %{
        "eintraege" => [
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
            "fakten" => szenen_fakten,
            "boegen" => [@uhrmacher]
          }
        ]
      })
    ])
  end

  defp abweichen do
    antwort([
      aufruf("notiz", %{
        "eintraege" => [
          %{
            "abschnitt" => "ABWEICHUNG",
            "schluessel" => "2",
            "zeile" => "das Klopfen trägt keine eigene Szene",
            "fakten" => [],
            "boegen" => []
          }
        ]
      })
    ])
  end

  defp fertig(szenen),
    do:
      antwort([
        aufruf("fertig", %{"fakten" => 2, "szenen" => szenen, "offen_geblieben" => ""})
      ])

  test "Stil lesen, Weg prüfen, FORM und SZENEN notieren, fertig: der Stand mit den Notizen" do
    assert {:ok, %{stand: s, runden: runden}} =
             Epos.laufen_ueberblick(eingabe(),
               modell: skript([lesen(), weg_lesen(), notieren(["S2-F1", "S2-F2"]), fertig(1)]),
               kontext_fenster: 20_000,
               stand_beobachter: self()
             )

    assert is_integer(runden)
    assert s.art == :epos
    assert Stand.form(s).zeile == "Heldenlied in Szenen, nah an der Gruppe"
    assert [%{schluessel: "Regen", fakten: ["S2-F1", "S2-F2"]}] = Stand.abschnitt(s, "SZENEN")
    assert MapSet.size(s.gelesen) == 2

    # Die Ablage für das Schreiben (E2): die Notizen mit den Abschnitten des Epos.
    assert Enum.map(Stand.ablage(s)["notizen"], & &1["abschnitt"]) == ~w(FORM SZENEN)

    # Der Beobachter bekommt das Abbild des Epos-Jack.
    assert_received {:jack_resuemee_stand, %{"jack" => "epos", "szenen" => 0}}
    assert_received {:jack_resuemee_stand, %{"jack" => "epos", "szenen" => 1}}

    # Der Auftrag aus der Vorlage: zuerst der Stil.
    assert_received {:sitzung, auftrag}
    assert auftrag =~ "**Sitzung 2**"
    assert auftrag =~ "heißt **„Heldenlied“**"
    assert auftrag =~ "**Ton des Epos:** Nah an der Gruppe."
    assert auftrag =~ "in 2 Stationen fest"
    assert auftrag =~ Stand.keine_frueheren()
    refute auftrag =~ "{{"
  end

  test "eine offene Station hält fertig auf, bis sie in einer Szene oder unter ABWEICHUNG steht" do
    assert {:ok, %{stand: s}} =
             Epos.laufen_ueberblick(eingabe(),
               modell: skript([lesen(), notieren(["S2-F1"]), fertig(1), abweichen(), fertig(1)]),
               kontext_fenster: 20_000
             )

    assert [%{schluessel: "2"}] = Stand.abschnitt(s, "ABWEICHUNG")

    [abgelehnt, abschluss] =
      for {"abschluss.jsonl", eintrag} <- Stand.journal_liste(s), do: eintrag

    assert abgelehnt["versuch"] == "abgelehnt"
    assert [h] = abgelehnt["hindernisse"]
    assert h =~ "„2“ — Mira klopft"
    assert abschluss["abschluss"] == true
    assert abschluss["zahlen_stimmten"] == "ja"
  end

  test "ohne fertig: ein Fehler mit eigener Marke" do
    assert {:error, {:epos_ueberblick_ohne_abschluss, _}} =
             Epos.laufen_ueberblick(eingabe(),
               modell: skript([lesen() | List.duplicate(ohne_aufruf(), 4)]),
               kontext_fenster: 20_000
             )
  end

  test "ohne Fakten oder mit zu kleinem Fenster: Fehler vor dem ersten Modellaufruf" do
    assert {:error, :keine_fakten} =
             Epos.laufen_ueberblick(%{eingabe() | fakten: []}, modell: skript([]))

    assert {:error, {:kontext_fenster_ungueltig, 100, _}} =
             Epos.laufen_ueberblick(eingabe(), modell: skript([]), kontext_fenster: 100)

    refute_received {:sitzung, _}
  end
end
