defmodule Mix.Tasks.Lore.Backup do
  @moduledoc """
  Backup the local Mnesia data directory into a single `.bup` file.

      mix lore.backup                                  # → backup-<ts>.bup im cwd
      mix lore.backup --out /path/to/file.bup
      LORE_MNESIA_DIR=/path/to/mnesia mix lore.backup  # zielt auf einen anderen Mnesia-Dir

  Uses Mnesia's built-in `:mnesia.backup/1`, which writes a consistent
  snapshot of all `disc_copies` tables in one atomic operation. The resulting
  `.bup` file is Mnesia's own binary format — restore it via `mix lore.restore`.

  ## Nur Worker-Mnesia

  Seit Issue #164 (Etappe 5c) ist der **Hub stateless** — keine Mnesia, kein
  Postgres, kein Backup nötig (Disaster-Recovery = `git pull` + Secrets +
  Re-Deploy). Diese Task betrifft daher ausschließlich **Worker-Mnesia**
  (`worker_*` tables): `LORE_MNESIA_DIR` auf z.B. `priv/mnesia/dev-worker/`
  zeigen lassen und aus `apps/worker/` laufen. **Der Worker-BEAM muss vorher
  gestoppt sein** — Mnesia locked das Verzeichnis.

  ## Restore

  `mix lore.restore --from <file.bup>` (see that task).
  """

  use Mix.Task

  @shortdoc "Backup the local Mnesia data dir to a .bup file"

  @impl Mix.Task
  def run(args) do
    {opts, _positional, _} =
      OptionParser.parse(args, switches: [out: :string], aliases: [o: :out])

    out = opts[:out] || default_filename()
    out_abs = Path.expand(out)

    point_mnesia_at_data_dir!()
    :ok = Shared.Mnesia.ensure_started!()

    dir = :mnesia.system_info(:directory) |> to_string()
    Mix.shell().info("Mnesia dir:  #{dir}")
    Mix.shell().info("Output:      #{out_abs}")

    # Wait for all disc tables to finish loading their replicas before
    # asking Mnesia to checkpoint them. Without this, fresh-after-start
    # backups fail with "Cannot prepare checkpoint (replica not available)".
    tables = :mnesia.system_info(:tables) -- [:schema]
    ensure_backupable!(tables, dir)

    :ok = :mnesia.wait_for_tables(tables, 10_000)

    case :mnesia.backup(String.to_charlist(out_abs)) do
      :ok ->
        Mix.shell().info(
          "Done. Tables backed up (#{length(tables)}): #{Enum.map_join(tables, ", ", &Atom.to_string/1)}"
        )

        Mix.shell().info("Size: #{format_size(File.stat!(out_abs).size)}")

      {:error, reason} ->
        Mix.raise("Mnesia backup failed: #{inspect(reason)}")
    end
  end

  @doc """
  Issue #995: 0 Tabellen ist KEIN gültiges Backup, sondern fast immer ein
  Konfigurationsfehler (LORE_MNESIA_DIR vergessen/vertippt → frischer, leerer
  Default-Pfad; oder versehentlich das Hub- statt Worker-Dir).

  `:mnesia.backup/1` schreibt darauf klaglos eine gültige, aber leere .bup-Datei
  — mit derselben grünen "Done"-Meldung wie ein echtes Backup. Der Fehlschlag
  fällt dann erst im DR-Fall auf, wenn es zu spät ist. Fail-loud statt still:
  lieber ein abgebrochener Lauf als ein Backup, das nur so aussieht.
  """
  @spec ensure_backupable!([atom()], String.t()) :: :ok
  def ensure_backupable!([], dir) do
    Mix.raise("""
    Keine Tabellen im Mnesia-Verzeichnis #{dir} — es gibt nichts zu sichern.

    Das ist fast immer ein Konfigurationsfehler. Prüfe LORE_MNESIA_DIR, z.B.:
      LORE_MNESIA_DIR=$(pwd)/priv/mnesia/prod-worker mix lore.backup

    Kein Backup geschrieben (eine leere .bup-Datei wäre gefährlicher als gar
    keine — sie sieht im DR-Fall wie ein gültiges Backup aus).
    """)
  end

  def ensure_backupable!(tables, _dir) when is_list(tables), do: :ok

  # Mix-Tasks bypass runtime.exs, so the `:mnesia, :dir` config never gets
  # set from LORE_MNESIA_DIR. We replicate that handshake here, stopping
  # Mnesia first if it's already running against the default location.
  defp point_mnesia_at_data_dir! do
    dir =
      System.get_env("LORE_MNESIA_DIR") ||
        Path.expand("priv/mnesia/#{Mix.env()}", File.cwd!())

    File.mkdir_p!(dir)

    if :mnesia.system_info(:is_running) == :yes do
      current = :mnesia.system_info(:directory) |> to_string()

      if Path.expand(current) != Path.expand(dir) do
        :stopped = :mnesia.stop()
      end
    end

    Application.put_env(:mnesia, :dir, String.to_charlist(dir))
    :ok
  end

  defp default_filename do
    ts =
      DateTime.utc_now()
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()
      |> String.replace(":", "-")

    "lore-backup-#{ts}.bup"
  end

  defp format_size(bytes) when bytes < 1_024, do: "#{bytes} B"
  defp format_size(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KiB"
  defp format_size(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MiB"
end
