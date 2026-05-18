defmodule HubWeb.PageController do
  use HubWeb, :controller

  def home(conn, _params) do
    render(conn, :home, current_user: Hub.Auth.current_user(conn))
  end
end
