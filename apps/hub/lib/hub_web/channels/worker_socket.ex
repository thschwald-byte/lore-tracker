defmodule HubWeb.WorkerSocket do
  @moduledoc """
  Phoenix.Socket entry point for `Worker.HubClient` (slipstream) connections.

  Authentication: connect params must include `token` and `worker_id`. We
  look the token up in `Hub.WorkerTokens` and reject the connection if it
  doesn't match (worker_id mismatch is treated the same as missing).
  """

  use Phoenix.Socket

  channel "worker:*", HubWeb.WorkerChannel

  @impl true
  def connect(%{"token" => token, "worker_id" => worker_id}, socket, _connect_info)
      when is_binary(token) and is_binary(worker_id) do
    case Hub.WorkerTokens.lookup(token) do
      {:ok, %{worker_id: ^worker_id, admin_discord_id: admin_discord_id}} ->
        socket =
          socket
          |> assign(:worker_id, worker_id)
          |> assign(:admin_discord_id, admin_discord_id)
          |> assign(:token, token)

        {:ok, socket}

      _ ->
        :error
    end
  end

  def connect(_, _, _), do: :error

  @impl true
  def id(%{assigns: %{worker_id: worker_id}}), do: "worker_socket:" <> worker_id
end
