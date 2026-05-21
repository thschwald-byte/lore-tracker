defmodule HubWeb.AdminBackupController do
  @moduledoc """
  POST /admin/backup — live Mnesia-Snapshot des Hub-EventLogs als Download.

  Nur globale Rolle `:admin` (analog `AdminUsersLive`). Funktioniert ohne
  Hub-Restart, weil `:mnesia.backup/1` einen konsistenten Checkpoint auf
  den laufenden Tabellen schreibt.

  Auf einer Postgres-betriebenen Instance (z.B. Gigalixir-Prod) liefert
  der Endpoint 503 + Hinweis auf `gigalixir pg:backups` — Postgres-Dumps
  gehören nicht in einen Phoenix-Request.

  Restore: das herunter-geladene `.bup`-File via `mix lore.restore --from
  <file>` auf einer **gestoppten** Hub-BEAM einspielen. Siehe
  `docs/Backup-Recovery.md`.
  """

  use HubWeb, :controller

  alias Hub.Reader

  require Logger

  def create(conn, _params) do
    user = conn.assigns[:current_user]

    cond do
      is_nil(user) ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "login required"})

      not admin?(user) ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "admin role required"})

      true ->
        dispatch_backup(conn)
    end
  end

  defp admin?(user) do
    with {:ok, %{"users" => users}} when is_list(users) <- Reader.read(%{"kind" => "all_users"}) do
      Enum.any?(users, fn u ->
        u["discord_id"] == user.discord_id and u["role"] == "admin"
      end)
    else
      _ -> false
    end
  end

  defp dispatch_backup(conn) do
    case Application.get_env(:hub, :storage_backend, :mnesia) do
      :mnesia ->
        backup_mnesia(conn)

      :postgres ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{
          error: "postgres_backend",
          message:
            "This hub uses Postgres for storage. Use 'gigalixir pg:backups' (see docs/Backup-Recovery.md) instead — Postgres dumps should not stream through a Phoenix request."
        })

      other ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "unknown_storage_backend", value: inspect(other)})
    end
  end

  defp backup_mnesia(conn) do
    tmp_file =
      Path.join(
        System.tmp_dir!(),
        "hub-backup-#{:erlang.unique_integer([:positive])}.bup"
      )

    tables = :mnesia.system_info(:tables) -- [:schema]
    :ok = :mnesia.wait_for_tables(tables, 10_000)

    try do
      case :mnesia.backup(String.to_charlist(tmp_file)) do
        :ok ->
          ts =
            DateTime.utc_now()
            |> DateTime.truncate(:second)
            |> DateTime.to_iso8601()
            |> String.replace(":", "-")

          Logger.info("AdminBackup: live snapshot to #{tmp_file} (#{File.stat!(tmp_file).size} bytes, #{length(tables)} tables)")

          send_download(conn, {:file, tmp_file},
            filename: "hub-backup-#{ts}.bup",
            content_type: "application/octet-stream"
          )

        {:error, reason} ->
          Logger.error("AdminBackup: :mnesia.backup failed — #{inspect(reason)}")

          conn
          |> put_status(:internal_server_error)
          |> json(%{error: "mnesia_backup_failed", reason: inspect(reason)})
      end
    after
      File.rm(tmp_file)
    end
  end
end
