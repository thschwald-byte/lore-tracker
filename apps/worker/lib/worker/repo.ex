defmodule Worker.Repo do
  @moduledoc """
  Thin Mnesia wrappers for the worker's tables. Only the operations needed
  by the current milestone live here; the materializer (M4) will own writes
  for the rest of the schema.

  All reads/writes use Mnesia transactions — single-record CRUD only, no
  joins. Materialized views are computed by the materializer, not here.
  """

  alias Worker.Schema.Mnesia, as: S

  # ─── worker_state ────────────────────────────────────────────────

  @doc "Fetch a value from the singleton worker_state bag."
  @spec get_state(atom()) :: term() | nil
  def get_state(key) when is_atom(key) do
    transaction(fn -> :mnesia.read(S.worker_state(), key) end)
    |> case do
      [{_, ^key, value}] -> value
      [] -> nil
    end
  end

  @doc "Set/overwrite a single key in worker_state."
  @spec put_state(atom(), term()) :: :ok
  def put_state(key, value) when is_atom(key) do
    transaction(fn -> :mnesia.write({S.worker_state(), key, value}) end)
    :ok
  end

  @doc "Atomically write many state keys at once."
  @spec put_state_many(map() | keyword()) :: :ok
  def put_state_many(map) do
    table = S.worker_state()

    transaction(fn ->
      Enum.each(map, fn {key, value} ->
        :mnesia.write({table, key, value})
      end)
    end)

    :ok
  end

  # ─── users ──────────────────────────────────────────────────────

  @doc "Upsert a known user (admin + invite-redeemed players)."
  @spec upsert_user(String.t(), String.t()) :: :ok
  def upsert_user(discord_id, display_name)
      when is_binary(discord_id) and is_binary(display_name) do
    transaction(fn ->
      joined_at =
        case :mnesia.read(S.users(), discord_id) do
          [{_, _, _, ts}] -> ts
          [] -> DateTime.utc_now()
        end

      :mnesia.write({S.users(), discord_id, display_name, joined_at})
    end)

    :ok
  end

  defp transaction(fun) do
    case :mnesia.transaction(fun) do
      {:atomic, result} -> result
      {:aborted, reason} -> raise "Mnesia transaction aborted: #{inspect(reason)}"
    end
  end
end
