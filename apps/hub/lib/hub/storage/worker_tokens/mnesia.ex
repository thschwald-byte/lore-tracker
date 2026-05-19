defmodule Hub.Storage.WorkerTokens.Mnesia do
  @moduledoc """
  Mnesia-backed pairing-token directory.
  """

  @behaviour Hub.Storage.WorkerTokens

  @table :hub_worker_tokens
  @fields [:token, :worker_id, :admin_discord_id, :issued_at, :last_seen_at]

  def table, do: @table

  @impl true
  def bootstrap! do
    Shared.Mnesia.ensure_table!(@table,
      attributes: @fields,
      type: :set,
      index: [:worker_id]
    )
  end

  @impl true
  def issue(worker_id, admin_discord_id) do
    token = random_token()
    now = DateTime.utc_now()

    :ok =
      transaction(fn ->
        :mnesia.write({@table, token, worker_id, admin_discord_id, now, now})
      end)

    token
  end

  @impl true
  def lookup(token) when is_binary(token) do
    case transaction(fn -> :mnesia.read(@table, token) end) do
      [{@table, ^token, worker_id, admin_discord_id, issued_at, last_seen_at}] ->
        {:ok,
         %{
           token: token,
           worker_id: worker_id,
           admin_discord_id: admin_discord_id,
           issued_at: issued_at,
           last_seen_at: last_seen_at
         }}

      [] ->
        :error
    end
  end

  defp transaction(fun) do
    case :mnesia.transaction(fun) do
      {:atomic, result} -> result
      {:aborted, reason} -> raise "Mnesia transaction aborted: #{inspect(reason)}"
    end
  end

  defp random_token, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
