defmodule Hub.AuthLogoutTest do
  @moduledoc """
  Issue #358 (Audit Auth+Sessions): Logout muss die Session sauber
  invalidieren, nicht nur einen Key entfernen.
  """
  use HubWeb.ConnCase, async: true

  alias Hub.Auth

  test "logout invalidiert die Session (current_user weg)", %{conn: conn} do
    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Auth.put_user(%{discord_id: "did-1", display_name: "Tester"})

    assert Auth.current_user(conn) != nil

    conn = Auth.logout(conn)
    assert Auth.current_user(conn) == nil
  end

  test "logout droppt auch sonstigen Session-State (return_to)", %{conn: conn} do
    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Auth.put_user(%{discord_id: "did-1", display_name: "Tester"})
      |> Auth.put_return_to("/campaigns/x")

    conn = Auth.logout(conn)
    # Nach dem Logout ist nichts mehr in der Session lesbar.
    assert Plug.Conn.get_session(conn, :current_user) == nil
    assert Plug.Conn.get_session(conn, :return_to) == nil
  end
end
