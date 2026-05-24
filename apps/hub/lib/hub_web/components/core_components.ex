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

  attr(:current_user, :map, required: true)
  attr(:active, :atom, default: :dashboard)
  attr(:current_campaign, :map, default: nil)
  attr(:viewer_role, :atom, default: :spieler)

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

  attr(:href, :string, required: true)
  attr(:label, :string, required: true)
  attr(:icon, :string, required: true)
  attr(:active, :boolean, default: false)

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

  @doc """
  Hex-frame icon button (cyber-noir aesthetic, Issue #116).

  Replaces the older `.btn`/`.btn-primary`/`.btn-rec` triplet and inline
  text-link buttons across all LiveViews. Icon-only with hover-glow; the
  `title` attribute doubles as the accessible label (screen reader + tooltip).

  Variants are pre-defined — pick the closest `kind`. Sizes: `:sm` (18 px,
  default, for list-row actions like edit/delete), `:md` (24 px, for
  secondary controls like Pause/Marker), `:lg` (32 px, for primary CTAs
  like REC/Stopp/Kampagne-gründen and destructive cascade-deletes).

  Pass `phx-click`, `phx-value-*`, `disabled`, `data-confirm` etc. directly
  — they flow through `:rest` (global attrs).

  ## Examples

      <.cyber_icon_button kind={:edit} phx-click="utterance_edit_start"
        phx-value-id={u["id"]} title="Eintrag bearbeiten" />

      <.cyber_icon_button kind={:rec_start} size={:lg} phx-click="rec_start"
        disabled={not @owner?} title="Aufnahme starten" />

      <.cyber_icon_button kind={:cascade_delete} size={:lg} type="submit"
        disabled={String.trim(@typed) != @campaign_name}
        title="Endgültig löschen" />
  """
  attr(:kind, :atom,
    required: true,
    values: [
      :edit,
      :delete,
      :confirm,
      :cancel,
      :add,
      :create,
      :rec_start,
      :rec_stop,
      :rec_pause,
      :rec_resume,
      :marker,
      :mic_on,
      :mic_off,
      :power,
      :invite,
      :revoke,
      :download,
      :regenerate,
      :reset,
      :cascade_delete,
      :diff,
      :collapse,
      :expand,
      :copy,
      :notifications,
      :test
    ]
  )

  attr(:size, :atom, default: :sm, values: [:sm, :md, :lg])
  attr(:type, :string, default: "button", values: ~w(button submit))
  attr(:title, :string, required: true)
  attr(:class, :string, default: nil)
  attr(:rest, :global, include: ~w(form name value))

  def cyber_icon_button(assigns) do
    assigns =
      assigns
      |> assign(:icon, icon_for(assigns.kind))
      |> assign(:kind_class, "cyber-btn-#{kind_class_suffix(assigns.kind)}")
      |> assign(:size_class, "cyber-btn-#{assigns.size}")
      |> assign(:icon_class, icon_size_class(assigns.size))

    ~H"""
    <button
      type={@type}
      title={@title}
      aria-label={@title}
      class={["cyber-btn", @kind_class, @size_class, @class]}
      {@rest}
    >
      <svg
        class="absolute inset-0 w-full h-full"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        stroke-width="1.4"
        stroke-linecap="round"
        stroke-linejoin="round"
        aria-hidden="true"
      >
        <polygon points="12,2 21,7 21,17 12,22 3,17 3,7" />
      </svg>
      <span class={["hero-#{@icon} relative z-10", @icon_class]} aria-hidden="true"></span>
    </button>
    """
  end

  # Heroicon (Tailwind-plugin name) pro Kind.
  defp icon_for(:edit), do: "pencil"
  defp icon_for(:delete), do: "trash"
  defp icon_for(:confirm), do: "check"
  defp icon_for(:cancel), do: "x-mark"
  defp icon_for(:add), do: "plus-mini"
  defp icon_for(:create), do: "plus"
  defp icon_for(:rec_start), do: "stop-circle-solid"
  defp icon_for(:rec_stop), do: "stop-circle"
  defp icon_for(:rec_pause), do: "pause"
  defp icon_for(:rec_resume), do: "play"
  defp icon_for(:marker), do: "bookmark"
  defp icon_for(:mic_on), do: "microphone"
  defp icon_for(:mic_off), do: "no-symbol"
  defp icon_for(:power), do: "power"
  defp icon_for(:invite), do: "link-mini"
  defp icon_for(:revoke), do: "no-symbol"
  defp icon_for(:download), do: "cloud-arrow-down"
  defp icon_for(:regenerate), do: "arrow-path"
  defp icon_for(:reset), do: "arrow-uturn-left"
  defp icon_for(:cascade_delete), do: "trash"
  defp icon_for(:diff), do: "clipboard-document"
  defp icon_for(:collapse), do: "chevron-right"
  defp icon_for(:expand), do: "chevron-left"
  defp icon_for(:copy), do: "clipboard-document"
  defp icon_for(:notifications), do: "bell"
  defp icon_for(:test), do: "bolt"
  defp icon_for(:promote), do: "chevron-double-up"
  defp icon_for(:demote), do: "chevron-double-down"

  # Atom-Kind → CSS-Klassen-Suffix (Underscore → Hyphen).
  defp kind_class_suffix(kind),
    do: kind |> Atom.to_string() |> String.replace("_", "-")

  defp icon_size_class(:sm), do: "w-[10px] h-[10px]"
  defp icon_size_class(:md), do: "w-3.5 h-3.5"
  defp icon_size_class(:lg), do: "w-5 h-5"

  # ── Lore-Spy-Buttons (Issue #170) ──────────────────────────────
  # Modernerer Label-Button mit Glow-Effekten. Lebt parallel zu
  # cyber_icon_button (Hex-Icon-Buttons aus Issue #116). Migration
  # inkrementell, beginnend bei Dashboard.

  attr(:variant, :atom,
    default: :primary,
    values: [:primary, :secondary, :outline, :ghost, :success, :danger]
  )

  attr(:size, :atom, default: :md, values: [:sm, :md, :lg, :xl])
  attr(:type, :string, default: "button", values: ~w(button submit reset))
  attr(:icon, :string, default: nil, doc: "Heroicon-Name (z.B. \"plus\", \"trash\")")
  attr(:loading, :boolean, default: false)
  attr(:class, :string, default: nil)
  attr(:rest, :global, include: ~w(form name value disabled href))
  slot(:inner_block, required: true)

  def ls_btn(assigns) do
    ~H"""
    <button
      type={@type}
      class={[
        "ls-btn",
        ls_btn_variant_class(@variant),
        ls_btn_size_class(@size),
        @loading && "ls-btn--loading",
        @class
      ]}
      {@rest}
    >
      <span :if={@icon} class={["hero-#{@icon} ls-btn-icon", ls_btn_icon_size_class(@size)]} aria-hidden="true"></span>
      {render_slot(@inner_block)}
    </button>
    """
  end

  defp ls_btn_variant_class(:primary), do: "ls-btn--primary"
  defp ls_btn_variant_class(:secondary), do: "ls-btn--secondary"
  defp ls_btn_variant_class(:outline), do: "ls-btn--outline"
  defp ls_btn_variant_class(:ghost), do: "ls-btn--ghost"
  defp ls_btn_variant_class(:success), do: "ls-btn--success"
  defp ls_btn_variant_class(:danger), do: "ls-btn--danger"

  defp ls_btn_size_class(:sm), do: "ls-btn--sm"
  defp ls_btn_size_class(:md), do: nil
  defp ls_btn_size_class(:lg), do: "ls-btn--lg"
  defp ls_btn_size_class(:xl), do: "ls-btn--xl"

  defp ls_btn_icon_size_class(:sm), do: "w-3 h-3"
  defp ls_btn_icon_size_class(:md), do: "w-3.5 h-3.5"
  defp ls_btn_icon_size_class(:lg), do: "w-4 h-4"
  defp ls_btn_icon_size_class(:xl), do: "w-5 h-5"

  # ── Lore-Spy Icon Buttons (Issue #170, 5b.4) ───────────────────
  # Quadratische / runde Icon-only-Buttons. Baut auf .ls-btn auf, erbt
  # Variant-Farben + Hover-Glow. Ersetzt schrittweise cyber_icon_button
  # für nicht-Inline-Stellen (z.B. Card-Aktionen, Recording-Controls).

  attr(:variant, :atom,
    default: :primary,
    values: [:primary, :secondary, :outline, :ghost, :success, :danger]
  )

  attr(:size, :atom, default: :md, values: [:sm, :md, :lg])
  attr(:shape, :atom, default: :square, values: [:square, :round])
  attr(:icon, :string, required: true, doc: "Heroicon-Name")
  attr(:label, :string, required: true, doc: "ARIA-Label (Pflicht weil icon-only)")
  attr(:type, :string, default: "button", values: ~w(button submit reset))
  attr(:class, :string, default: nil)
  attr(:rest, :global, include: ~w(form name value disabled href))

  def ls_icon_btn(assigns) do
    ~H"""
    <button
      type={@type}
      title={@label}
      aria-label={@label}
      class={[
        "ls-btn ls-icon-btn",
        ls_btn_variant_class(@variant),
        ls_icon_btn_size_class(@size),
        @shape == :round && "ls-icon-btn--round",
        @class
      ]}
      {@rest}
    >
      <span class={["hero-#{@icon}", ls_icon_btn_icon_size_class(@size)]} aria-hidden="true"></span>
    </button>
    """
  end

  defp ls_icon_btn_size_class(:sm), do: "ls-icon-btn--sm"
  defp ls_icon_btn_size_class(:md), do: nil
  defp ls_icon_btn_size_class(:lg), do: "ls-icon-btn--lg"

  defp ls_icon_btn_icon_size_class(:sm), do: "w-3.5 h-3.5"
  defp ls_icon_btn_icon_size_class(:md), do: "w-4 h-4"
  defp ls_icon_btn_icon_size_class(:lg), do: "w-5 h-5"

  # ── Themed Action Buttons (Issue #170, 5b.3) ───────────────────
  # Spezielle TTRPG-Feeling-Buttons für Hero-Bereiche. Bewusst sparsam
  # einsetzen — wenn alles "epic" ist, ist nichts mehr "epic".

  attr(:type, :string, default: "button", values: ~w(button submit reset))
  attr(:icon, :string, default: nil, doc: "Heroicon-Name als Prefix")
  attr(:class, :string, default: nil)
  attr(:rest, :global, include: ~w(form name value disabled))
  slot(:inner_block, required: true)

  @doc """
  Epic-Action-Button — Cinzel-Schrift, dark background, cyan-purple
  Gradient-Border-Animation. Für narrativ wichtige Aktionen
  (z.B. „Kampagne starten", „Lore enthüllen"). Bewusst sparsam.
  """
  def ls_btn_epic(assigns) do
    ~H"""
    <button type={@type} class={["ls-btn ls-btn--epic", @class]} {@rest}>
      <span :if={@icon} class={["hero-#{@icon} w-4 h-4"]} aria-hidden="true"></span>
      {render_slot(@inner_block)}
    </button>
    """
  end

  attr(:type, :string, default: "button", values: ~w(button submit reset))
  attr(:label, :string, required: true, doc: "ARIA-Label, z.B. \"Roll D20\"")
  attr(:class, :string, default: nil)
  attr(:rest, :global, include: ~w(form name value disabled))
  slot(:inner_block, required: true)

  @doc """
  D20-Roll-Button — quadratisch (64×64), leicht rotiert, Hover-Wackler
  + Scale. Für Würfel-/Zufalls-Aktionen. Heute kein konkreter Caller —
  ready-to-use für zukünftige Features (Issue-Backlog z.B. Random-NPC,
  Encounter-Generator).
  """
  def ls_btn_roll(assigns) do
    ~H"""
    <button type={@type} class={["ls-btn--roll", @class]} aria-label={@label} {@rest}>
      {render_slot(@inner_block)}
    </button>
    """
  end

  attr(:type, :string, default: "button", values: ~w(button submit reset))
  attr(:icon, :string, required: true, doc: "Heroicon-Name (zentriert im FAB)")
  attr(:label, :string, required: true, doc: "ARIA-Label")
  attr(:class, :string, default: nil)
  attr(:rest, :global, include: ~w(form name value disabled))

  @doc """
  Floating Action Button — rund (56×56), cyan-glow + pulse-Animation.
  Für persistente Hero-Aktionen (z.B. „+ Neue Lore" floating bottom-
  right). Heute kein konkreter Caller — ready-to-use.
  """
  def ls_fab(assigns) do
    ~H"""
    <button type={@type} class={["ls-fab", @class]} aria-label={@label} {@rest}>
      <span class={"hero-#{@icon}"} aria-hidden="true"></span>
    </button>
    """
  end
end
