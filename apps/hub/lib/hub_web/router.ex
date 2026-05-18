defmodule HubWeb.Router do
  use HubWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :put_root_layout, html: {HubWeb.Layouts, :root}
  end

  pipeline :require_user do
    plug Hub.Auth, :require_user
  end

  scope "/", HubWeb do
    pipe_through [:browser, :require_user]

    live "/", DashboardLive, :index
    live "/campaigns/:id", CampaignLive, :show
  end

  scope "/", HubWeb do
    pipe_through :browser

    get "/pair", PairController, :start
  end

  scope "/auth", HubWeb do
    pipe_through :browser

    delete "/logout", AuthController, :logout
    get "/logout", AuthController, :logout
    get "/:provider", AuthController, :request
    get "/:provider/callback", AuthController, :callback
  end
end
