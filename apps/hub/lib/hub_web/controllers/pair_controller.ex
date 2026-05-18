defmodule HubWeb.PairController do
  use HubWeb, :controller

  alias Hub.Pairing

  def start(conn, params) do
    with {:ok, worker_id} <- Pairing.validate_worker_id(params["worker_id"]),
         {:ok, callback} <- Pairing.validate_callback(params["callback"]) do
      conn
      |> Pairing.put_pair_context(worker_id, callback, params["nonce"])
      |> redirect(to: "/auth/discord")
    else
      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> text("/pair rejected: #{reason}")
    end
  end
end
