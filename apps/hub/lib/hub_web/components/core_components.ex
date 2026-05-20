defmodule HubWeb.CoreComponents do
  @moduledoc """
  Shared LiveView components for the LoreTracker hub UI.
  """
  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: HubWeb.Endpoint,
    router: HubWeb.Router,
    statics: HubWeb.static_paths()

  alias Phoenix.LiveView.JS

  # ─── Sidebar ─────────────────────────────────────────────────────

  attr :current_user, :map, required: true
  attr :active, :atom, default: :dashboard
  attr :current_campaign, :map, default: nil
  attr :viewer_role, :atom, default: :spieler

  def sidebar(assigns) do
    ~H"""
    <aside class="w-56 shrink-0 bg-bg-1 border-r border-bg-3/60 flex flex-col">
      <div class="px-4 pt-6 pb-4 flex flex-col items-center text-center">
        <.logo class="w-14 h-14 mb-2" />
        <div class="font-display text-accent text-sm tracking-widest">LORE TRACKER</div>
      </div>

      <nav class="px-2 mt-4 flex-1 space-y-1">
        <.nav_link href={~p"/"} label="Dashboard" icon="hero-home" active={@active == :dashboard} />
        <%= if @current_campaign do %>
          <.nav_link
            href={~p"/campaigns/#{@current_campaign["id"]}"}
            label={@current_campaign["name"]}
            icon="hero-book-open"
            active={@active == :campaign}
          />
        <% end %>
        <%= if @viewer_role == :admin do %>
          <.nav_link
            href={~p"/admin/users"}
            label="User-Verwaltung"
            icon="hero-user-group"
            active={@active == :admin}
          />
        <% end %>
        <.nav_link
          href={~p"/settings"}
          label="Einstellungen"
          icon="hero-cog-6-tooth"
          active={@active == :settings}
        />
      </nav>

      <div class="px-4 py-4 border-t border-bg-3/60 text-xs text-ink-2">
        <div class="truncate">{@current_user.display_name}</div>
        <a href={~p"/auth/logout"} class="text-ink-2 hover:text-accent">Abmelden</a>
      </div>
    </aside>
    """
  end

  attr :href, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :active, :boolean, default: false

  def nav_link(assigns) do
    ~H"""
    <.link
      navigate={@href}
      class={["nav-item", @active && "nav-item-active"]}
    >
      <span class={[@icon, "w-5 h-5"]}></span>
      <span class="text-sm">{@label}</span>
    </.link>
    """
  end

  # ─── Logo ────────────────────────────────────────────────────────

  attr :class, :string, default: ""

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

  attr :flash, :map, required: true

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

  attr :kind, :atom, required: true
  attr :msg, :string, required: true

  def flash(assigns) do
    ~H"""
    <div class={[
      "panel px-4 py-3 max-w-sm",
      @kind == :info && "border-accent/40 text-ink-0",
      @kind == :error && "border-rec/60 text-rec-soft"
    ]}>
      {@msg}
    </div>
    """
  end

  # ─── Modal ───────────────────────────────────────────────────────

  attr :id, :string, required: true
  attr :show, :boolean, default: false
  attr :on_cancel, JS, default: %JS{}
  slot :inner_block, required: true

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
end
