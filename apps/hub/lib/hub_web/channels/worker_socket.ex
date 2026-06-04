defmodule HubWeb.WorkerSocket do
  @moduledoc """
  Phoenix.Socket entry point for `Worker.HubClient` (slipstream) connections.

  Authentication: connect params must include `token` and `worker_id`. Token
  ist ein JWT (Issue #160, Etappe 5a) signiert mit LORE_JWT_SECRET; wir
  verifizieren die Signatur via `Hub.WorkerJWT.verify/1` und prüfen, dass
  die in den Claims kodierte `worker_id` mit der vom Client geschickten
  übereinstimmt (sonst Connection-Mismatch).
  """

  use Phoenix.Socket

  require Logger

  channel("worker:*", HubWeb.WorkerChannel)

  @impl true
  def connect(%{"token" => token, "worker_id" => worker_id}, socket, _connect_info)
      when is_binary(token) and is_binary(worker_id) do
    case Hub.WorkerJWT.verify_token(token) do
      {:ok, %{"worker_id" => ^worker_id, "admin_discord_id" => admin_discord_id}} ->
        # Issue #360: das JWT selbst NICHT im Socket-State halten — es wird
        # nach connect/3 nirgends mehr gelesen (Channel-Authz hängt an
        # :worker_id/:admin_discord_id), und ein 1-Jahr gültiges Credential im
        # Socket-Assign ist unnötige Leak-Fläche (Crash-Dump/Observer/State-Dump).
        socket =
          socket
          |> assign(:worker_id, worker_id)
          |> assign(:admin_discord_id, admin_discord_id)

        {:ok, socket}

      {:ok, %{"worker_id" => claim_worker_id}} ->
        Logger.warning(
          "WorkerSocket: worker_id mismatch (claim=#{inspect(claim_worker_id)} client=#{inspect(worker_id)})"
        )

        :error

      {:error, reason} ->
        Logger.warning("WorkerSocket: token verify failed: #{inspect(reason)}")
        :error
    end
  end

  def connect(_, _, _), do: :error

  @impl true
  def id(%{assigns: %{worker_id: worker_id}}), do: "worker_socket:" <> worker_id
end
