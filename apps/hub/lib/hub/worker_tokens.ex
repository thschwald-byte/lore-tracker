defmodule Hub.WorkerTokens do
  @moduledoc """
  Persisted directory of issued worker-pairing tokens.

  One record per (token, worker_id) pair. Tokens are minted in `Hub.Pairing`
  after a successful Discord OAuth round-trip; consumed by `Hub.WorkerSocket`
  (M3) to authenticate channel connections.
  """

  @table :hub_worker_tokens
  @fields [:token, :worker_id, :admin_discord_id, :issued_at, :last_seen_at]

  def table, do: @table

  def bootstrap! do
    Shared.Mnesia.ensure_table!(@table,
      attributes: @fields,
      type: :set,
      index: [:worker_id]
    )
  end

  @doc """
  Mint and persist a token bound to (worker_id, admin_discord_id).
  Returns the random base64-url token string.
  """
  @spec issue(String.t(), String.t()) :: String.t()
  def issue(worker_id, admin_discord_id)
      when is_binary(worker_id) and is_binary(admin_discord_id) do
    token = random_token()
    now = DateTime.utc_now()

    :ok =
      transaction(fn ->
        :mnesia.write({@table, token, worker_id, admin_discord_id, now, now})
      end)

    token
  end

  @doc """
  Look up a token. Returns `{:ok, map}` or `:error`.
  """
  @spec lookup(String.t()) :: {:ok, map()} | :error
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
