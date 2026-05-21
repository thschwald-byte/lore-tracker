defmodule Hub.Storage.CloudKeys.Postgres do
  @moduledoc """
  Postgres-backed Cloud-API-Key-Tabelle (Issue #27).

  Idempotent UPSERT auf `provider` als Primary Key. `encrypted_key` ist
  bereits AES-GCM-encrypted von `Hub.CloudKeys` bevor wir hier landen.
  """

  @behaviour Hub.Storage.CloudKeys

  import Ecto.Query
  alias Hub.Repo
  alias Hub.Schema.CloudKey

  @impl true
  def bootstrap!, do: :ok

  @impl true
  def put(provider, encrypted_key, created_by) do
    now = DateTime.utc_now()

    case Repo.get(CloudKey, provider) do
      nil ->
        {1, _} =
          Repo.insert_all(CloudKey, [
            %{
              provider: provider,
              encrypted_key: encrypted_key,
              created_at: now,
              updated_at: now,
              created_by_discord_id: created_by
            }
          ])

      %CloudKey{} ->
        {1, _} =
          Repo.update_all(
            from(c in CloudKey, where: c.provider == ^provider),
            set: [
              encrypted_key: encrypted_key,
              updated_at: now,
              created_by_discord_id: created_by
            ]
          )
    end

    :ok
  end

  @impl true
  def get(provider) do
    case Repo.get(CloudKey, provider) do
      nil ->
        :error

      %CloudKey{} = row ->
        {:ok,
         %{
           provider: row.provider,
           encrypted_key: row.encrypted_key,
           created_at: row.created_at,
           updated_at: row.updated_at,
           created_by_discord_id: row.created_by_discord_id
         }}
    end
  end

  @impl true
  def delete(provider) do
    Repo.delete_all(from(c in CloudKey, where: c.provider == ^provider))
    :ok
  end

  @impl true
  def list do
    Repo.all(from(c in CloudKey, order_by: c.provider))
    |> Enum.map(fn row ->
      %{
        provider: row.provider,
        encrypted_key: row.encrypted_key,
        created_at: row.created_at,
        updated_at: row.updated_at,
        created_by_discord_id: row.created_by_discord_id
      }
    end)
  end
end
