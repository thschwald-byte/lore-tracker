defmodule Hub.Storage.CloudKeys do
  @moduledoc """
  Behaviour für die Cloud-API-Key-Tabelle (Issue #27).

  Schlüssel werden vor dem Speichern via `Hub.Vault.encrypt!/1` verschlüsselt
  und nie im EventLog persistiert. Eine Row pro Provider (`"anthropic"`,
  `"openai"`, …) — Instance-globale Keys, Admin-verwaltet.

  Zwei Adapter:
  - `Hub.Storage.CloudKeys.Mnesia` — default in dev (file-backed).
  - `Hub.Storage.CloudKeys.Postgres` — production-only, Gigalixir.

  Selected at runtime via `Application.get_env(:hub, :storage_backend)`.
  """

  @type row :: %{
          provider: String.t(),
          encrypted_key: binary(),
          created_at: DateTime.t(),
          updated_at: DateTime.t(),
          created_by_discord_id: String.t() | nil
        }

  @callback bootstrap!() :: :ok
  @callback put(provider :: String.t(), encrypted_key :: binary(), created_by :: String.t() | nil) ::
              :ok
  @callback get(provider :: String.t()) :: {:ok, row()} | :error
  @callback delete(provider :: String.t()) :: :ok
  @callback list() :: [row()]
end
