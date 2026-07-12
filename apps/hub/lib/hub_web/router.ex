defmodule HubWeb.Router do
  use HubWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(:put_root_layout, html: {HubWeb.Layouts, :root})
  end

  pipeline :require_user do
    plug(Hub.Auth, :require_user)
  end

  # Issue #162 (Etappe 5b): kein /api-Scope mehr — Worker calls Cloud-LLMs
  # direkt via pro-Worker ANTHROPIC_API_KEY. Hub.LLMProxyController + cloud_keys
  # sind entfernt. (Issue #473: der frühere WorkerAuthPlug existiert nicht mehr
  # im Repo — Verweis entfernt; ein künftiger /api-Endpoint bräuchte ohnehin
  # eigene JWT-Auth via Hub.WorkerJWT.)

  scope "/", HubWeb do
    pipe_through([:browser, :require_user])

    # Issue #387: live_session-Wrap + on_mount HubWeb.SidebarContext lädt
    # die zuletzt besuchte Kampagne aus LocalStorage in `current_campaign`,
    # damit das Sidebar-Item „Kampagne: <name>" auf allen Pages klickbar
    # bleibt. Admin-Route-Auth bleibt unverändert: jede Admin-LV gating
    # server-seitig im mount/3 via `Permissions.can?(perm_user, :view_admin)`.
    live_session :default, on_mount: HubWeb.SidebarContext do
      live("/", DashboardLive, :index)
      live("/campaigns/:id", CampaignLive, :show)
      live("/settings", EinstellungenLive, :index)
      # Issue #510: Cloud-API-Keys pro Worker verwalten (Admin-only).
      live("/cloud-api", CloudApiLive, :index)
      live("/admin/users", AdminUsersLive, :index)
      live("/admin/probelauf", AdminProbelaufLive, :index)
      # Issue #177: Spend-Dashboard für Cloud-LLM-Calls.
      live("/admin/spend", AdminSpendLive, :index)
      # Issue #68 (Phase 1): strukturiertes Pipeline-Fehler-Log.
      live("/admin/errors", AdminErrorsLive, :index)
      # Issue #292 (Phase 1): GPU/CPU-Job-Queue Observability.
      live("/admin/jobs", AdminJobsLive, :index)
    end

    # Issue #144: Admin-Debug-Endpoint für LV-State-Impersonation.
    # Caller muss :admin sein, Target-User muss via Hub.DebugConsent grant
    # zugestimmt haben (in /settings auf der Target-Seite).
    get("/admin/debug/campaign/:id", DebugController, :campaign)
  end

  scope "/", HubWeb do
    pipe_through(:browser)

    get("/pair", PairController, :start)
    get("/invite/:token", InviteController, :show)
  end

  scope "/auth", HubWeb do
    pipe_through(:browser)

    delete("/logout", AuthController, :logout)
    get("/logout", AuthController, :logout)
    get("/:provider", AuthController, :request)
    get("/:provider/callback", AuthController, :callback)
  end

  if Mix.env() in [:dev, :test] do
    pipeline :dev_api do
      plug(:accepts, ["json"])
    end

    scope "/dev", HubWeb do
      pipe_through(:dev_api)
      post("/event", DevIntentController, :create)
      get("/active_session/:campaign_id", DevIntentController, :active_session)
      post("/settings", DevIntentController, :update_settings)
    end
  end
end
