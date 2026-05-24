defmodule HubWeb.DevIntentController do
  @moduledoc """
  Dev-only HTTP endpoint that lets external Mix tasks (e.g.
  `mix lore.fake_session`) inject events into the event-stream without
  having to share a BEAM node or Mnesia schema.

  Only mounted on the `:dev_routes` scope (see Router).

  Issue #154 (Etappe 4c.3): Delegiert via `Hub.EventBridge` an einen
  online Worker. Cold-Fail: 503, der Aufrufer (Mix-Task) muss seinen
  Worker starten.
  """

  use HubWeb, :controller

  def create(conn, %{"payload" => payload}) when is_map(payload) do
    case Hub.EventBridge.publish(payload) do
      :ok ->
        json(conn, %{ok: true, seq: nil})

      {:error, :no_worker_online} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{ok: false, error: "no_worker_online"})
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{ok: false, error: "missing payload"})
  end

  def active_session(conn, %{"campaign_id" => campaign_id}) do
    case Hub.Reader.read(%{"kind" => "active_session", "campaign_id" => campaign_id}) do
      {:ok, %{"session_id" => nil}} -> json(conn, %{error: "no_active_session"})
      {:ok, %{"session_id" => sid}} -> json(conn, %{session_id: sid})
      {:error, reason} -> json(conn, %{error: inspect(reason)})
    end
  end

  def update_settings(conn, %{"settings" => kv}) when is_map(kv) do
    n = Hub.Commands.update_all_worker_settings(kv)
    json(conn, %{ok: true, workers_signalled: n})
  end

  def update_settings(conn, _) do
    conn
    |> put_status(:bad_request)
    |> json(%{ok: false, error: "missing settings"})
  end
end
