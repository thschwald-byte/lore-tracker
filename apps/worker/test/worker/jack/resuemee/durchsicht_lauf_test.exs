defmodule Worker.Jack.Resuemee.DurchsichtLaufTest do
  # J5 (#1209, B3): die Durchsicht als Lauf der Laufzeit, allein und als
  # dritter Lauf von `laufen/2`, mit einem Stub-Modell (Muster
  # `schreiben_lauf_test.exs`). Kein Ollama, kein Mnesia.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Worker.Jack.Resuemee
  alias Worker.Jack.Resuemee.{Durchsicht, Eingabe}

  @uhrmacher "Der verschwundene Uhrmacher"
  @grund "Satz 2 lässt Brann klopfen, der Fakt S2-F2 nennt Mira."

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
      %{"id" => "f_a", "claim" => "Die Gruppe steht vor der Werkstatt.", "source_refs" => ["b0"]},
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
        %{text: "Ihr steht vor der Werkstatt.", sprecher: "SL", block_id: "b0"},
        %{text: "Ich klopfe an.", sprecher: "Mira", block_id: "b1"}
      ],
      cast: ["Mira", "Brann"],
      straenge: [@uhrmacher],
      ueberschrift: "Rückblick",
      flavor: %{base: "Knapp und trocken.", summary: nil}
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

  defp saetze(wer),
    do: [
      %{"text" => "Die Gruppe steht vor der Werkstatt.", "fakten" => ["S2-F1"]},
      %{"text" => "#{wer} klopft an die Tür.", "fakten" => ["S2-F2"]}
    ]

  # Der Entwurf aus dem Schreiben, mit der falschen Figur in Satz 2.
  defp entwurf, do: [%{"titel" => "Vor der Werkstatt", "saetze" => saetze("Brann")}]

  @falsch "**Vor der Werkstatt**\nDie Gruppe steht vor der Werkstatt. Brann klopft an die Tür."
  @richtig "**Vor der Werkstatt**\nDie Gruppe steht vor der Werkstatt. Mira klopft an die Tür."

  defp ueberblick_schritte do
    [
      antwort([aufruf("fakten", %{"von" => 1, "bis" => 2})]),
      antwort([aufruf("notiz", %{"eintraege" => ablage()["notizen"]})]),
      antwort([
        aufruf("fertig", %{"fakten" => 2, "gliederung" => 1, "offen_geblieben" => ""})
      ])
    ]
  end

  defp schreib_schritte do
    [
      antwort([aufruf("absatz", %{"titel" => "Vor der Werkstatt", "saetze" => saetze("Brann")})]),
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

  # Durchsicht: lesen, die falsche Figur ersetzen, im zweiten Durchgang
  # bestätigen, fertig.
  defp durchsicht_schritte do
    [
      antwort([aufruf("durchsicht", %{"nummer" => 1})]),
      antwort([
        aufruf("absatz_ersetzen", %{
          "nummer" => 1,
          "titel" => "Vor der Werkstatt",
          "grund" => @grund,
          "saetze" => saetze("Mira")
        })
      ]),
      antwort([aufruf("durchsicht", %{"nummer" => 1})]),
      antwort([aufruf("absatz_bestaetigen", %{"nummer" => 1})]),
      antwort([
        aufruf("fertig", %{"bestaetigt" => 1, "ersetzt" => 1, "offen_geblieben" => ""})
      ])
    ]
  end

  test "Ton, Notizen, Entwurf, dann Auftrag; heraus kommt der durchgesehene Entwurf" do
    assert {:ok, %{stand: s, markdown: @richtig, runden: runden}} =
             Resuemee.laufen_durchsicht(eingabe(), ablage(), entwurf(),
               modell: skript(durchsicht_schritte()),
               kontext_fenster: 20_000,
               stand_beobachter: self()
             )

    assert is_integer(runden)
    assert s.lauf == :durchsicht
    assert s.durchsicht.durchgang == 2
    assert %{"ersetzt" => 1, "bestaetigt" => 1} = Durchsicht.zaehlwerte(s)

    assert_received {:sitzung, auftrag}
    refute auftrag =~ "{{"
    assert auftrag =~ "# Die Durchsicht des Resümees von Sitzung 2"

    [ton, form, absatz, aufgabe] =
      for m <- [
            "**Grundton der Kampagne:** Knapp und trocken.",
            "### FORM\nForm — chronologische Nacherzählung",
            "Absatz 1 — Vor der Werkstatt\n  1. Die Gruppe steht vor der Werkstatt.  [S2-F1]",
            "## Deine Aufgabe"
          ],
          do: auftrag |> :binary.match(m) |> elem(0)

    assert ton < form and form < absatz and absatz < aufgabe

    assert_received {:jack_resuemee_stand,
                     %{"lauf" => "durchsicht", "durchsicht" => %{"durchgang" => 1}}}
  end

  test "ohne fertig: ein Fehler" do
    assert {:error, {:durchsicht_ohne_abschluss, _}} =
             Resuemee.laufen_durchsicht(eingabe(), ablage(), entwurf(),
               modell:
                 skript([
                   antwort([aufruf("durchsicht", %{"nummer" => 1})])
                   | List.duplicate(ohne_aufruf(), 4)
                 ]),
               kontext_fenster: 20_000
             )
  end

  test "ohne Absatz im Entwurf oder ohne Fakten: Fehler vor dem ersten Modellaufruf" do
    assert {:error, :entwurf_leer} =
             Resuemee.laufen_durchsicht(eingabe(), ablage(), [], modell: skript([]))

    assert {:error, :keine_fakten} =
             Resuemee.laufen_durchsicht(%{eingabe() | fakten: []}, ablage(), entwurf(),
               modell: skript([])
             )

    refute_received {:sitzung, _}
  end

  test "laufen/2: Überblick, Schreiben, Durchsicht — das Markdown kommt aus der Durchsicht" do
    assert {:ok, %{schreiben: sch, durchsicht: d, markdown: @richtig}} =
             Resuemee.laufen(eingabe(),
               modell:
                 skript(ueberblick_schritte() ++ schreib_schritte() ++ durchsicht_schritte()),
               kontext_fenster: 20_000
             )

    assert sch.markdown == @falsch
    assert d.stand.lauf == :durchsicht
    assert d.stand.notizen == sch.stand.notizen

    assert_received {:sitzung, _ueberblick}
    assert_received {:sitzung, _schreiben}
    assert_received {:sitzung, dritter}
    assert dritter =~ "Absatz 1 — Vor der Werkstatt"
    assert dritter =~ "Brann klopft an die Tür.  [S2-F2]"
  end

  test "laufen/2: scheitert die Durchsicht, gilt der Entwurf aus dem Schreiben" do
    {ergebnis, log} =
      with_log(fn ->
        Resuemee.laufen(eingabe(),
          modell:
            skript(
              ueberblick_schritte() ++
                schreib_schritte() ++
                [antwort([aufruf("durchsicht", %{"nummer" => 1})])] ++
                List.duplicate(ohne_aufruf(), 4)
            ),
          kontext_fenster: 20_000
        )
      end)

    assert {:ok, %{durchsicht: {:error, {:durchsicht_ohne_abschluss, _}}, markdown: @falsch}} =
             ergebnis

    assert log =~ "Durchsicht von Sitzung 2 gescheitert, es gilt der Entwurf aus dem Schreiben"
  end

  test "laufen/2 mit durchsicht: false überspringt den dritten Lauf" do
    assert {:ok, %{durchsicht: :uebersprungen, markdown: @falsch}} =
             Resuemee.laufen(eingabe(),
               modell: skript(ueberblick_schritte() ++ schreib_schritte()),
               kontext_fenster: 20_000,
               durchsicht: false
             )

    assert_received {:sitzung, _}
    assert_received {:sitzung, _}
    refute_received {:sitzung, _}
  end
end
