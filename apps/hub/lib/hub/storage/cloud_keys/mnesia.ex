defmodule Hub.Storage.CloudKeys.Mnesia do
  @moduledoc """
  Mnesia-backed Cloud-API-Key-Tabelle (Issue #27).

  Eine Row pro Provider, `:set`-Tabelle. `encrypted_key` ist bereits
  AES-GCM-encrypted via `Hub.Vault` — dieser Adapter sieht nur Bytes.
  """

  @behaviour Hub.Storage.CloudKeys

  @table :hub_cloud_keys
  @fields [:provider, :encrypted_key, :created_at, :updated_at, :created_by_discord_id]

  def table, do: @table

  @impl true
  def bootstrap! do
    Shared.Mnesia.ensure_table!(@table, attributes: @fields, type: :set)
    :ok
  end

  @impl true
  def put(provider, encrypted_key, created_by)
      when is_binary(provider) and is_binary(encrypted_key) do
    now = DateTime.utc_now()

    transaction(fn ->
      created_at =
        case :mnesia.read(@table, provider) do
          [{@table, _, _, created_at, _, _}] -> created_at
          [] -> now
        end

      :mnesia.write({@table, provider, encrypted_key, created_at, now, created_by})
    end)

    :ok
  end

  @impl true
  def get(provider) when is_binary(provider) do
    case transaction(fn -> :mnesia.read(@table, provider) end) do
      [{@table, ^provider, encrypted_key, created_at, updated_at, created_by}] ->
        {:ok,
         %{
           provider: provider,
           encrypted_key: encrypted_key,
           created_at: created_at,
           updated_at: updated_at,
           created_by_discord_id: created_by
         }}

      [] ->
        :error
    end
  end

  @impl true
  def delete(provider) when is_binary(provider) do
    transaction(fn -> :mnesia.delete({@table, provider}) end)
    :ok
  end

  @impl true
  def list do
    transaction(fn -> :mnesia.foldl(&[&1 | &2], [], @table) end)
    |> Enum.map(fn {@table, provider, encrypted_key, created_at, updated_at, created_by} ->
      %{
        provider: provider,
        encrypted_key: encrypted_key,
        created_at: created_at,
        updated_at: updated_at,
        created_by_discord_id: created_by
      }
    end)
    |> Enum.sort_by(& &1.provider)
  end

  defp transaction(fun) do
    case :mnesia.transaction(fun) do
      {:atomic, result} -> result
      {:aborted, reason} -> raise "Mnesia transaction aborted: #{inspect(reason)}"
    end
  end
end
