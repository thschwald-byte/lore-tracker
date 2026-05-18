defmodule HubWeb.AuthController do
  use HubWeb, :controller

  plug Ueberauth

  alias Hub.{Auth, Pairing, WorkerTokens}

  def request(conn, _params) do
    # Ueberauth's request plug normally handles the redirect; if we end up
    # here, the provider didn't match.
    conn
    |> put_status(:bad_request)
    |> text("Unknown auth provider")
  end

  def callback(%{assigns: %{ueberauth_failure: failure}} = conn, _params) do
    conn
    |> put_status(:unauthorized)
    |> text("OAuth-Fehler: #{inspect(failure.errors)}")
  end

  def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _params) do
    discord_id = to_string(auth.uid)
    display_name = auth.info.name || auth.info.nickname || "User #{discord_id}"
    user = %{discord_id: discord_id, display_name: display_name}

    case Pairing.take_pair_context(conn) do
      {:ok, %{worker_id: worker_id, callback: callback_url}, conn} ->
        token = WorkerTokens.issue(worker_id, discord_id)

        redirect_to =
          callback_url <>
            "?" <>
            URI.encode_query(
              token: token,
              discord_id: discord_id,
              display_name: display_name
            )

        redirect(conn, external: redirect_to)

      {:error, :no_pair_context, conn} ->
        {return_to, conn} = Auth.take_return_to(conn, "/")

        conn
        |> Auth.put_user(user)
        |> redirect(to: return_to)
    end
  end

  def logout(conn, _params) do
    conn
    |> Auth.logout()
    |> redirect(to: "/")
  end
end
