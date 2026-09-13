defmodule Worker.Jack.Resuemee.SucheLaufTest do
  # E0 (#1210): Blättern in einem echten Lauf der Laufzeit, mit einem
  # geskripteten Modell (Muster `lauf_test.exs`). Die Wiederholungssperre
  # trifft das Blättern nicht — gezählt wird erst, wenn es nichts Neues mehr
  # bringt. Kein Ollama, kein Mnesia.
  use ExUnit.Case, async: true

  alias Worker.Jack.Resuemee
  alias Worker.Jack.Resuemee.Eingabe

  defmodule Skript do
    @moduledoc false
    @behaviour Worker.Agent.Modell

    @impl true
    def antworten(nachrichten, _werkzeuge, opts) do
      case Agent.get_and_update(Keyword.fetch!(opts, :skript), fn
             [kopf | rest] -> {kopf, rest}
             [] -> {nil, []}
           end) do
        nil -> raise "Skript erschöpft; zuletzt: #{inspect(Enum.take(nachrichten, -2))}"
        schritt -> {:ok, schritt}
      end
    end
  end

  defp antwort(aufrufe),
    do: %{text: nil, denken: nil, aufrufe: aufrufe, stopp: :werkzeuge, nutzung: nil}

  defp aufruf(name, args), do: %{id: "id_#{name}", name: name, argumente: {:ok, args}}

  defp skript(schritte) do
    {:ok, s} = Agent.start_link(fn -> schritte end)
    {Skript, skript: s}
  end

  # 130 Blöcke mit „Uhr“: sieben Seiten zu höchstens 20.
  defp eingabe do
    bloecke =
      for i <- 0..129,
          do: %{text: "Die Uhr Nummer #{i} tickt.", sprecher: "SL", block_id: "u#{i}"}

    roh = [
      %{"id" => "f_a", "claim" => "Die Gruppe steht vor der Werkstatt.", "source_refs" => ["u0"]},
      %{"id" => "f_b", "claim" => "Mira klopft an die Tür.", "source_refs" => ["u1"]}
    ]

    fakten = Eingabe.fakten(roh, 2, %{}, %{"u0" => 0, "u1" => 1})

    %{
      sitzung: %{id: "s2", nummer: 2, name: "Nach Norden"},
      fakten: fakten,
      fruehere: [],
      boegen: [],
      bloecke: bloecke,
      cast: ["Mira"],
      straenge: [],
      ueberschrift: "Resümee",
      flavor: %{base: nil, summary: nil}
    }
  end

  defp abschliessen do
    [
      antwort([aufruf("fakten", %{"von" => 1, "bis" => 2})]),
      antwort([
        aufruf("notiz", %{
          "eintraege" => [
            %{
              "abschnitt" => "FORM",
              "schluessel" => "Form",
              "zeile" => "chronologische Zusammenfassung",
              "fakten" => [],
              "boegen" => []
            },
            %{
              "abschnitt" => "GLIEDERUNG",
              "schluessel" => "1",
              "zeile" => "vor der Werkstatt",
              "fakten" => ["S2-F1", "S2-F2"],
              "boegen" => []
            }
          ]
        })
      ]),
      antwort([aufruf("fertig", %{"fakten" => 2, "gliederung" => 1, "offen_geblieben" => ""})])
    ]
  end

  defp protokoll do
    receive do
      {:agent, e} -> [e | protokoll()]
    after
      0 -> []
    end
  end

  test "zehnmal weiter: sechs Seiten und drei „keine weiteren“ laufen, erst der zehnte wird gewarnt" do
    suche = aufruf("suche_sitzung", %{"begriff" => "Uhr"})
    weiter = aufruf("suche_sitzung", %{"begriff" => "Uhr", "weiter" => true})

    schritte = [antwort([suche])] ++ List.duplicate(antwort([weiter]), 10) ++ abschliessen()

    assert {:ok, _} =
             Resuemee.laufen_ueberblick(eingabe(),
               modell: skript(schritte),
               kontext_fenster: 200_000,
               beobachter: self()
             )

    ereignisse = protokoll()

    texte =
      for %{"ereignis" => "ergebnis", "name" => "suche_sitzung", "text" => t} <- ereignisse,
          do: t

    assert length(texte) == 11
    [erste | weiters] = texte
    assert erste =~ "## Mitschnitt — 130 Treffer, hier 1 bis 20, 110 folgen"

    # Die ersten sechs weiter-Aufrufe — gleiche Argumente — liefern jedes Mal
    # die nächste Seite; keiner ist gesperrt.
    for {t, k} <- weiters |> Enum.take(6) |> Enum.with_index(1) do
      assert t =~ "## Mitschnitt — 130 Treffer, hier #{20 * k + 1} bis #{min(20 * k + 20, 130)}"
      refute t =~ "WIEDERHOLUNG"
    end

    # Danach bringt Blättern nichts Neues: erst jetzt zählt die Sperre, der
    # vierte gleiche Aufruf ohne neue Treffer wird nicht ausgeführt.
    assert weiters |> Enum.slice(6, 3) |> Enum.all?(&(&1 =~ "Keine weiteren Treffer"))
    assert List.last(texte) =~ "WIEDERHOLUNG — Du wiederholst dich"

    assert [%{"name" => "suche_sitzung", "anzahl" => 4, "folge" => "warnung"}] =
             for(%{"ereignis" => "wiederholung"} = e <- ereignisse, do: e)
  end
end
