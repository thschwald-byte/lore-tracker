defmodule Hub.Auth do
  @moduledoc """
  Session-backed Discord login for the Hub web UI.

  - `put_user/2` / `current_user/1` / `logout/1`: session helpers.
  - `require_user/2` (Plug): bounces unauthenticated requests to Discord
    OAuth, remembering the original path so we can land back on it.

  Pair flow keys (`:pair_*`) live in `Hub.Pairing` and never collide with
  the `:current_user` / `:return_to` keys used here.
  """

  @behaviour Plug

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, :require_user), do: require_user(conn, [])
  def call(conn, _), do: conn

  @session_user :current_user
  @session_return_to :return_to
  # Issue #558: per-Session-Random-ID für erzwungenes LiveView-Disconnect beim
  # Logout. Der Key `:live_socket_id` ist die Phoenix-Konvention — LiveView
  # liest ihn beim Connect und nutzt ihn als Socket-ID, sodass ein
  # `Endpoint.broadcast(id, "disconnect", …)` genau die Sockets DIESER Session
  # killt (kein Cross-Device-Flicker, anders als eine per-User-ID).
  @session_live_socket_id :live_socket_id

  @spec put_user(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def put_user(conn, %{discord_id: _, display_name: _} = user) do
    conn
    |> put_session(@session_user, user)
    |> put_session(@session_live_socket_id, "users_socket:" <> random_socket_token())
  end

  defp random_socket_token, do: Base.url_encode64(:crypto.strong_rand_bytes(16))

  @spec current_user(Plug.Conn.t()) :: map() | nil
  def current_user(conn), do: get_session(conn, @session_user)

  # Issue #358: die GANZE Session droppen, nicht nur den :current_user-Key —
  # `configure_session(drop: true)` invalidiert das komplette Session-Cookie
  # (auch return_to / etwaige pair_*-Reste), sauberer als ein selektives
  # delete_session.
  #
  # Issue #558: aktive LiveView-Sockets, die VOR dem Logout connected wurden
  # (z.B. offener Zweit-Tab), leben sonst bis zum nächsten Reconnect weiter —
  # die HTTP-Session ist weg, der LV-Prozess merkt es erst beim Re-Mount.
  # `Endpoint.broadcast(live_socket_id, "disconnect", …)` killt sie sofort; der
  # Tab reconnectet, findet das Cookie gedroppt → re-mountet unauth → Login.
  @spec logout(Plug.Conn.t()) :: Plug.Conn.t()
  def logout(conn) do
    if id = get_session(conn, @session_live_socket_id) do
      HubWeb.Endpoint.broadcast(id, "disconnect", %{})
    end

    conn
    |> clear_session()
    |> configure_session(drop: true)
  end

  @spec put_return_to(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def put_return_to(conn, path), do: put_session(conn, @session_return_to, path)

  @spec take_return_to(Plug.Conn.t(), String.t()) :: {String.t(), Plug.Conn.t()}
  def take_return_to(conn, default) do
    case get_session(conn, @session_return_to) do
      nil -> {default, conn}
      path -> {safe_local_path(path, default), delete_session(conn, @session_return_to)}
    end
  end

  # Issue #473: Open-Redirect-Guard (defense-in-depth). Nur lokale Pfade —
  # führendes "/", aber NICHT "//"/"/\" (protokoll-relativ → extern). Aktuell
  # landen hier nur interne request_path/invite-Pfade, aber der Guard verhindert,
  # dass eine künftige user-kontrollierte Quelle zur offenen Weiterleitung wird.
  @doc false
  def safe_local_path(path, default) when is_binary(path) do
    if String.starts_with?(path, "/") and not String.starts_with?(path, "//") and
         not String.starts_with?(path, "/\\") do
      path
    else
      default
    end
  end

  def safe_local_path(_path, default), do: default

  @doc """
  Plug: if there's no current_user in the session, store the request path
  as `return_to` and redirect to Discord OAuth.
  """
  @spec require_user(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def require_user(conn, _opts) do
    case current_user(conn) do
      nil ->
        conn
        |> put_return_to(request_path(conn))
        |> redirect(to: "/auth/discord")
        |> halt()

      _user ->
        conn
    end
  end

  defp request_path(%Plug.Conn{request_path: p, query_string: ""}), do: p
  defp request_path(%Plug.Conn{request_path: p, query_string: q}), do: p <> "?" <> q
end
