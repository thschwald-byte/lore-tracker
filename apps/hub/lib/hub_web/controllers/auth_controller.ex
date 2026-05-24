defmodule HubWeb.AuthController do
  use HubWeb, :controller

  plug Ueberauth

  alias Hub.{Auth, EventBridge, Pairing, WorkerTokens}
  require Logger

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
    avatar_url = auth.info.image
    user = %{discord_id: discord_id, display_name: display_name, avatar_url: avatar_url}

    # Refresh the user record on every login so display_name + avatar_url
    # follow Discord changes. Idempotent — Materializer preserves joined_at
    # and only writes if anything actually differs in practice (any UserUpserted
    # event is cheap, the materializer-side write is a noop tuple-rewrite).
    #
    # Issue #154 (Etappe 4c.3): Event-Erzeugung via Worker-Bridge statt
    # EventLog.append. Cold-Fail: kein Worker online → Login klappt trotzdem,
    # Display-Name wird halt erst materialisiert wenn ein Worker hochkommt
    # (Hub-LV zeigt bis dahin "Warte auf Worker").
    case EventBridge.publish(%{
           "kind" => Shared.Events.user_upserted(),
           "discord_id" => discord_id,
           "display_name" => display_name,
           "avatar_url" => avatar_url
         }) do
      :ok ->
        :ok

      {:error, :no_worker_online} ->
        Logger.warning(
          "AuthController: UserUpserted nicht delegierbar (kein Worker online) — Login fortgesetzt, User-Record kommt beim nächsten Worker-Connect"
        )

        :ok
    end

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
