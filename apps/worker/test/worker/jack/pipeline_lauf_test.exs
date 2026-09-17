defmodule Worker.Jack.PipelineLaufTest do
  # J4 (#1207): ein Durchgang im Betrieb — Gedächtnis, Extraktion, Iteration —
  # im Speicher, mit einem Stub-Modell. Kein Ollama, keine Dateien.
  use ExUnit.Case, async: true

  alias Worker.Jack.{Phase, Pipeline}

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

  defp aussage_b do
    antwort([
      aufruf("aussage", %{
        # ohne gemeinsame Wörter mit der ersten — sonst legt das Tor sie als
        # mögliche Dublette vor
        "claim" => "Die Zählung erreicht fünf.",
        "beleg" => "Satz 5 im Mitschnitt",
        "source_refs" => [5],
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

  test "Gedächtnis, Extraktion, zwei Verifikationen ohne Neues — gesättigt: Fakten mit Block-IDs" do
    ohne_neues = [lesen(), fertig(%{"aussagen" => 1})]
    modell = skript(durchgang_1() ++ ohne_neues ++ ohne_neues)

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
               %{nr: 2, vorher: 1, bestand: 1, neu: 0},
               %{nr: 3, vorher: 1, bestand: 1, neu: 0}
             ]
           } = bericht

    # Für die nächste Iteration: Bestand und Übergabe samt Gedächtnis.
    assert %{"aussagen" => [%{"nummer" => 1}], "fortsetzung" => %{"register" => [_ | _]}} =
             bericht.ablage

    # drei frische Sitzungen, jede mit ihrem Auftrag; das Gedächtnis reist mit
    assert_received {:sitzung, "LESEN\n\nDer Mitschnitt hat die Blöcke 0 bis 9."}
    assert_received {:sitzung, "SAMMELN\n\n## Dein Gedächtnis\n\n" <> g}
    assert g =~ "## ABLAUF"
    assert_received {:sitzung, "VERIFIZIEREN\n\n## Dein Gedächtnis\n\n" <> _}
  end

  test "eine Verifikation ohne Neues ist noch nicht gesättigt; ein Fund setzt neu an" do
    modell =
      skript(
        durchgang_1() ++
          [lesen(), fertig(%{"aussagen" => 1})] ++
          [lesen(), aussage_b(), fertig(%{"aussagen" => 2})] ++
          [lesen(), fertig(%{"aussagen" => 2})]
      )

    # Deckel 3 erreicht, bevor zwei Verifikationen in Folge leer blieben.
    assert {:ok, [_, _], _saw, %{ende: :fertig, durchgaenge: ds}} =
             Pipeline.extrahieren(@kontext, %{"1" => "Figur"}, [], [],
               auftraege: @auftraege,
               modell: modell,
               iterationen: 3
             )

    assert Enum.map(ds, & &1.neu) == [1, 0, 1, 0]
  end

  test "das Kontextfenster geht an jede Phase; ohne Angabe gilt 98 304 wie in den Messläufen" do
    # J4 (#1207): im Betrieb kommt der Wert aus ctx_jack
    # (Pipeline.kontext_fenster/0). Sichtbar ist er im "start"-Eintrag des
    # Protokolls jeder Sitzung, den der Beobachter bekommt.
    ohne_neues = [lesen(), fertig(%{"aussagen" => 1})]

    assert {:ok, _, _, _} =
             Pipeline.extrahieren(@kontext, %{"1" => "Figur"}, [], [],
               auftraege: @auftraege,
               modell: skript(durchgang_1() ++ ohne_neues ++ ohne_neues),
               kontext_fenster: 20_000,
               beobachter: self()
             )

    # Gedächtnis, Extraktion, zwei Verifikationen — vier Sitzungen.
    assert start_fenster() == [20_000, 20_000, 20_000, 20_000]

    assert {:ok, _, _, _} =
             Pipeline.extrahieren(@kontext, %{"1" => "Figur"}, [], [],
               auftraege: @auftraege,
               modell: skript(durchgang_1()),
               iterationen: 0,
               beobachter: self()
             )

    assert start_fenster() == [98_304, 98_304]
  end

  # Die Kontextfenster aus den "start"-Einträgen im Postfach, in Reihenfolge.
  defp start_fenster(acc \\ []) do
    receive do
      {:agent, %{"ereignis" => "start", "kontext_fenster" => f}} -> start_fenster([f | acc])
      _anderes -> start_fenster(acc)
    after
      0 -> Enum.reverse(acc)
    end
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

  test "noch eine Iteration auf dem abgelegten Stand: nur der Folgelauf, Bestand alt und neu" do
    {:ok, _, _, %{ablage: ablage}} =
      Pipeline.extrahieren(@kontext, %{"1" => "Figur"}, [], [],
        auftraege: @auftraege,
        modell: skript(durchgang_1()),
        iterationen: 0
      )

    assert ablage["bloecke"] == Enum.map(@kontext, & &1.id)
    assert_received {:sitzung, "LESEN" <> _}
    assert_received {:sitzung, "SAMMELN" <> _}

    # Der Stand reist als Ereignis — derselbe JSON-Rundlauf wie im Fold.
    ablage = ablage |> Jason.encode!() |> Jason.decode!()
    modell = skript([lesen(), aussage_b(), fertig(%{"aussagen" => 2})])

    assert {:ok, facts, _saw,
            %{ende: :fertig, durchgaenge: [%{nr: 1, vorher: 1, bestand: 2, neu: 1}]}} =
             Pipeline.extrahieren(@kontext, %{"1" => "Figur"}, [], [],
               auftraege: @auftraege,
               modell: modell,
               ablage: ablage,
               iterationen: 1
             )

    assert facts |> Enum.map(& &1["source_refs"]) |> Enum.sort() == [["b3"], ["b5"]]

    # Nur der Folgelauf, mit dem Gedächtnis des ersten Laufs.
    assert_received {:sitzung, "VERIFIZIEREN\n\n## Dein Gedächtnis\n\n" <> g}
    assert g =~ "## ABLAUF"
    refute_received {:sitzung, "LESEN" <> _}
    refute_received {:sitzung, "SAMMELN" <> _}
  end

  test "nachhaken: dreimal zurück an die Arbeit, dann Schluss" do
    assert {:weiter, "Deine letzte Antwort enthielt keinen Werkzeugaufruf." <> _} =
             Phase.nachhaken(%{ohne_aufruf_in_folge: 1})

    assert {:weiter, _} = Phase.nachhaken(%{ohne_aufruf_in_folge: 3})
    assert :fertig = Phase.nachhaken(%{ohne_aufruf_in_folge: 4})
  end

  test "eine Antwort ohne Werkzeugaufruf kostet nicht mehr die Sitzung" do
    [les, gedaechtnis_, fertig1 | rest] = durchgang_1()
    modell = skript([les, ohne_aufruf(), gedaechtnis_, fertig1 | rest])

    assert {:ok, [_], _saw, %{ende: :fertig}} =
             Pipeline.extrahieren(@kontext, %{"1" => "Figur"}, [], [],
               auftraege: @auftraege,
               modell: modell,
               iterationen: 0
             )
  end

  test "Phase 1 ohne fertig: keine Extraktion, ein Fehler" do
    # erst nach der vierten Antwort ohne Aufruf in Folge gibt die Laufzeit auf
    modell = skript([lesen() | List.duplicate(ohne_aufruf(), 4)])

    assert {:error, {:phase1_ohne_abschluss, _}} =
             Pipeline.extrahieren(@kontext, %{"1" => "Figur"}, [], [],
               auftraege: @auftraege,
               modell: modell
             )
  end

  describe "Laufband: Jack meldet seine drei Stufen (J4, #1207)" do
    # Der Rückruf schickt alles ans Testpostfach. Beginn und Ende kommen aus
    # dem Lauf selbst (hier: dem Testprozess), Zählung und gelesene Blöcke aus
    # dem Melder der jeweiligen Phase — der ist fort, bevor die Phase als
    # beendet gilt (`Melder.stopp/1` wartet), seine Meldungen liegen also da.
    defp melde do
      ich = self()
      fn stufe, ereignis -> send(ich, {:melde, stufe, ereignis}) end
    end

    defp meldungen(acc \\ []) do
      receive do
        {:melde, stufe, ereignis} -> meldungen([{stufe, ereignis} | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    defp beginn_und_ende(ms),
      do: for({s, e} <- ms, e == :beginn or match?({:ende, _}, e), do: {s, e})

    # Gelesene Blöcke je Stufe und Durchgang: {stufe, nr} => Anzahl verschiedener.
    defp gelesen_je_stufe(ms) do
      for({s, {:gelesen, n, nr}} <- ms, do: {{s, nr}, n})
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {k, ns} -> {k, ns |> Enum.uniq() |> length()} end)
    end

    test "Gedächtnis → Extraktion → Verifikation, je mit Beginn und Ende; jede zählt ihre Blöcke" do
      ohne_neues = [lesen(), fertig(%{"aussagen" => 1})]

      assert {:ok, [_], _saw, %{ende: :gesaettigt}} =
               Pipeline.extrahieren(@kontext, %{"1" => "Figur"}, [], [],
                 auftraege: @auftraege,
                 modell: skript(durchgang_1() ++ ohne_neues ++ ohne_neues),
                 melde_stufe: melde()
               )

      ms = meldungen()

      assert beginn_und_ende(ms) == [
               {"jack_gedaechtnis", :beginn},
               {"jack_gedaechtnis", {:ende, :ok}},
               {"extract", :beginn},
               {"extract", {:ende, :ok}},
               {"jack_verifikation", :beginn},
               {"jack_verifikation", {:ende, :ok}}
             ]

      # Zehn Blöcke je Lesegang — nicht 40 über alle vier zusammen. Die zweite
      # Verifikation brachte nichts Neues und zählt trotzdem neu.
      assert gelesen_je_stufe(ms) == %{
               {"jack_gedaechtnis", nil} => 10,
               {"extract", nil} => 10,
               {"jack_verifikation", 1} => 10,
               {"jack_verifikation", 2} => 10
             }

      assert for({s, {:zaehlung, g, nr}} <- ms, do: {s, g, nr}) == [
               {"jack_gedaechtnis", 10, nil},
               {"extract", 10, nil},
               {"jack_verifikation", 10, 1},
               {"jack_verifikation", 10, 2}
             ]
    end

    test "ein Fehler in Phase 1 ist ein Fehlschlag des Gedächtnisses — die Extraktion beginnt nicht" do
      modell = skript([lesen() | List.duplicate(ohne_aufruf(), 4)])

      assert {:error, {:phase1_ohne_abschluss, _}} =
               Pipeline.extrahieren(@kontext, %{"1" => "Figur"}, [], [],
                 auftraege: @auftraege,
                 modell: modell,
                 melde_stufe: melde()
               )

      # Gemeldet in der Form, in der der Fehler die Pipeline verlässt — so
      # klassifiziert /admin/errors ihn wie bisher.
      assert [
               {"jack_gedaechtnis", :beginn},
               {"jack_gedaechtnis",
                {:ende, {:error, {:extraction, {:jack, {:phase1_ohne_abschluss, _}}}}}}
             ] = beginn_und_ende(meldungen())
    end

    test "eine abgebrochene Verifikation ist ihr Fehlschlag, der Bestand bleibt" do
      modell = skript(durchgang_1() ++ [lesen() | List.duplicate(ohne_aufruf(), 4)])

      assert {:ok, [_], _saw, %{ende: {:iteration_ohne_abschluss, _}}} =
               Pipeline.extrahieren(@kontext, %{"1" => "Figur"}, [], [],
                 auftraege: @auftraege,
                 modell: modell,
                 melde_stufe: melde()
               )

      assert [
               _,
               _,
               _,
               {"extract", {:ende, :ok}},
               {"jack_verifikation", :beginn},
               {"jack_verifikation",
                {:ende, {:error, {:extraction, {:jack, {:iteration_ohne_abschluss, _}}}}}}
             ] = beginn_und_ende(meldungen())
    end

    test "ohne Iteration läuft keine Verifikation — sie bleibt im Band offen" do
      assert {:ok, _, _, _} =
               Pipeline.extrahieren(@kontext, %{"1" => "Figur"}, [], [],
                 auftraege: @auftraege,
                 modell: skript(durchgang_1()),
                 iterationen: 0,
                 melde_stufe: melde()
               )

      refute Enum.any?(meldungen(), fn {s, _} -> s == "jack_verifikation" end)
    end

    test "noch N Iterationen: nur die Verifikation, Durchgänge ab 1" do
      {:ok, _, _, %{ablage: ablage}} =
        Pipeline.extrahieren(@kontext, %{"1" => "Figur"}, [], [],
          auftraege: @auftraege,
          modell: skript(durchgang_1()),
          iterationen: 0
        )

      assert {:ok, _, _, _} =
               Pipeline.extrahieren(@kontext, %{"1" => "Figur"}, [], [],
                 auftraege: @auftraege,
                 modell: skript([lesen(), aussage_b(), fertig(%{"aussagen" => 2})]),
                 ablage: ablage |> Jason.encode!() |> Jason.decode!(),
                 iterationen: 1,
                 melde_stufe: melde()
               )

      ms = meldungen()

      assert beginn_und_ende(ms) == [
               {"jack_verifikation", :beginn},
               {"jack_verifikation", {:ende, :ok}}
             ]

      assert gelesen_je_stufe(ms) == %{{"jack_verifikation", 1} => 10}
    end

    test "Sprecher ohne Namen: Fehlschlag der Extraktion, keine Phase beginnt" do
      assert {:error, {:sprecher_ohne_namen, ["1"]}} =
               Pipeline.extrahieren(@kontext, %{}, [], [],
                 auftraege: @auftraege,
                 modell: skript([]),
                 melde_stufe: melde()
               )

      assert meldungen() == [
               {"extract", :beginn},
               {"extract",
                {:ende, {:error, {:extraction, {:jack, {:sprecher_ohne_namen, ["1"]}}}}}}
             ]
    end
  end
end
