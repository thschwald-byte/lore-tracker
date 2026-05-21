defmodule Hub.Storage.WorkerTokens do
  @moduledoc """
  Behaviour for the pairing-token directory. Two adapters today:

  - `Hub.Storage.WorkerTokens.Mnesia` — default in dev (file-backed).
  - `Hub.Storage.WorkerTokens.Postgres` — production-only adapter for Gigalixir.

  Selected at runtime via `Application.get_env(:hub, :storage_backend)`.
  The public façade `Hub.WorkerTokens` dispatches here.
  """

  @type token_row :: %{
          token: String.t(),
          worker_id: String.t(),
          admin_discord_id: String.t(),
          issued_at: DateTime.t(),
          last_seen_at: DateTime.t(),
          last_seen_version: String.t() | nil,
          last_seen_sha: String.t() | nil,
          last_seen_protocol_version: integer() | nil
        }

  @callback bootstrap!() :: :ok
  @callback issue(worker_id :: String.t(), admin_discord_id :: String.t()) :: String.t()
  @callback lookup(token :: String.t()) :: {:ok, token_row()} | :error
  @callback record_join(token :: String.t(), payload :: map()) :: :ok | :error
end
