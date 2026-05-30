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

  # Issue #162 (Etappe 5b): kein /api-Scope mehr — Worker calls Cloud-LLMs
  # direkt via pro-Worker ANTHROPIC_API_KEY. Hub.LLMProxyController + cloud_keys
  # sind entfernt. WorkerAuthPlug verbleibt im Repo nur falls künftig ein
  # /api-Endpoint dazukommt (z.B. Backup-Download). Aktuell ungenutzt.

  scope "/", HubWeb do
    pipe_through [:browser, :require_user]

    live "/", DashboardLive, :index
    live "/campaigns/:id", CampaignLive, :show
    live "/settings", EinstellungenLive, :index
    live "/admin/users", AdminUsersLive, :index
    live "/admin/probelauf", AdminProbelaufLive, :index
    # Issue #177: Spend-Dashboard für Cloud-LLM-Calls.
    live "/admin/spend", AdminSpendLive, :index
    # Issue #68 (Phase 1): strukturiertes Pipeline-Fehler-Log.
    live "/admin/errors", AdminErrorsLive, :index

    # Issue #144: Admin-Debug-Endpoint für LV-State-Impersonation.
    # Caller muss :admin sein, Target-User muss via Hub.DebugConsent grant
    # zugestimmt haben (in /settings auf der Target-Seite).
    get "/admin/debug/campaign/:id", DebugController, :campaign
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
