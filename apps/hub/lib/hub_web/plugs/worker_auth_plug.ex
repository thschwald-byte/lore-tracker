defmodule HubWeb.WorkerAuthPlug do
  @moduledoc """
  Bearer-Token-Auth für `/api/*`-Endpoints (Issue #27).

  Liest `Authorization: Bearer <jwt>` Header, verifiziert die Signatur via
  `Hub.WorkerJWT.verify/1` (Issue #160, Etappe 5a). Bei Erfolg landet
  `worker_id` + `admin_discord_id` aus den JWT-Claims in `conn.assigns.worker`.
  Bei Misserfolg sofort 401.

  Side-channel-Notiz: gleiche Verifikations-Mechanik wie `HubWeb.WorkerSocket`
  — keine zusätzliche Angriffsfläche.
  """

  import Plug.Conn

  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    with [bearer | _] <- get_req_header(conn, "authorization"),
         "Bearer " <> token <- bearer,
         {:ok, %{"worker_id" => worker_id, "admin_discord_id" => admin}} <-
           Hub.WorkerJWT.verify_token(token) do
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
