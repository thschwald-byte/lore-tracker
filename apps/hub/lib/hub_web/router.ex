defmodule HubWeb.Router do
  use HubWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
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
    live "/settings", EinstellungenLive, :index
    live "/admin/users", AdminUsersLive, :index
    live "/admin/probelauf", AdminProbelaufLive, :index
  end

  scope "/", HubWeb do
    pipe_through :browser

    get "/pair", PairController, :start
    get "/invite/:token", InviteController, :show
  end

  scope "/auth", HubWeb do
    pipe_through :browser

    delete "/logout", AuthController, :logout
    get "/logout", AuthController, :logout
    get "/:provider", AuthController, :request
    get "/:provider/callback", AuthController, :callback
  end

  if Mix.env() in [:dev, :test] do
    pipeline :dev_api do
      plug :accepts, ["json"]
    end

    scope "/dev", HubWeb do
      pipe_through :dev_api
      post "/event", DevIntentController, :create
      get "/active_session/:campaign_id", DevIntentController, :active_session
      post "/settings", DevIntentController, :update_settings
    end
  end
end
