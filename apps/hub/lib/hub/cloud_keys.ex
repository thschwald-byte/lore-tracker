defmodule Hub.CloudKeys do
  @moduledoc """
  Public façade für Cloud-LLM-API-Keys (Issue #27).

  Keys werden via `Hub.Vault` AES-GCM-verschlüsselt bevor sie in die
  Storage-Tabelle wandern, und beim Lesen sofort dekriptiert. Nie im
  EventLog persistiert (event-sourced + replay-fähig → Klartext-Leakage).

  Provider-Strings sind klein-geschrieben (`"anthropic"`, `"openai"`,
  `"google"`). Eine Row pro Provider, Instance-global, Admin-verwaltet.
  """

  alias Hub.Vault

  @doc "Verschlüsselt und schreibt den Klartext-Key in die Storage."
  @spec put(String.t(), String.t(), String.t() | nil) :: :ok | {:error, term()}
  def put(provider, key, created_by_discord_id \\ nil)
      when is_binary(provider) and is_binary(key) do
    case Vault.encrypt(key) do
      {:ok, ciphertext} ->
        adapter().put(provider, ciphertext, created_by_discord_id)

      err ->
        err
    end
  end

  @doc "Liefert den Klartext-Key zurück oder `:error` wenn nichts hinterlegt ist."
  @spec get(String.t()) :: {:ok, String.t()} | :error
  def get(provider) when is_binary(provider) do
    case adapter().get(provider) do
      {:ok, %{encrypted_key: ciphertext}} ->
        case Vault.decrypt(ciphertext) do
          {:ok, plaintext} -> {:ok, plaintext}
          _ -> :error
        end

      :error ->
        :error
    end
  end

  @doc "Meta-Info ohne den Key (für UI). `created_at`/`updated_at`/`by`."
  @spec info(String.t()) :: {:ok, map()} | :error
  def info(provider) when is_binary(provider) do
    case adapter().get(provider) do
      {:ok, row} -> {:ok, Map.delete(row, :encrypted_key)}
      :error -> :error
    end
  end

  @doc "Liste aller konfigurierten Provider mit Meta (ohne Key) — fürs Admin-UI."
  @spec list_providers() :: [map()]
  def list_providers do
    adapter().list()
    |> Enum.map(&Map.delete(&1, :encrypted_key))
  end

  @doc "Löscht den Key zu einem Provider."
  @spec delete(String.t()) :: :ok
  def delete(provider) when is_binary(provider), do: adapter().delete(provider)

  @doc "True wenn ein Key zu diesem Provider gespeichert ist."
  @spec configured?(String.t()) :: boolean()
  def configured?(provider) when is_binary(provider) do
    case adapter().get(provider) do
      {:ok, _} -> true
      :error -> false
    end
  end

  @doc """
  Probe-Call: prüft ob der gespeicherte Key für `provider` tatsächlich
  funktioniert. Für Anthropic: kleiner `/v1/messages`-Call mit dem
  billigsten Modell + 1 Token Output. Liefert `:ok | {:error, reason}`.
  """
  @spec test_connection(String.t()) :: :ok | {:error, term()}
  def test_connection("anthropic") do
    with {:ok, key} <- get("anthropic"),
         {:ok, %{status: 200}} <-
           Req.post("https://api.anthropic.com/v1/messages",
             json: %{
               model: "claude-haiku-4-5-20251001",
               max_tokens: 1,
               messages: [%{role: "user", content: "ping"}]
             },
             headers: [
               {"x-api-key", key},
               {"anthropic-version", "2023-06-01"},
               {"content-type", "application/json"}
             ],
             receive_timeout: 30_000,
             retry: false
           ) do
      :ok
    else
      :error -> {:error, :no_key_configured}
      {:ok, %{status: status, body: body}} -> {:error, {:upstream, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  def test_connection(provider), do: {:error, {:unknown_provider, provider}}

  @doc false
  def bootstrap!, do: adapter().bootstrap!()

  defp adapter do
    case Application.get_env(:hub, :storage_backend, :mnesia) do
      :mnesia -> Hub.Storage.CloudKeys.Mnesia
      :postgres -> Hub.Storage.CloudKeys.Postgres
      other -> raise "Unknown :hub :storage_backend #{inspect(other)}"
    end
  end
end
