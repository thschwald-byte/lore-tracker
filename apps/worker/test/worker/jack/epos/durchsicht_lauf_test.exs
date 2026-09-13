defmodule Worker.Jack.Epos.DurchsichtLaufTest do
  # J6 (#1210, E3): die Durchsicht des Epos-Jack als Lauf der Laufzeit, allein
  # und als dritter Lauf von `laufen/2`, mit einem Stub-Modell (Muster
  # `resuemee/durchsicht_lauf_test.exs`). Kein Ollama, kein Mnesia.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Worker.Jack.Epos
  alias Worker.Jack.Epos.Durchsicht
  alias Worker.Jack.Resuemee.Eingabe

  @uhrmacher "Der verschwundene Uhrmacher"
  @grund "Brann klopft, der Fakt S2-F2 nennt Mira."
  @falsch "Der Regen hing über dem Hafen, als Brann an die Tür der Werkstatt klopfte."
  @richtig "Der Regen hing über dem Hafen, als Mira an die Tür der Werkstatt klopfte."

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
      %{
        "id" => "f_b",
        "claim" => "Mira klopft an die Tür.",
        "source_refs" => ["b1"],
        "character_alias" => "Mira"
      }
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
      cast: ["Mira", "Brann"],
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

  defp ablage, do: %{"notizen" => notizen()}

  # Das Kapitel aus dem Schreiben, mit der falschen Figur.
  defp entwurf, do: [%{"text" => @falsch, "szene" => "Regen"}]

  defp ueberblick_schritte do
    [
      antwort([aufruf("fakten", %{"von" => 1, "bis" => 2})]),
      antwort([aufruf("notiz", %{"eintraege" => notizen()})]),
      antwort([aufruf("fertig", %{"fakten" => 2, "szenen" => 1, "offen_geblieben" => ""})])
    ]
  end

  defp schreib_schritte do
    [
      antwort([aufruf("absatz", %{"text" => @falsch, "szene" => "Regen"})]),
      antwort([aufruf("fertig", %{"absaetze" => 1, "offen_geblieben" => ""})])
    ]
  end

  # Durchsicht: lesen, die falsche Figur ersetzen, im zweiten Durchgang
  # bestätigen, fertig.
  defp durchsicht_schritte do
    [
      antwort([aufruf("durchsicht", %{"nummer" => 1})]),
      antwort([
        aufruf("absatz_ersetzen", %{
          "nummer" => 1,
          "szene" => "Regen",
          "grund" => @grund,
          "text" => @richtig
        })
      ]),
      antwort([aufruf("durchsicht", %{"nummer" => 1})]),
      antwort([aufruf("absatz_bestaetigen", %{"nummer" => 1})]),
      antwort([
        aufruf("fertig", %{"bestaetigt" => 1, "ersetzt" => 1, "offen_geblieben" => ""})
      ])
    ]
  end

  defp gescheiterte_durchsicht,
    do: [antwort([aufruf("durchsicht", %{"nummer" => 1})]) | List.duplicate(ohne_aufruf(), 4)]

  test "Stil, Szenen, Kapitel, dann Auftrag; heraus kommt das durchgesehene Kapitel" do
    assert {:ok, %{stand: s, markdown: @richtig, runden: runden}} =
             Epos.laufen_durchsicht(eingabe(), ablage(), entwurf(),
               modell: skript(durchsicht_schritte()),
               kontext_fenster: 20_000,
               stand_beobachter: self()
             )

    assert is_integer(runden)
    assert s.art == :epos
    assert s.lauf == :durchsicht
    assert s.durchsicht.durchgang == 2
    assert [%{text: @richtig, szene: "Regen"}] = s.entwurf
    assert %{"ersetzt" => 1, "bestaetigt" => 1} = Durchsicht.zaehlwerte(s)

    assert_received {:sitzung, auftrag}
    refute auftrag =~ "{{"
    assert auftrag =~ "# Die Durchsicht des Epos-Kapitels von Sitzung 2"

    [ton, form, szenen, kapitel, aufgabe] =
      for m <- [
            "**Ton des Epos:** Nah an der Gruppe.",
            "> Heldenlied in Szenen, nah an der Gruppe",
            "### SZENEN\nRegen — Nacht, Regen, vor der Werkstatt",
            "Absatz 1 (Fließtext) · ",
            "## Deine Aufgabe"
          ],
          do: auftrag |> :binary.match(m) |> elem(0)

    assert ton < form and form < szenen and szenen < kapitel and kapitel < aufgabe
    assert auftrag =~ @falsch

    assert_received {:jack_resuemee_stand,
                     %{
                       "jack" => "epos",
                       "lauf" => "durchsicht",
                       "durchsicht" => %{"durchgang" => 1}
                     }}
  end

  test "ohne fertig: ein Fehler mit eigener Marke" do
    assert {:error, {:epos_durchsicht_ohne_abschluss, _}} =
             Epos.laufen_durchsicht(eingabe(), ablage(), entwurf(),
               modell: skript(gescheiterte_durchsicht()),
               kontext_fenster: 20_000
             )
  end

  test "ohne Absatz im Kapitel oder ohne Fakten: Fehler vor dem ersten Modellaufruf" do
    assert {:error, :entwurf_leer} =
             Epos.laufen_durchsicht(eingabe(), ablage(), [], modell: skript([]))

    assert {:error, :entwurf_leer} =
             Epos.laufen_durchsicht(eingabe(), ablage(), [%{"text" => "  "}], modell: skript([]))

    assert {:error, :keine_fakten} =
             Epos.laufen_durchsicht(%{eingabe() | fakten: []}, ablage(), entwurf(),
               modell: skript([])
             )

    refute_received {:sitzung, _}
  end

  test "laufen/2: Überblick, Schreiben, Durchsicht — das Markdown kommt aus der Durchsicht" do
    assert {:ok, %{ueberblick: u, schreiben: sch, durchsicht: d, markdown: @richtig}} =
             Epos.laufen(eingabe(),
               modell:
                 skript(ueberblick_schritte() ++ schreib_schritte() ++ durchsicht_schritte()),
               kontext_fenster: 20_000
             )

    assert u.stand.lauf == :ueberblick
    assert sch.markdown == @falsch
    assert d.stand.lauf == :durchsicht
    assert d.stand.notizen == sch.stand.notizen
    assert d.stand.durchsicht.ausgang == sch.stand.entwurf

    # Das Ergebnis arbeitet auf dem Kapitel nach der Durchsicht.
    assert Epos.Ergebnis.zaehlwerte(d.stand)["durchsicht"]["ersetzt"] == 1
    assert [%{szene: "Regen", fakt_ids: ["f_a", "f_b"]}] = Epos.Ergebnis.quellen(d.stand)

    assert_received {:sitzung, _ueberblick}
    assert_received {:sitzung, _schreiben}
    assert_received {:sitzung, dritter}
    assert dritter =~ "# Die Durchsicht des Epos-Kapitels von Sitzung 2"
    assert dritter =~ "Absatz 1 (Fließtext) · 14 Wörter · Szene „Regen“\n" <> @falsch
  end

  test "laufen/2: scheitert die Durchsicht, gilt das Kapitel aus dem Schreiben" do
    {ergebnis, log} =
      with_log(fn ->
        Epos.laufen(eingabe(),
          modell:
            skript(ueberblick_schritte() ++ schreib_schritte() ++ gescheiterte_durchsicht()),
          kontext_fenster: 20_000
        )
      end)

    assert {:ok, %{durchsicht: {:error, {:epos_durchsicht_ohne_abschluss, _}}, markdown: @falsch}} =
             ergebnis

    assert log =~
             "Epos-Jack: Durchsicht von Sitzung 2 gescheitert, es gilt das Kapitel aus dem Schreiben"
  end

  test "laufen/2 mit durchsicht: false überspringt den dritten Lauf" do
    assert {:ok, %{durchsicht: :uebersprungen, markdown: @falsch}} =
             Epos.laufen(eingabe(),
               modell: skript(ueberblick_schritte() ++ schreib_schritte()),
               kontext_fenster: 20_000,
               durchsicht: false
             )

    assert_received {:sitzung, _}
    assert_received {:sitzung, _}
    refute_received {:sitzung, _}
  end
end
