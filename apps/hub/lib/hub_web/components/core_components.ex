defmodule HubWeb.CoreComponents do
  @moduledoc """
  Shared LiveView components for the LoreTracker hub UI.

  Button-/Icon-/Avatar-/Chip-Primitives leben seit Issue #194 in
  `HubWeb.UIComponents` (Design System v0.1). Hier nur noch das Layout-
  Skelett (Sidebar, Logo, Flash, Modal, Info-Popover, Version-Footer).
  """
  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: HubWeb.Endpoint,
    router: HubWeb.Router,
    statics: HubWeb.static_paths()

  alias Phoenix.LiveView.JS

  # ─── Sidebar ─────────────────────────────────────────────────────

  attr(:current_user, :map, required: true)
  attr(:active, :atom, default: :dashboard)
  attr(:current_campaign, :map, default: nil)
  attr(:viewer_role, :atom, default: :spieler)
  attr(:current_user_role, :atom, default: :spieler)

  def sidebar(assigns) do
    # Admin-Nav-Items (Userverwaltung, Probelauf, Spend, Errors, Jobs) sind
    # globale System-Funktionen — koppeln an die globale Rolle, NICHT an
    # `viewer_role`. `viewer_role` ist überladen: auf den Admin-/Settings-
    # Pages ist es die globale Rolle, in CampaignLive die per-Campaign-Rolle.
    # Ein globaler Admin, der in einer Kampagne nur Spieler ist, hätte sonst
    # die Admin-Nav disabled wenn er in dieser Kampagne navigiert.
    #
    # `current_user_role` wird vom `HubWeb.SidebarContext`-on_mount-Hook
    # geladen (Worker-Snapshot), weil der Session-Cookie die Rolle nicht
    # enthält (siehe HubWeb.AuthController).
    admin? = assigns.current_user_role == :admin
    has_campaign? = not is_nil(assigns.current_campaign)
    has_worker? = has_own_worker?(assigns.current_user)

    debug_href =
      if has_campaign? and admin? do
        "/admin/debug/campaign/#{assigns.current_campaign["id"]}"
      else
        "#"
      end

    campaign_href =
      if has_campaign? do
        "/campaigns/#{assigns.current_campaign["id"]}"
      else
        "#"
      end

    assigns =
      assigns
      |> assign(:admin?, admin?)
      |> assign(:has_campaign?, has_campaign?)
      |> assign(:has_worker?, has_worker?)
      |> assign(:debug_href, debug_href)
      |> assign(:campaign_href, campaign_href)

    ~H"""
    <aside
      id="app-sidebar"
      class="shrink-0 bg-bg-1 border-r border-bg-3/60 flex flex-col overflow-hidden transition-all duration-200"
      data-collapsed="false"
      style="width: 14rem;"
    >
      <div class="px-3 pt-4 pb-3 flex items-center justify-between border-b border-bg-3/60">
        <div class="flex items-center gap-2 nav-label">
          <.logo class="w-8 h-8 shrink-0" />
          <div class="font-display text-accent text-xs tracking-widest">LORE TRACKER</div>
        </div>
        <button
          type="button"
          id="sidebar-toggle"
          phx-hook="SidebarToggle"
          class="text-ink-2 hover:text-accent shrink-0 p-1"
          title="Navigation ein-/ausklappen"
          aria-label="Sidebar einklappen"
        >
          <span class="hero-bars-3 w-5 h-5"></span>
        </button>
      </div>

      <nav class="px-2 mt-3 flex-1 space-y-1">
        <.nav_link href="/" label="Dashboard" icon="hero-home" active={@active == :dashboard} />

        <.nav_link
          href={@campaign_href}
          label={if @has_campaign?, do: @current_campaign["name"], else: "Kampagne"}
          icon="hero-book-open"
          active={@active == :campaign}
          disabled?={not @has_campaign?}
          disabled_title="Keine Kampagne ausgewählt"
        />

        <.nav_link
          href="/settings"
          label="Einstellungen"
          icon="hero-cog-6-tooth"
          active={@active == :settings}
          disabled?={not @admin? or not @has_worker?}
          disabled_title={
            cond do
              not @admin? -> "Einstellungen — nur Admins"
              not @has_worker? -> "Einstellungen für eigenen Worker — kein eigener Worker erreichbar"
              true -> nil
            end
          }
        />

        <.nav_link
          href="/cloud-api"
          label="Cloud API"
          icon="hero-key"
          active={@active == :cloud_api}
          disabled?={not @admin? or not @has_worker?}
          disabled_title={
            cond do
              not @admin? -> "Cloud-API — nur Admins"
              not @has_worker? -> "Cloud-API — kein eigener Worker erreichbar"
              true -> nil
            end
          }
        />

        <hr class="border-bg-3/60 my-2 nav-label" />

        <.nav_link
          href="/admin/users"
          label="Userverwaltung"
          icon="hero-user-group"
          active={@active == :admin_users}
          disabled?={not @admin?}
          disabled_title="Nur Admins"
        />

        <.nav_link
          href="/admin/probelauf"
          label="Probelauf"
          icon="hero-beaker"
          active={@active == :admin_probelauf}
          disabled?={not @admin?}
          disabled_title="Nur Admins"
        />

        <.nav_link
          href="/admin/spend"
          label="LLM-Spend"
          icon="hero-banknotes"
          active={@active == :admin_spend}
          disabled?={not @admin?}
          disabled_title="Nur Admins"
        />

        <.nav_link
          href="/admin/errors"
          label="Pipeline-Fehler"
          icon="hero-exclamation-triangle"
          active={@active == :admin_errors}
          disabled?={not @admin?}
          disabled_title="Nur Admins"
        />

        <.nav_link
          href="/admin/jobs"
          label="Jobs"
          icon="hero-queue-list"
          active={@active == :admin_jobs}
          disabled?={not @admin?}
          disabled_title="Nur Admins"
        />

        <.nav_link
          href={@debug_href}
          label="Debug"
          icon="hero-bug-ant"
          active={@active == :admin_debug}
          disabled?={not @admin? or not @has_campaign?}
          disabled_title={
            cond do
              not @admin? -> "Nur Admins"
              not @has_campaign? -> "Kampagne wählen"
              true -> nil
            end
          }
        />
      </nav>

      <div class="px-3 py-3 border-t border-bg-3/60 text-xs text-ink-2 nav-label">
        <div class="truncate">{@current_user.display_name}</div>
        <a href="/auth/logout" class="text-ink-2 hover:text-accent">Abmelden</a>
      </div>
    </aside>
    """
  end

  attr(:href, :string, required: true)
  attr(:label, :string, required: true)
  attr(:icon, :string, required: true)
  attr(:active, :boolean, default: false)
  attr(:disabled?, :boolean, default: false)
  attr(:disabled_title, :string, default: nil)

  def nav_link(%{disabled?: true} = assigns) do
    ~H"""
    <span
      class="nav-item nav-item-disabled"
      title={@disabled_title}
      aria-disabled="true"
    >
      <span class={[@icon, "w-5 h-5 shrink-0"]}></span>
      <span class="text-sm nav-label">{@label}</span>
    </span>
    """
  end

  def nav_link(assigns) do
    ~H"""
    <.link
      navigate={@href}
      class={["nav-item", @active && "nav-item-active"]}
    >
      <span class={[@icon, "w-5 h-5 shrink-0"]}></span>
      <span class="text-sm nav-label">{@label}</span>
    </.link>
    """
  end

  # Issue #268: checkt ob der aktuelle User mindestens einen eigenen
  # Worker connected hat (= admin_discord_id == current_user.discord_id).
  # Disabled die Sidebar-Einstellungen wenn nicht.
  defp has_own_worker?(%{discord_id: did}) when is_binary(did) do
    Hub.WorkerRegistry.list()
    |> Enum.any?(fn {_id, meta} -> Map.get(meta, :admin_discord_id) == did end)
  end

  defp has_own_worker?(_), do: false

  # ─── tab_header (Issue #270) ─────────────────────────────────────
  # Excel-Style horizontaler Tab-Reiter für CampaignLive-Top-Bar. Click
  # toggled — gleicher Tab nochmal = zu. LV verwaltet `:open_tab` exklusiv
  # (nur einer offen), Tab-Body wird vom Parent gerendert.

  attr(:tab_id, :string, required: true, doc: "wird als phx-value-tab beim Toggle gesendet")
  attr(:label, :string, required: true)
  attr(:icon, :string, default: nil, doc: "Heroicon-Klasse, z.B. \"hero-arrow-path\"")
  attr(:active?, :boolean, default: false)

  def tab_header(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="toggle_tab"
      phx-value-tab={@tab_id}
      role="tab"
      aria-selected={"#{@active?}"}
      class={[
        "flex items-center gap-2 px-4 py-2 text-sm border-b-2 -mb-px transition-colors whitespace-nowrap",
        if(@active?,
          do: "border-accent text-fg bg-bg-2/40",
          else: "border-transparent text-fg-muted hover:text-fg hover:border-bg-3"
        )
      ]}
    >
      <span :if={@icon} class={[@icon, "w-4 h-4"]}></span>
      {@label}
    </button>
    """
  end

  # ─── Logo ────────────────────────────────────────────────────────

  attr(:class, :string, default: "")

  def logo(assigns) do
    ~H"""
    <svg viewBox="0 0 64 64" fill="none" xmlns="http://www.w3.org/2000/svg" class={@class}>
      <defs>
        <radialGradient id="glow" cx="50%" cy="50%" r="50%">
          <stop offset="0%" stop-color="#3fc7d3" stop-opacity="0.8" />
          <stop offset="100%" stop-color="#3fc7d3" stop-opacity="0" />
        </radialGradient>
      </defs>
      <circle cx="32" cy="32" r="28" fill="url(#glow)" />
      <polygon
        points="32,10 52,22 52,42 32,54 12,42 12,22"
        stroke="#3fc7d3"
        stroke-width="2.5"
        fill="#11172a"
      />
      <text
        x="32"
        y="38"
        text-anchor="middle"
        fill="#7cdde5"
        font-family="Cinzel, serif"
        font-weight="600"
        font-size="14"
      >
        20
      </text>
    </svg>
    """
  end

  # ─── Flash ───────────────────────────────────────────────────────

  attr(:flash, :map, required: true)

  def flash_group(assigns) do
    ~H"""
    <div class="fixed top-4 right-4 z-50 space-y-2">
      <%= if msg = Phoenix.Flash.get(@flash, :info) do %>
        <.flash kind={:info} msg={msg} />
      <% end %>
      <%= if msg = Phoenix.Flash.get(@flash, :error) do %>
        <.flash kind={:error} msg={msg} />
      <% end %>
    </div>
    """
  end

  attr(:kind, :atom, required: true)
  attr(:msg, :string, required: true)

  # Issue #448: jeder Toast ist wegklickbar — Klick irgendwo auf den Toast (inkl.
  # ×) feuert lv:clear-flash für diesen Key (LiveView leert den Flash + re-rendert)
  # plus sofortiges JS.hide fürs unmittelbare Feedback. Gilt für info wie error.
  def flash(assigns) do
    ~H"""
    <div
      id={"flash-#{@kind}"}
      role="alert"
      title="Klicken zum Schließen"
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> JS.hide(to: "#flash-#{@kind}")}
      class={[
        "panel px-4 py-3 pr-8 max-w-sm relative cursor-pointer",
        @kind == :info && "border-accent/40 text-ink-0",
        @kind == :error && "border-rec/60 text-rec-soft"
      ]}
    >
      {@msg}
      <button
        type="button"
        aria-label="Schließen"
        class="absolute top-1.5 right-2 text-lg leading-none text-ink-2 hover:text-ink-0"
      >
        ×
      </button>
    </div>
    """
  end

  # ─── Modal ───────────────────────────────────────────────────────

  attr(:id, :string, required: true)
  attr(:show, :boolean, default: false)
  attr(:on_cancel, JS, default: %JS{})
  slot(:inner_block, required: true)

  def modal(assigns) do
    ~H"""
    <div
      id={@id}
      phx-mounted={@show && show_modal(@id)}
      phx-remove={hide_modal(@id)}
      class="hidden fixed inset-0 z-50 bg-bg-0/80 flex items-center justify-center p-4"
    >
      <div
        class="panel max-w-lg w-full p-6 shadow-glow"
        phx-click-away={JS.exec(@on_cancel, "phx-remove")}
        phx-window-keydown={JS.exec(@on_cancel, "phx-remove")}
        phx-key="escape"
      >
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  def show_modal(id), do: JS.remove_class("hidden", to: "##{id}")
  def hide_modal(id), do: JS.add_class("hidden", to: "##{id}")

  # ─── Info-Popover (Issue #41) ───────────────────────────────────────
  #
  # Klick aufs ⓘ-Icon öffnet einen Popover mit DAU-Erklärung. Mobil-
  # freundlich (kein Hover-only), Click außerhalb schließt. content
  # darf Newlines enthalten — wird mit whitespace-pre-wrap gerendert.
  #
  # Default-id ist md5(content) — explizit setzen wenn derselbe Text
  # mehrfach pro Seite vorkommt.

  attr(:content, :string, required: true)
  attr(:id, :string, default: nil)
  attr(:icon_class, :string, default: "w-3.5 h-3.5")
  attr(:placement, :string, default: "right", values: ~w(right left))

  def info_popover(assigns) do
    assigns =
      assign_new(assigns, :id, fn ->
        "info-pop-" <> Base.url_encode64(:crypto.hash(:md5, assigns.content), padding: false)
      end)

    ~H"""
    <span
      class="relative inline-block"
      id={"#{@id}-wrap"}
      phx-click-away={JS.add_class("hidden", to: "##{@id}")}
    >
      <button
        type="button"
        phx-click={JS.toggle(to: "##{@id}")}
        class="text-ink-2/60 hover:text-accent focus:text-accent focus:outline-none align-middle"
        aria-label="Mehr Informationen"
      >
        <span class={"hero-information-circle-mini #{@icon_class}"}></span>
      </button>
      <div
        id={@id}
        class={[
          "hidden absolute z-30 top-full mt-1 w-72 panel p-3 text-xs text-ink-0 whitespace-pre-wrap leading-relaxed shadow-glow normal-case tracking-normal",
          @placement == "right" && "left-0",
          @placement == "left" && "right-0"
        ]}
      >
        {@content}
      </div>
    </span>
    """
  end

  # ─── Version-Footer ─────────────────────────────────────────────

  @doc """
  Kleiner Footer-Pill unten rechts mit Hub-Version + Git-SHA. Wird in
  `app.html.heex` eingebunden, erscheint auf allen Logged-In-Seiten.
  Owner/Admin/Spieler-übergreifend sichtbar — die Version ist keine
  geheime Info.
  """
  def version_footer(assigns) do
    ~H"""
    <footer class="fixed bottom-2 right-3 text-[10px] text-ink-2/60 font-mono pointer-events-none select-none z-10">
      Hub {Hub.Version.display()}
    </footer>
    """
  end
end
