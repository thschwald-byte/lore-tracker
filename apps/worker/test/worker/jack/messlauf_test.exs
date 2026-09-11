defmodule Worker.Jack.MesslaufTest do
  # Der Ablauf der Reihe C mit einem Stub-Modell: Phase 1, Phase 2, ein
  # Folgedurchgang ohne Neues — gesättigt. Kein Ollama.
  use ExUnit.Case, async: true

  alias Worker.Jack.{Messlauf, Systemprompt}

  @bloecke for i <- 0..9,
               do: %{text: "Satz #{i} im Mitschnitt.", sprecher: "Figur", block_id: "b#{i}"}

  # Spielt ein Skript ab und meldet den Auftrag jeder frischen Sitzung.
  defmodule Skript do
    @moduledoc false
    @behaviour Worker.Agent.Modell

    @impl true
    def antworten(nachrichten, _werkzeuge, opts) do
      case nachrichten do
        [%{role: :system, content: sys}, %{role: :user, content: auftrag}] ->
          send(Keyword.fetch!(opts, :test), {:sitzung, sys, auftrag})

        _ ->
          :ok
      end

      case Agent.get_and_update(Keyword.fetch!(opts, :skript), fn [kopf | rest] ->
             {kopf, rest}
           end) do
        {:error, _} = fehler -> fehler
        antwort -> {:ok, antwort}
      end
    end
  end

  defp antwort(aufrufe),
    do: %{text: nil, denken: nil, aufrufe: aufrufe, stopp: :werkzeuge, nutzung: nil}

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

  @tag :tmp_dir
  test "Durchgang 1 mit beiden Phasen, dann Verifizieren bis nichts Neues kommt", %{tmp_dir: dir} do
    {:ok, skript} =
      Agent.start_link(fn ->
        [
          # Durchgang 1, Phase 1
          lesen(),
          gedaechtnis(),
          fertig(%{"bereiche" => 1, "eintraege" => 10}),
          # Durchgang 1, Phase 2
          lesen(),
          aussage(),
          fertig(%{"aussagen" => 1}),
          # Durchgang 2: verifiziert, nichts Neues
          lesen(),
          fertig(%{"aussagen" => 1})
        ]
      end)

    beilage = Path.join(dir, "bloecke.tsv")
    File.write!(beilage, "idx\tsprecher\ttext\n")
    nach = Path.join(dir, "lauf")

    e =
      Messlauf.laufen(
        eingabe: %{bloecke: @bloecke, cast: [], straenge: []},
        auftraege: %{phase1: "LESEN\n", phase2: "SAMMELN\n", folgelauf: "VERIFIZIEREN\n"},
        nach: nach,
        modell: {Skript, skript: skript, test: self()},
        beilagen: [{beilage, "bloecke_mit_sprecher.tsv"}]
      )

    assert %{ende: :gesaettigt, durchgaenge: [d1, d2]} = e
    assert %{nr: 1, durchgang: 1, vorher: 0, bestand: 1, neu: 1, ende: :halt} = d1
    assert %{nr: 2, durchgang: 2, vorher: 1, bestand: 1, neu: 0} = d2

    # drei frische Sitzungen, jede mit pis Systemprompt und ihrem Auftrag
    assert_received {:sitzung, sys, "LESEN\n\nDer Mitschnitt hat die Blöcke 0 bis 9."}
    assert sys == Systemprompt.pi()
    assert_received {:sitzung, _, "SAMMELN\n\n## Dein Gedächtnis\n\n" <> g}
    assert g =~ "## ABLAUF"
    assert_received {:sitzung, _, "VERIFIZIEREN\n\n## Dein Gedächtnis\n\n" <> _}

    assert File.exists?(Path.join([nach, "d1", "phase1", "notizen.txt"]))
    assert File.exists?(Path.join([nach, "d1", "aussagen.jsonl"]))
    assert File.exists?(Path.join([nach, "d2", "bloecke_mit_sprecher.tsv"]))

    assert %{
             "ende" => ":gesaettigt",
             "denken_zurueck" => false,
             "beispiele" => nil,
             "durchgaenge" => [_, %{"neu" => 0}]
           } =
             nach |> Path.join("messlauf.json") |> File.read!() |> Jason.decode!()
  end

  @tag :tmp_dir
  test "Phase 1 ohne fertig beendet den Messlauf, wie die Kette der Reihe C", %{tmp_dir: dir} do
    {:ok, skript} =
      Agent.start_link(fn ->
        [lesen(), %{text: "bin durch", denken: nil, aufrufe: [], stopp: :stop, nutzung: nil}]
      end)

    e =
      Messlauf.laufen(
        eingabe: %{bloecke: @bloecke, cast: [], straenge: []},
        auftraege: %{phase1: "L", phase2: "S", folgelauf: "V"},
        nach: Path.join(dir, "lauf"),
        modell: {Skript, skript: skript, test: self()}
      )

    assert %{ende: {:abgebrochen, {:phase1_ohne_abschluss, :fertig}}, durchgaenge: []} = e
  end

  @tag :tmp_dir
  test "fortsetzen: ein abgebrochener Messlauf läuft ab dem nächsten Durchgang weiter",
       %{tmp_dir: dir} do
    nach = Path.join(dir, "lauf")

    basis = [
      eingabe: %{bloecke: @bloecke, cast: [], straenge: []},
      auftraege: %{phase1: "LESEN\n", phase2: "SAMMELN\n", folgelauf: "VERIFIZIEREN\n"},
      nach: nach
    ]

    # Durchgang 2 bricht an einem Modellfehler ab, der nicht vorübergehend ist.
    {:ok, erster} =
      Agent.start_link(fn ->
        [
          lesen(),
          gedaechtnis(),
          fertig(%{"bereiche" => 1, "eintraege" => 10}),
          lesen(),
          aussage(),
          fertig(%{"aussagen" => 1}),
          lesen(),
          {:error, :kaputt}
        ]
      end)

    assert %{ende: {:abgebrochen, {:laufzeit, {:modell_fehler, :kaputt}}}, durchgaenge: [_, _]} =
             Messlauf.laufen(basis ++ [modell: {Skript, skript: erster, test: self()}])

    # Mit anderem Schalter als der Lauf selbst wird nicht fortgesetzt.
    assert {:error, {:denken_zurueck_anders, false, true}} =
             Messlauf.fortsetzen(basis ++ [denken_zurueck: true])

    # Ebenso mit einem anderen Beispielsatz.
    {:ok, satz} = Worker.Jack.Beispiele.lesen("### Beispiel 1 · Regel · x\nText\n")

    assert {:error, {:beispiele_anders, nil, _}} =
             Messlauf.fortsetzen(basis ++ [beispiele: satz])

    refute File.exists?(Path.join(nach, "messlauf_vor_fortsetzung.json"))

    {:ok, zweiter} = Agent.start_link(fn -> [lesen(), fertig(%{"aussagen" => 1})] end)

    assert %{ende: :gesaettigt, durchgaenge: [d1, d2, d3]} =
             Messlauf.fortsetzen(basis ++ [modell: {Skript, skript: zweiter, test: self()}])

    assert %{nr: 1, ende: {:frueher, ":halt"}} = d1
    assert %{nr: 2, ende: {:frueher, "{:modell_fehler, :kaputt}"}} = d2
    assert %{nr: 3, vorher: 1, bestand: 1, neu: 0} = d3

    assert %{
             "ende" => ":gesaettigt",
             "fortsetzungen" => [%{"ab" => 3, "vorheriges_ende" => "{:abgebrochen" <> _}],
             "durchgaenge" => [_, %{"ende" => "{:modell_fehler, :kaputt}"}, %{"nr" => 3}]
           } =
             nach |> Path.join("messlauf.json") |> File.read!() |> Jason.decode!()

    assert %{"ende" => "{:abgebrochen" <> _} =
             nach |> Path.join("messlauf_vor_fortsetzung.json") |> File.read!() |> Jason.decode!()

    # Ein gesättigter Lauf wird nicht noch einmal fortgesetzt.
    assert {:error, {:nicht_fortsetzbar, ":gesaettigt"}} = Messlauf.fortsetzen(basis)

    assert {:error, {:messlauf_json, :enoent}} =
             Messlauf.fortsetzen(Keyword.put(basis, :nach, dir))
  end

  test "Aufträge lesen: fehlt einer, ist das ein Fehler; das Modell der Reihe C" do
    assert {:error, {:auftrag_fehlt, _}} = Messlauf.auftraege("/gibt/es/nicht")

    assert {Worker.Agent.Modell.Ollama, o} = Messlauf.modell_reihe_c(endpunkt: "http://x:1")
    assert o[:modell] == "qwen3.8:27b"
    assert o[:endpunkt] == "http://x:1"
    assert o[:temperatur] == 0.7
    assert o[:max_ausgabe] == 60_000
    assert o[:extra] == %{"top_p" => 0.8, "frequency_penalty" => 0.4}
  end

  test "pis Systemprompt: Kopf, keine Werkzeugzeilen, Arbeitsverzeichnis /" do
    p = Systemprompt.pi()
    assert p =~ ~r/^You are an expert coding assistant operating inside pi/
    assert p =~ "\nAvailable tools:\n(none)\n"
    assert String.ends_with?(p, "\nCurrent working directory: /")
  end
end
