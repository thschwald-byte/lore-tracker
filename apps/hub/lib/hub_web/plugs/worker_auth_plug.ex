defmodule HubWeb.WorkerAuthPlug do
  @moduledoc """
  Bearer-Token-Auth für `/api/*`-Endpoints (Issue #27).

  Liest `Authorization: Bearer <worker_token>` Header, sucht den Token via
  `Hub.WorkerTokens.lookup/1`. Bei Erfolg landet `worker_id` +
  `admin_discord_id` in `conn.assigns.worker`. Bei Misserfolg sofort 401.

  Side-channel-Notiz: gleiche Token-Lookup-Mechanik wie `HubWeb.WorkerSocket`
  — keine zusätzliche Angriffsfläche.
  """

  import Plug.Conn

  alias Hub.WorkerTokens

  def init(opts), do: opts

  def call(conn, _opts) do
    with [bearer | _] <- get_req_header(conn, "authorization"),
         "Bearer " <> token <- bearer,
         {:ok, %{worker_id: worker_id, admin_discord_id: admin}} <- WorkerTokens.lookup(token) do
      assign(conn, :worker, %{worker_id: worker_id, admin_discord_id: admin})
    else
      _ ->
        conn
        |> put_status(:unauthorized)
        |> Phoenix.Controller.json(%{error: "unauthorized"})
        |> halt()
    end
  end
end
