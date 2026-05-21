defmodule Mix.Tasks.Lore.Restore do
  @moduledoc """
  Restore the local Mnesia data directory from a `.bup` file produced by
  `mix lore.backup`.

      mix lore.restore --from /path/to/file.bup
      LORE_MNESIA_DIR=/path/to/mnesia mix lore.restore --from file.bup

  ## How it works

  Uses Mnesia's `:install_fallback/1` — the canonical disaster-recovery
  path. The backup file becomes the database's authoritative source for
  both schema and rows on the next Mnesia start.

  ## Caveats

  - **All BEAMs holding this Mnesia dir must be stopped first** — Mnesia
    locks the directory per node. If the worker is running, stop it before
    restoring.
  - **The target Mnesia dir is overwritten.** Schema + all tables from the
    backup replace whatever is currently in `LORE_MNESIA_DIR`. If you want
    to keep the old data, back it up first or restore into a different
    directory.
  - **Backup file is binary** in Mnesia's own format. Don't try to edit
    it manually; treat as an opaque blob.

  See `mix help lore.backup` for the companion command.
  """

  use Mix.Task

  @shortdoc "Restore the local Mnesia data dir from a .bup file"

  @impl Mix.Task
  def run(args) do
    {opts, _positional, _} =
      OptionParser.parse(args, switches: [from: :string], aliases: [f: :from])

    file =
      opts[:from] ||
        Mix.raise("--from <path> required. Example: mix lore.restore --from lore-backup.bup")

    file_abs = Path.expand(file)

    unless File.exists?(file_abs) do
      Mix.raise("Backup file not found: #{file_abs}")
    end

    point_mnesia_at_data_dir!()

    dir = Application.get_env(:mnesia, :dir) |> to_string()
    Mix.shell().info("Mnesia dir:  #{dir}")
    Mix.shell().info("Source:      #{file_abs}")

    # Start Mnesia briefly so install_fallback can stage the backup; then
    # stop + start to apply it. This is the documented Mnesia disaster-
    # recovery dance (see :mnesia.install_fallback/1).
    case :mnesia.system_info(:is_running) do
      :yes -> :ok
      _ -> :ok = :mnesia.start()
    end

    case :mnesia.install_fallback(String.to_charlist(file_abs)) do
      :ok ->
        :stopped = :mnesia.stop()
        :ok = :mnesia.start()
        tables = :mnesia.system_info(:tables) -- [:schema]
        :ok = :mnesia.wait_for_tables(tables, 30_000)

        Mix.shell().info(
          "Done. Tables restored (#{length(tables)}): #{Enum.map_join(tables, ", ", &Atom.to_string/1)}"
        )

      {:error, reason} ->
        Mix.raise("Mnesia restore failed: #{inspect(reason)}")
    end
  end

  # Same handshake as in Mix.Tasks.Lore.Backup — Mix-Tasks bypass
  # runtime.exs, so we set :mnesia, :dir manually from LORE_MNESIA_DIR.
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
end
