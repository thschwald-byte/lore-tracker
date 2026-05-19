defmodule Hub.WorkerTokens do
  @moduledoc """
  Public façade for issued worker-pairing tokens.

  Tokens are minted in `Hub.Pairing` after a successful Discord OAuth
  round-trip; consumed by `HubWeb.WorkerSocket` to authenticate channel
  connections.

  Storage backend (Mnesia in dev, Postgres in prod) is selected at runtime
  via `Application.get_env(:hub, :storage_backend)`.
  """

  def bootstrap!, do: adapter().bootstrap!()

  @spec issue(String.t(), String.t()) :: String.t()
  def issue(worker_id, admin_discord_id)
      when is_binary(worker_id) and is_binary(admin_discord_id) do
    adapter().issue(worker_id, admin_discord_id)
  end

  @spec lookup(String.t()) :: {:ok, map()} | :error
  def lookup(token) when is_binary(token), do: adapter().lookup(token)

  defp adapter do
    case Application.get_env(:hub, :storage_backend, :mnesia) do
      :mnesia -> Hub.Storage.WorkerTokens.Mnesia
      :postgres -> Hub.Storage.WorkerTokens.Postgres
      other -> raise "Unknown :hub :storage_backend #{inspect(other)}"
    end
  end
end
