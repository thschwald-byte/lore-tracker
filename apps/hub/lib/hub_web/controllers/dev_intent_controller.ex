defmodule HubWeb.DevIntentController do
  @moduledoc """
  Dev-only HTTP endpoint that lets external Mix tasks (e.g.
  `mix lore.fake_session`) inject events into `Hub.EventLog` without
  having to share a BEAM node or Mnesia schema.

  Only mounted on the `:dev_routes` scope (see Router).
  """

  use HubWeb, :controller

  def create(conn, %{"payload" => payload}) when is_map(payload) do
    {:ok, seq} = Hub.EventLog.append(payload, "dev")
    json(conn, %{ok: true, seq: seq})
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
