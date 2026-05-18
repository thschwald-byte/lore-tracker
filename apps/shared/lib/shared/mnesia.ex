defmodule Shared.Mnesia do
  @moduledoc """
  Idempotent Mnesia bootstrap shared by Hub and Worker.

  Mnesia is a node-singleton; in dev both apps live in one BEAM and share a
  single data dir + schema, with their own table namespaces (`hub_*` vs
  `worker_*`). In prod they run on separate nodes with separate dirs.

  Configure `:mnesia, :dir` in your env config *before* OTP boots so mnesia
  auto-starts pointing at the right dir. Then call `ensure_disc_schema!/0`
  once during app startup to upgrade the in-memory schema to `disc_copies`,
  which is what makes `disc_copies` tables actually persist.
  """

  @doc """
  Idempotently make sure Mnesia is started and its schema lives on disk
  (in the configured `:mnesia, :dir`).
  """
  @spec ensure_started!() :: :ok
  def ensure_started! do
    dir = :mnesia.system_info(:directory) |> to_string()
    File.mkdir_p!(dir)

    if :mnesia.system_info(:is_running) != :yes do
      :ok = :mnesia.start()
    end

    case :mnesia.change_table_copy_type(:schema, node(), :disc_copies) do
      {:atomic, :ok} -> :ok
      {:aborted, {:already_exists, :schema, _node, :disc_copies}} -> :ok
    end

    :ok
  end

  @doc """
  Create a Mnesia table if it doesn't exist, then wait until it's loaded.

  Pass standard `:mnesia.create_table/2` options — typical caller wants
  `attributes:`, `disc_copies:`, optionally `type:` and `index:`.
  """
  @spec ensure_table!(atom(), keyword()) :: :ok
  def ensure_table!(name, opts) when is_atom(name) and is_list(opts) do
    opts = Keyword.put_new(opts, :disc_copies, [node()])

    case :mnesia.create_table(name, opts) do
      {:atomic, :ok} -> :ok
      {:aborted, {:already_exists, ^name}} -> :ok
    end

    :ok = :mnesia.wait_for_tables([name], 5_000)
  end
end
