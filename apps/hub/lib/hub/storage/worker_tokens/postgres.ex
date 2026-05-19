defmodule Hub.Storage.WorkerTokens.Postgres do
  @moduledoc """
  Postgres-backed pairing-token directory.
  """

  @behaviour Hub.Storage.WorkerTokens

  alias Hub.Repo
  alias Hub.Schema.WorkerToken

  @impl true
  def bootstrap!, do: :ok

  @impl true
  def issue(worker_id, admin_discord_id) do
    token = random_token()
    now = DateTime.utc_now()

    {1, _} =
      Repo.insert_all(WorkerToken, [
        %{
          token: token,
          worker_id: worker_id,
          admin_discord_id: admin_discord_id,
          issued_at: now,
          last_seen_at: now
        }
      ])

    token
  end

  @impl true
  def lookup(token) when is_binary(token) do
    case Repo.get(WorkerToken, token) do
      nil ->
        :error

      %WorkerToken{} = row ->
        {:ok,
         %{
           token: row.token,
           worker_id: row.worker_id,
           admin_discord_id: row.admin_discord_id,
           issued_at: row.issued_at,
           last_seen_at: row.last_seen_at
         }}
    end
  end

  defp random_token, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
