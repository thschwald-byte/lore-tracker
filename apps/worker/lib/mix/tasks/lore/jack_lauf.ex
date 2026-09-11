defmodule Mix.Tasks.Lore.Jack.Lauf do
  @shortdoc "Messlauf wie Reihe C gegen das echte Modell (J3, #1195)"
  @moduledoc """
  Fährt einen Messlauf (`Worker.Jack.Messlauf`) auf der Eingabe des Spikes
  gegen Ollama und zeigt ihn in der Laufsicht (`Worker.Jack.Sicht`).

      mix lore.jack.lauf --daten <spike-daten> --namen <namensdatei> --auftraege <dir>
                         [--nach <dir>] [--durchgaenge 8] [--port 8098] [--ohne-sicht]
                         [--endpunkt http://localhost:11434] [--modell qwen3.8:27b]
                         [--fortsetzen --nach <verzeichnis eines abgebrochenen Laufs>]
                         [--denken-zurueck] [--beispiele <datei>]

    * `--daten` — `sharp-solution/daten` (`bloecke.tsv`, `cast.txt`,
      `straenge.txt`; `fakten_voll.tsv` geht als Beilage mit).
    * `--namen` — die Namensdatei (Handles → Figurennamen), außerhalb des
      Repos.
    * `--auftraege` — Verzeichnis mit `s1_phase1.md`, `s1_phase2.md`,
      `s1_folgelauf.md`, etwa `~/.local/share/lore-jack/auftraege/7ecc9ea8`.
    * `--nach` — Default `~/.local/share/lore-jack/laeufe/<zeitstempel>`;
      nie ins Scratchpad oder nach `/tmp`, und nie ein bestehendes
      Verzeichnis (es wird nichts überschrieben).
    * `--fortsetzen` — setzt den abgebrochenen Messlauf unter `--nach` ab
      dem nächsten Durchgang fort (`Worker.Jack.Messlauf.fortsetzen/1`);
      `--daten`, `--namen` und `--auftraege` müssen dieselben sein wie beim
      ersten Start.
    * `--denken-zurueck` — die Denkspur geht wie bei pi an das Modell zurück
      (Default aus, siehe `Worker.Agent.Lauf`); steht in `messlauf.json`.
      Ob Ollama sie wirklich einrechnet, prüft vorher
      `mix lore.jack.denkprobe`.
    * `--beispiele` — der Beispielsatz für den Regelfilter-Lauf
      (`Worker.Jack.Beispiele`); dann hat Phase 2 die Werkzeuge `beispiele` und
      `beispiel`, Pfad und sha256 stehen in `messlauf.json`. Ohne bleibt der
      Werkzeugsatz wie im Spike. Die Aufträge dazu liegen in einem eigenen
      Verzeichnis (eve: `sharp-solution/auftraege_beispiele/`).

  **Belegt die Karte.** Der Task bricht ab, solange eine Spike-VM läuft
  (`lauf.qcow2`), damit nicht zwei Läufe um die GPU konkurrieren. Ob der
  Lauf überhaupt starten darf, entscheidet Tom — der Task fragt nicht.
  """

  use Mix.Task

  alias Worker.Jack.{Abzug, Beispiele, Messlauf, Sicht}

  @aufruf "Aufruf: mix lore.jack.lauf --daten <dir> --namen <datei> --auftraege <dir> " <>
            "[--nach <dir>] [--durchgaenge n] [--port p] [--ohne-sicht] [--endpunkt url] [--modell name]"

  @impl Mix.Task
  def run(args) do
    opts = optionen!(args)
    Mix.Task.run("compile")
    keine_spike_vm!()
    # Ein Mix-Task startet die Anwendungen nicht; der Ollama-Adapter braucht
    # Req samt Finch-Pool. Der Worker selbst (Mnesia, Hub) bleibt aus.
    {:ok, _} = Application.ensure_all_started(:req)

    namen = namen!(opts[:namen])

    eingabe =
      case Abzug.spike_laden(opts[:daten], namen) do
        {:ok, e} -> e
        {:error, grund} -> Mix.raise("Eingabe: #{inspect(grund)}")
      end

    auftraege =
      case Messlauf.auftraege(opts[:auftraege]) do
        {:ok, a} -> a
        {:error, grund} -> Mix.raise("Aufträge: #{inspect(grund)}")
      end

    beispiele = beispiele!(opts[:beispiele])
    nach = if opts[:fortsetzen], do: bestehend!(opts[:nach]), else: ziel!(opts[:nach])
    sicht = sicht(opts)

    Mix.shell().info(
      "Messlauf nach #{nach}: #{length(eingabe.bloecke)} Blöcke, #{length(eingabe.cast)} im Cast, " <>
        "#{length(eingabe.straenge)} Stränge, Modell #{opts[:modell] || "qwen3.8:27b"}, " <>
        "Denken zurück: #{if opts[:denken_zurueck], do: "ja", else: "nein"}, " <>
        "Beispiele: #{if beispiele, do: "bis Nr. #{Beispiele.max(beispiele)} (#{String.slice(beispiele.sha256, 0, 12)})", else: "keine"}."
    )

    ergebnis =
      starten(opts[:fortsetzen],
        eingabe: eingabe,
        auftraege: auftraege,
        nach: nach,
        durchgaenge: Keyword.get(opts, :durchgaenge, 8),
        sicht: sicht,
        modell:
          Messlauf.modell_reihe_c(
            Enum.reject(
              [endpunkt: opts[:endpunkt], modell_name: opts[:modell]],
              fn {_, v} -> is_nil(v) end
            )
          ),
        denken_zurueck: opts[:denken_zurueck] || false,
        beispiele: beispiele,
        beilagen: [
          {Path.join(opts[:daten], "bloecke.tsv"), "bloecke_mit_sprecher.tsv"},
          {Path.join(opts[:daten], "fakten_voll.tsv"), "fakten_voll.tsv"}
        ],
        melden: &melden/1
      )

    Mix.shell().info("Messlauf beendet: #{inspect(ergebnis.ende)} — #{nach}/messlauf.json")
  end

  defp optionen!(args) do
    strict = [
      daten: :string,
      namen: :string,
      auftraege: :string,
      nach: :string,
      durchgaenge: :integer,
      port: :integer,
      ohne_sicht: :boolean,
      endpunkt: :string,
      modell: :string,
      fortsetzen: :boolean,
      denken_zurueck: :boolean,
      beispiele: :string
    ]

    case OptionParser.parse(args, strict: strict) do
      {opts, [], []} ->
        if opts[:daten] && opts[:namen] && opts[:auftraege], do: opts, else: Mix.raise(@aufruf)

      _ ->
        Mix.raise(@aufruf)
    end
  end

  defp keine_spike_vm! do
    case System.cmd("pgrep", ["-f", "lauf\\.qcow2"], stderr_to_stdout: true) do
      {"", _} -> :ok
      {pids, 0} -> Mix.raise("Eine Spike-VM läuft (#{String.trim(pids)}) — erst nach ihrem Ende.")
      _ -> :ok
    end
  end

  defp namen!(pfad) do
    with {:ok, text} <- File.read(pfad),
         {:ok, namen} <- Abzug.namen_aus_text(text) do
      namen
    else
      {:error, grund} -> Mix.raise("Namensdatei #{pfad}: #{inspect(grund)}")
    end
  end

  defp ziel!(nil) do
    stempel = DateTime.utc_now() |> Calendar.strftime("%Y%m%d-%H%M%S")
    ziel!(Path.expand("~/.local/share/lore-jack/laeufe/#{stempel}"))
  end

  defp ziel!(pfad) do
    if File.exists?(pfad), do: Mix.raise("#{pfad} gibt es schon — ein neues Verzeichnis nehmen.")
    File.mkdir_p!(pfad)
    File.chmod!(pfad, 0o700)
    pfad
  end

  defp beispiele!(nil), do: nil

  defp beispiele!(pfad) do
    case Beispiele.laden(pfad) do
      {:ok, b} -> b
      {:error, grund} -> Mix.raise("Beispiele: #{inspect(grund)}")
    end
  end

  defp bestehend!(nil), do: Mix.raise("--fortsetzen braucht --nach <verzeichnis des Laufs>.")

  defp bestehend!(pfad) do
    unless File.exists?(Path.join(pfad, "messlauf.json")),
      do: Mix.raise("#{pfad}/messlauf.json fehlt — dort liegt kein Messlauf zum Fortsetzen.")

    pfad
  end

  defp starten(true, lauf_opts) do
    case Messlauf.fortsetzen(lauf_opts) do
      {:error, grund} -> Mix.raise("Fortsetzen geht nicht: #{inspect(grund)}")
      ergebnis -> ergebnis
    end
  end

  defp starten(_neu, lauf_opts), do: Messlauf.laufen(lauf_opts)

  defp sicht(opts) do
    if opts[:ohne_sicht] do
      nil
    else
      {:ok, _} = Application.ensure_all_started(:plug_cowboy)

      case Sicht.start_link(port: Keyword.get(opts, :port, 8098)) do
        {:ok, sicht} ->
          Mix.shell().info("Laufsicht: http://127.0.0.1:#{Sicht.port(sicht)}")
          sicht

        {:error, grund} ->
          Mix.raise("Laufsicht startet nicht: #{inspect(grund)}")
      end
    end
  end

  defp melden({:phase, nr, dir}), do: Mix.shell().info("Phase #{nr} beginnt → #{dir}")

  defp melden({:durchgang, d}),
    do:
      Mix.shell().info(
        "Durchgang #{d.nr} (#{d.durchgang}): #{d.bestand} Aussagen, #{d.neu} neu, Ende #{inspect(d.ende)}"
      )
end
