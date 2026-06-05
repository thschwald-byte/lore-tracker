defmodule Hub.AuthTest do
  @moduledoc """
  Issue #473 Cut 2: Open-Redirect-Guard in take_return_to (safe_local_path/2).
  Nur lokale Pfade dürfen als return_to durchgehen; protokoll-relative/externe
  URLs fallen auf den Default zurück.
  """

  use ExUnit.Case, async: true

  import Plug.Test
  alias Hub.Auth

  @user %{discord_id: "did-558-test", display_name: "Tester"}
  defp session_conn, do: conn(:get, "/") |> init_test_session(%{})

  describe "live_socket_id / Logout-Disconnect (#558)" do
    test "put_user setzt eine per-Session live_socket_id" do
      id = session_conn() |> Auth.put_user(@user) |> Plug.Conn.get_session(:live_socket_id)
      assert is_binary(id)
      assert String.starts_with?(id, "users_socket:")
    end

    test "zwei Logins → unterschiedliche IDs (per-Session, nicht per-User)" do
      id1 = session_conn() |> Auth.put_user(@user) |> Plug.Conn.get_session(:live_socket_id)
      id2 = session_conn() |> Auth.put_user(@user) |> Plug.Conn.get_session(:live_socket_id)
      assert id1 != id2
    end

    test "logout broadcastet disconnect auf die live_socket_id der Session" do
      conn = session_conn() |> Auth.put_user(@user)
      id = Plug.Conn.get_session(conn, :live_socket_id)

      HubWeb.Endpoint.subscribe(id)
      Auth.logout(conn)

      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: ^id}
    end

    test "logout ohne live_socket_id (Alt-Session) crasht nicht" do
      assert %Plug.Conn{} = Auth.logout(session_conn())
    end
  end

  test "lokaler Pfad bleibt erhalten" do
    assert Auth.safe_local_path("/campaigns/abc", "/") == "/campaigns/abc"
    assert Auth.safe_local_path("/invite/xyz?foo=1", "/") == "/invite/xyz?foo=1"
    assert Auth.safe_local_path("/", "/dash") == "/"
  end

  test "protokoll-relative URL (//host) → default" do
    assert Auth.safe_local_path("//evil.example.com", "/") == "/"
  end

  test "backslash-Trick (/\\host) → default" do
    assert Auth.safe_local_path("/\\evil.example.com", "/") == "/"
  end

  test "absolute externe URL / Nicht-Pfad → default" do
    assert Auth.safe_local_path("https://evil.example.com", "/") == "/"
    assert Auth.safe_local_path("evil", "/") == "/"
    assert Auth.safe_local_path(nil, "/dash") == "/dash"
  end
end
