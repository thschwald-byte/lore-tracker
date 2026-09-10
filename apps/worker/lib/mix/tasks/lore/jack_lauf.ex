defmodule Mix.Tasks.Lore.Jack.Lauf do
  @shortdoc "Messlauf wie Reihe C gegen das echte Modell (J3, #1195)"
  @moduledoc """
  Fährt einen Messlauf (`Worker.Jack.Messlauf`) auf der Eingabe des Spikes
  gegen Ollama und zeigt ihn in der Laufsicht (`Worker.Jack.Sicht`).

      mix lore.jack.lauf --daten <spike-daten> --namen <namensdatei> --auftraege <dir>
                         [--nach <dir>] [--durchgaenge 8] [--port 8098] [--ohne-sicht]
                         [--endpunkt http://localhost:11434] [--modell qwen3.8:27b]

    * `--daten` — `sharp-solution/daten` (`bloecke.tsv`, `cast.txt`,
      `straenge.txt`; `fakten_voll.tsv` geht als Beilage mit).
    * `--namen` — die Namensdatei (Handles → Figurennamen), außerhalb des
      Repos.
    * `--auftraege` — Verzeichnis mit `s1_phase1.md`, `s1_phase2.md`,
      `s1_folgelauf.md`, etwa `~/.local/share/lore-jack/auftraege/7ecc9ea8`.
    * `--nach` — Default `~/.local/share/lore-jack/laeufe/<zeitstempel>`;
      nie ins Scratchpad oder nach `/tmp`, und nie ein bestehendes
      Verzeichnis (es wird nichts überschrieben).

  **Belegt die Karte.** Der Task bricht ab, solange eine Spike-VM läuft
  (`lauf.qcow2`), damit nicht zwei Läufe um die GPU konkurrieren. Ob der
  Lauf überhaupt starten darf, entscheidet Tom — der Task fragt nicht.
  """

  use Mix.Task

  alias Worker.Jack.{Abzug, Messlauf, Sicht}

  @aufruf "Aufruf: mix lore.jack.lauf --daten <dir> --namen <datei> --auftraege <dir> " <>
            "[--nach <dir>] [--durchgaenge n] [--port p] [--ohne-sicht] [--endpunkt url] [--modell name]"

  @impl Mix.Task
  def run(args) do
    opts = optionen!(args)
    Mix.Task.run("compile")
    keine_spike_vm!()

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

    nach = ziel!(opts[:nach])
    sicht = sicht(opts)

    Mix.shell().info(
      "Messlauf nach #{nach}: #{length(eingabe.bloecke)} Blöcke, #{length(eingabe.cast)} im Cast, " <>
        "#{length(eingabe.straenge)} Stränge, Modell #{opts[:modell] || "qwen3.8:27b"}."
    )

    ergebnis =
      Messlauf.laufen(
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
      modell: :string
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
