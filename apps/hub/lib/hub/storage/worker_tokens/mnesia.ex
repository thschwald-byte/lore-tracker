defmodule Hub.Storage.WorkerTokens.Mnesia do
  @moduledoc """
  Mnesia-backed pairing-token directory.
  """

  @behaviour Hub.Storage.WorkerTokens

  @table :hub_worker_tokens
  @fields [
    :token,
    :worker_id,
    :admin_discord_id,
    :issued_at,
    :last_seen_at,
    :last_seen_version,
    :last_seen_sha,
    :last_seen_protocol_version
  ]

  def table, do: @table

  @impl true
  def bootstrap! do
    Shared.Mnesia.ensure_table!(@table,
      attributes: @fields,
      type: :set,
      index: [:worker_id]
    )

    :ok = migrate_add_version_fields!()
    :ok
  end

  @impl true
  def issue(worker_id, admin_discord_id) do
    token = random_token()
    now = DateTime.utc_now()

    :ok =
      transaction(fn ->
        :mnesia.write({@table, token, worker_id, admin_discord_id, now, now, nil, nil, nil})
      end)

    token
  end

  @impl true
  def lookup(token) when is_binary(token) do
    case transaction(fn -> :mnesia.read(@table, token) end) do
      [
        {@table, ^token, worker_id, admin_discord_id, issued_at, last_seen_at, version, sha,
         protocol_version}
      ] ->
        {:ok,
         %{
           token: token,
           worker_id: worker_id,
           admin_discord_id: admin_discord_id,
           issued_at: issued_at,
           last_seen_at: last_seen_at,
           last_seen_version: version,
           last_seen_sha: sha,
           last_seen_protocol_version: protocol_version
         }}

      [] ->
        :error
    end
  end

  @impl true
  def record_join(token, payload) when is_binary(token) and is_map(payload) do
    now = DateTime.utc_now()
    version = payload["worker_version"]
    sha = payload["worker_sha"]
    protocol_version = payload["protocol_version"]

    transaction(fn ->
      case :mnesia.read(@table, token) do
        [{@table, ^token, worker_id, admin_discord_id, issued_at, _, _, _, _}] ->
          :mnesia.write(
            {@table, token, worker_id, admin_discord_id, issued_at, now, version, sha,
             protocol_version}
          )

          :ok

        [] ->
          :error
      end
    end)
  end

  # Idempotent migration: extend the 6-field row layout to 9 fields with
  # nil-defaults for `last_seen_version`, `last_seen_sha`,
  # `last_seen_protocol_version`. Field-in-Attrs check (#43-pattern)
  # short-circuits on already-migrated tables.
  defp migrate_add_version_fields! do
    current_attrs = :mnesia.table_info(@table, :attributes)

    if :last_seen_version in current_attrs do
      :ok
    else
      transform = fn {tbl, token, worker_id, admin_discord_id, issued_at, last_seen_at} ->
        {tbl, token, worker_id, admin_discord_id, issued_at, last_seen_at, nil, nil, nil}
      end

      {:atomic, :ok} = :mnesia.transform_table(@table, transform, @fields)
      :ok
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
