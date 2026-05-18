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

  @spec put_user(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def put_user(conn, %{discord_id: _, display_name: _} = user) do
    put_session(conn, @session_user, user)
  end

  @spec current_user(Plug.Conn.t()) :: map() | nil
  def current_user(conn), do: get_session(conn, @session_user)

  @spec logout(Plug.Conn.t()) :: Plug.Conn.t()
  def logout(conn), do: delete_session(conn, @session_user)

  @spec put_return_to(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def put_return_to(conn, path), do: put_session(conn, @session_return_to, path)

  @spec take_return_to(Plug.Conn.t(), String.t()) :: {String.t(), Plug.Conn.t()}
  def take_return_to(conn, default) do
    case get_session(conn, @session_return_to) do
      nil -> {default, conn}
      path -> {path, delete_session(conn, @session_return_to)}
    end
  end

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
