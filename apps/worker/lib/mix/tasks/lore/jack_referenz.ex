defmodule Mix.Tasks.Lore.Jack.Referenz do
  @shortdoc "Referenzlauf mit Claude Code headless und Jacks Werkzeugen über MCP (#1195)"
  @moduledoc """
  Ein Referenzlauf (`Worker.Jack.Referenz`): Durchgang 1, Phase 1 und 2, mit
  Claude Code headless als Agent und Jacks Werkzeugen über den MCP-Server
  (`mix lore.jack.mcp`). Zeigt den Lauf in der Laufsicht (Folge-Modus).

      mix lore.jack.referenz --daten <spike-daten> --namen <namensdatei> --auftraege <dir>
                             [--nach <dir>] [--beispiele <datei>] [--port 8097] [--ohne-sicht]
                             [--modell claude-fable-5-1] [--effort max] [--max-min 360]
      mix lore.jack.referenz --demo --auftraege <dir> [--nach <dir>]

    * `--demo` — die erfundenen Blöcke der Demo statt echter Daten: ein
      Probelauf, bei dem nichts aus einem Mitschnitt das Haus verlässt.
    * `--nach` — Default `~/.local/share/lore-jack/laeufe/ref-<zeitstempel>`;
      nie ein bestehendes Verzeichnis.
    * `--max-min` — Zeitgrenze je Phase in Minuten (Claude Code kennt keinen
      Zugdeckel).
    * `--fortsetzen` — einen abgebrochenen Lauf unter `--nach` in Phase 2
      fortsetzen, im selben Durchgang (`Worker.Jack.Referenz.fortsetzen/1`);
      Modell, Effort und Beispiele wie beim abgebrochenen Lauf.
    * `--bis-fertig` — wie `--fortsetzen`, aber nach jedem Abbruch am
      Fünf-Stunden-Fenster bis zum Reset warten und wieder fortsetzen
      (`Worker.Jack.Referenz.bis_fertig/1`), höchstens `--max-teile` Teile
      (Default 12).

  **Schickt den Mitschnitt an Anthropic** und verbraucht Kontingent des
  Max-Abos (Tom, 11.09.2026: S3 darf zu Anthropic, Max-Abo). Ob ein Lauf
  starten darf, entscheidet Tom — der Task fragt nicht.
  """

  use Mix.Task

  alias Worker.Jack.{Abzug, Demo, Messlauf, Referenz, Sicht}

  @aufruf "Aufruf: mix lore.jack.referenz (--daten <dir> --namen <datei> | --demo) --auftraege <dir> " <>
            "[--nach <dir>] [--beispiele <datei>] [--port p] [--ohne-sicht] [--modell m] " <>
            "[--effort e] [--max-min n]"

  @impl Mix.Task
  def run(args) do
    opts = optionen!(args)
    # Der MCP-Server kompiliert nicht selbst (stdout gehört dem Protokoll).
    Mix.Task.run("compile")
    {:ok, _} = Application.ensure_all_started(:jason)

    claude =
      System.find_executable("claude") ||
        Mix.raise("claude (Claude Code) ist nicht im PATH.")

    {eingabe, mcp_eingabe, beilagen} = eingabe!(opts)

    auftraege =
      case Messlauf.auftraege(opts[:auftraege]) do
        {:ok, a} -> a
        {:error, grund} -> Mix.raise("Aufträge: #{inspect(grund)}")
      end

    fortsetzen? = opts[:fortsetzen] || opts[:bis_fertig]
    nach = if fortsetzen?, do: bestehend!(opts[:nach]), else: ziel!(opts[:nach])
    sicht(opts, nach)

    Mix.shell().info(
      "Referenzlauf #{if fortsetzen?, do: "FORTSETZUNG ", else: ""}nach #{nach}: " <>
        "#{length(eingabe.bloecke)} Blöcke, Modell " <>
        "#{opts[:modell] || "claude-fable-5-1"}, Effort #{opts[:effort] || "max"}" <>
        if(opts[:demo], do: ", DEMO-Daten.", else: ".")
    )

    lauf =
      cond do
        opts[:bis_fertig] -> &Referenz.bis_fertig/1
        opts[:fortsetzen] -> &Referenz.fortsetzen/1
        true -> &Referenz.laufen/1
      end

    ergebnis =
      lauf.(
        eingabe: eingabe,
        mcp_eingabe: mcp_eingabe,
        auftraege: auftraege,
        nach: nach,
        modell: opts[:modell] || "claude-fable-5-1",
        effort: opts[:effort] || "max",
        beispiele: opts[:beispiele] && Path.expand(opts[:beispiele]),
        claude: claude,
        worker_dir: File.cwd!(),
        max_ms: Keyword.get(opts, :max_min, 360) * 60_000,
        beilagen: beilagen,
        max_teile: Keyword.get(opts, :max_teile, 12),
        melden: &melden/1
      )

    case ergebnis do
      {:error, grund} ->
        Mix.raise("Fortsetzen geht nicht: #{inspect(grund)}")

      {:aufgehoert, grund} ->
        Mix.shell().info("Referenzlauf aufgehört: #{inspect(grund)} — #{nach}/messlauf.json")

      {:fertig, e} ->
        beendet(e, nach)

      %{} ->
        beendet(ergebnis, nach)
    end
  end

  defp beendet(e, nach),
    do:
      Mix.shell().info(
        "Referenzlauf beendet: #{e["ende"]}, #{e["bestand"]} Aussagen — #{nach}/messlauf.json"
      )

  defp melden({:phase, nr, dir}), do: Mix.shell().info("Phase #{nr} beginnt → #{dir}")

  # Ortszeit des Rechners; der Worker kennt keine Zeitzonen-Datenbank.
  defp melden({:warten, bis}) do
    {{_j, mo, t}, {h, mi, _s}} = :calendar.system_time_to_local_time(bis, :second)

    uhr =
      :io_lib.format("~2..0B.~2..0B. ~2..0B:~2..0B", [t, mo, h, mi]) |> IO.iodata_to_binary()

    Mix.shell().info("Warte bis #{uhr} (Nutzungsgrenze)")
  end

  defp bestehend!(nil), do: Mix.raise("--fortsetzen braucht --nach <verzeichnis des Laufs>.")

  defp bestehend!(pfad) do
    pfad = Path.expand(pfad)

    unless File.exists?(Path.join(pfad, "messlauf.json")),
      do: Mix.raise("#{pfad}/messlauf.json fehlt — kein Lauf zum Fortsetzen.")

    pfad
  end

  defp optionen!(args) do
    strict = [
      daten: :string,
      namen: :string,
      auftraege: :string,
      nach: :string,
      beispiele: :string,
      port: :integer,
      ohne_sicht: :boolean,
      modell: :string,
      effort: :string,
      max_min: :integer,
      demo: :boolean,
      fortsetzen: :boolean,
      bis_fertig: :boolean,
      max_teile: :integer
    ]

    case OptionParser.parse(args, strict: strict) do
      {opts, [], []} ->
        if opts[:auftraege] && (opts[:demo] || (opts[:daten] && opts[:namen])),
          do: opts,
          else: Mix.raise(@aufruf)

      _ ->
        Mix.raise(@aufruf)
    end
  end

  defp eingabe!(opts) do
    if opts[:demo] do
      {Demo.eingabe(), %{"eingabe" => "demo"}, []}
    else
      daten = Path.expand(opts[:daten])
      namen_pfad = Path.expand(opts[:namen])

      namen =
        case Abzug.namen_aus_text(File.read!(namen_pfad)) do
          {:ok, n} -> n
          {:error, grund} -> Mix.raise("Namensdatei: #{inspect(grund)}")
        end

      eingabe =
        case Abzug.spike_laden(daten, namen) do
          {:ok, e} -> e
          {:error, grund} -> Mix.raise("Eingabe: #{inspect(grund)}")
        end

      beilagen = [
        {Path.join(daten, "bloecke.tsv"), "bloecke_mit_sprecher.tsv"},
        {Path.join(daten, "fakten_voll.tsv"), "fakten_voll.tsv"}
      ]

      {eingabe, %{"daten" => daten, "namen" => namen_pfad}, beilagen}
    end
  end

  defp ziel!(nil) do
    stempel = DateTime.utc_now() |> Calendar.strftime("%Y%m%d-%H%M%S")
    ziel!(Path.expand("~/.local/share/lore-jack/laeufe/ref-#{stempel}"))
  end

  defp ziel!(pfad) do
    pfad = Path.expand(pfad)
    if File.exists?(pfad), do: Mix.raise("#{pfad} gibt es schon — ein neues Verzeichnis nehmen.")
    File.mkdir_p!(pfad)
    File.chmod!(pfad, 0o700)
    pfad
  end

  defp sicht(opts, nach) do
    unless opts[:ohne_sicht] do
      {:ok, _} = Application.ensure_all_started(:plug_cowboy)

      case Sicht.start_link(port: Keyword.get(opts, :port, 8097), folgen: nach) do
        {:ok, s} -> Mix.shell().info("Laufsicht: http://127.0.0.1:#{Sicht.port(s)}")
        {:error, grund} -> Mix.raise("Laufsicht startet nicht: #{inspect(grund)}")
      end
    end
  end
end
