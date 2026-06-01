defmodule HubWeb.UIComponents do
  @moduledoc """
  UI primitives for the LoreTracker dark-teal design system (Issue #194).

  Use alongside the generated `CoreComponents` module, not as a replacement.
  In `core_components.ex` (or wherever it's `use`d), add:

      import HubWeb.UIComponents

  ## Components

    * `btn/1`        — labeled buttons in 4 variants
    * `icon_btn/1`   — icon-only square buttons (always with aria-label)
    * `chip/1`       — small role/status pills
    * `avatar/1`     — circular initials avatar
    * `player_row/1` — composed row for member lists
    * `tabler/1`     — Tabler icon wrapper (via `tabler_icons` hex lib)

  ## Tokens

  Expects these Tailwind theme colors (siehe `app.css` + `tailwind.config.js`):

      primary, primary-fg, primary-bright, fg, fg-muted,
      surface, surface-2, border, danger, success, warning
  """
  use Phoenix.Component

  # ─── btn — labeled button with optional leading icon ────────────

  attr(:variant, :string,
    default: "primary",
    values: ~w(primary secondary ghost danger),
    doc: "Visual hierarchy tier"
  )

  attr(:icon, :string,
    default: nil,
    doc: "Tabler icon name (e.g. 'microphone', 'user-minus'). Hyphens become underscores."
  )

  attr(:type, :string, default: "button")
  attr(:class, :string, default: nil)

  attr(:rest, :global,
    include:
      ~w(phx-click phx-target phx-value-id phx-value-token phx-value-discord_id phx-value-campaign_id phx-value-session phx-value-stage phx-value-q phx-value-name phx-disable-with phx-submit phx-change phx-key phx-window-keydown phx-click-away phx-hook disabled form name value title data-confirm data-copy-text id)
  )

  slot(:inner_block, required: true)

  def btn(assigns) do
    ~H"""
    <button
      type={@type}
      class={[
        "inline-flex items-center justify-center gap-1.5 h-8 px-3.5 rounded-md",
        "text-xs font-medium uppercase tracking-wider whitespace-nowrap",
        "transition-colors duration-150",
        "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-offset-0",
        "disabled:opacity-50 disabled:cursor-not-allowed disabled:pointer-events-none",
        btn_variant(@variant),
        @class
      ]}
      {@rest}
    >
      <.tabler :if={@icon} name={@icon} class="w-4 h-4 shrink-0" />
      {render_slot(@inner_block)}
    </button>
    """
  end

  defp btn_variant("primary"),
    do:
      "bg-primary text-primary-fg border border-primary hover:brightness-110 focus-visible:ring-primary/50"

  defp btn_variant("secondary"),
    do:
      "bg-transparent text-primary border border-primary/40 hover:bg-primary/10 hover:border-primary/70 focus-visible:ring-primary/50"

  defp btn_variant("ghost"),
    do:
      "bg-transparent text-fg border border-transparent hover:bg-surface-2 focus-visible:ring-primary/30"

  defp btn_variant("danger"),
    do:
      "bg-danger/10 text-danger border border-danger/30 hover:bg-danger/20 focus-visible:ring-danger/40"

  # ─── icon_btn — icon-only square button ─────────────────────────

  attr(:icon, :string, required: true, doc: "Tabler icon name")
  attr(:label, :string, required: true, doc: "ARIA-Label (also tooltip)")
  attr(:variant, :string, default: "default", values: ~w(default danger))
  attr(:type, :string, default: "button")
  attr(:class, :string, default: nil)

  attr(:rest, :global,
    include:
      ~w(phx-click phx-target phx-value-id phx-value-token phx-value-discord_id phx-value-campaign_id phx-value-session phx-value-col phx-value-stage phx-disable-with phx-hook disabled form data-confirm data-copy-text id)
  )

  def icon_btn(assigns) do
    ~H"""
    <button
      type={@type}
      aria-label={@label}
      title={@label}
      class={[
        "inline-flex items-center justify-center w-8 h-8 rounded-md border",
        "transition-colors duration-150",
        "focus-visible:outline-none focus-visible:ring-2",
        "disabled:opacity-50 disabled:cursor-not-allowed",
        icon_btn_variant(@variant),
        @class
      ]}
      {@rest}
    >
      <.tabler name={@icon} class="w-4 h-4" />
    </button>
    """
  end

  defp icon_btn_variant("default"),
    do:
      "border-white/10 text-fg bg-transparent hover:bg-surface-2 hover:text-primary focus-visible:ring-primary/40"

  defp icon_btn_variant("danger"),
    do:
      "border-danger/20 text-danger bg-transparent hover:bg-danger/15 focus-visible:ring-danger/40"

  # ─── chip ────────────────────────────────────────────────────────

  attr(:variant, :string, default: "default", values: ~w(default accent))
  attr(:icon, :string, default: nil)
  attr(:class, :string, default: nil)
  slot(:inner_block, required: true)

  def chip(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1 px-2.5 py-0.5 rounded-full",
      "text-[10px] font-medium uppercase tracking-widest",
      "border whitespace-nowrap",
      chip_variant(@variant),
      @class
    ]}>
      <.tabler :if={@icon} name={@icon} class="w-3 h-3" />
      {render_slot(@inner_block)}
    </span>
    """
  end

  defp chip_variant("default"),
    do: "bg-primary/10 text-primary border-primary/25"

  defp chip_variant("accent"),
    do: "bg-primary/20 text-primary-bright border-primary/50"

  # ─── avatar — circular initials ─────────────────────────────────

  attr(:initials, :string, required: true)
  attr(:size, :string, default: "md", values: ~w(sm md lg))
  attr(:class, :string, default: nil)

  def avatar(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center justify-center rounded-full",
      "bg-primary/15 text-primary font-medium",
      avatar_size(@size),
      @class
    ]}>
      {@initials}
    </span>
    """
  end

  defp avatar_size("sm"), do: "w-6 h-6 text-[10px]"
  defp avatar_size("md"), do: "w-8 h-8 text-[11px]"
  defp avatar_size("lg"), do: "w-10 h-10 text-xs"

  # ─── modal — Issue #352: backdrop + content mit phx-click-away ───
  #
  # Standard-Modal-Pattern für Hub-LiveViews. Backdrop schließt bei Klick;
  # Content-Klicks bubbeln ohne JS-stopPropagation (sonst killt das Phoenix'
  # delegated click-listener für alle inneren `phx-click`-Buttons).
  #
  # `on_close` ist der LV-Event-Name (z.B. "delete_user_cancel"), der beim
  # Backdrop-Klick und Escape-Key gefeuert wird. `phx-click-away` läuft auf
  # dem Content — semantisch gleich wie `phx-click` auf Backdrop, ist
  # technisch der robustere Pfad weil LiveView die `phx-click-away`-Detection
  # selber macht (kein JS-Eingriff).
  #
  # WICHTIG: KEIN `onclick="event.stopPropagation()"` im Content. Phoenix
  # registriert delegated Click-Handler auf document-Level — stopPropagation
  # auf einem Parent-Element kappt alle phx-click-Events innerhalb. Wer
  # das Modal-Schließen "aus dem Inneren nicht" will, soll das per
  # `phx-click-away` lösen (siehe Issue #352).

  attr(:on_close, :string,
    required: true,
    doc: "LV-Event-Name beim Backdrop-Klick / Escape (z.B. \"my_modal_close\")"
  )

  attr(:title, :string, default: nil, doc: "Optionaler Titel (in Header gerendert)")

  attr(:max_width, :string,
    default: "max-w-2xl",
    values: ~w(max-w-sm max-w-md max-w-lg max-w-xl max-w-2xl max-w-3xl max-w-4xl)
  )

  # Issue #410: Outside-Dismiss (Backdrop-Klick + content phx-click-away)
  # optional abschaltbar. Für Setup-Flows mit nativem `<select>` ist das nötig:
  # das OS-Dropdown des Selects löst phx-click-away aus → das Modal würde beim
  # Aufklappen der Mikrofonliste zuklappen. Bei `false` schließt nur der
  # explizite on_close-Button (Escape bleibt, weil deliberate Tastendruck).
  attr(:dismiss_on_outside, :boolean,
    default: true,
    doc: "false → nur Escape + explizite Buttons schließen (kein Backdrop/click-away)"
  )

  attr(:class, :string, default: nil, doc: "Extra-Klassen am Content-Container")
  slot(:inner_block, required: true)

  def lt_modal(assigns) do
    ~H"""
    <div
      role="dialog"
      aria-modal="true"
      phx-click={@dismiss_on_outside && @on_close}
      phx-window-keydown={@on_close}
      phx-key="Escape"
      class="fixed inset-0 z-50 flex items-center justify-center bg-bg-0/70 backdrop-blur-sm"
    >
      <div
        class={[
          "panel p-6 w-full mx-4 shadow-2xl",
          @max_width,
          @class
        ]}
        phx-click-away={@dismiss_on_outside && @on_close}
      >
        <%= if @title do %>
          <h3 class="font-display text-lg text-ink-0 mb-4">{@title}</h3>
        <% end %>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  # ─── VU-Meter-Bar — Issue #391 ──────────────────────────────────
  #
  # Schmaler horizontaler Pegel-Balken. `level` ist 0.0..1.0, die Width wird
  # server-seitig gerendert (kein JS-Hook). Die CSS-Transition glättet die
  # 5-Hz-Updates. Genutzt im Mic-Setup-Modal (lokaler Pegel) und in der
  # mic_controls-Pill (Live-Pegel pro Streamer).
  attr(:level, :float, default: 0.0, doc: "Pegel 0.0..1.0")
  attr(:label, :string, default: nil, doc: "title-Attribut / Tooltip")
  attr(:class, :string, default: nil, doc: "Extra-Klassen am Wrapper (z.B. Breite/Höhe)")

  def vu_bar(assigns) do
    assigns = assign(assigns, :pct, trunc(min(1.0, max(0.0, assigns.level)) * 100))

    ~H"""
    <span class={["inline-flex items-center", @class]} title={@label}>
      <span class="relative inline-block w-12 h-1.5 grow rounded bg-surface-2 overflow-hidden">
        <span
          class="absolute inset-y-0 left-0 transition-[width] duration-75 ease-linear bg-primary"
          style={"width: #{@pct}%"}
        >
        </span>
      </span>
    </span>
    """
  end

  # ─── deleted_user_pill — Placeholder für dangling discord_ids ───
  #
  # Issue #57: Utterances / Sessions / Spend-Logs etc. behalten ihre
  # discord_id auch nach UserDeleted. Diese Komponente rendert dann einen
  # einheitlichen grauen Pill statt einem fehlenden Namen / krassen Avatar.

  attr(:size, :string, default: "md", values: ~w(sm md lg))
  attr(:class, :string, default: nil)

  def deleted_user_pill(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-2 text-fg-muted italic",
      @class
    ]}>
      <span class={[
        "inline-flex items-center justify-center rounded-full",
        "bg-fg-muted/15 text-fg-muted",
        avatar_size(@size)
      ]}>
        ?
      </span>
      <span class="text-xs">[gelöschter User]</span>
    </span>
    """
  end

  # ─── player_row — composed row for member lists ─────────────────

  attr(:name, :string, required: true)
  attr(:initials, :string, required: true)
  attr(:role, :string, default: "player", values: ~w(player co_gm gm))
  attr(:id, :string, required: true, doc: "Used for phx-value-discord_id on actions")
  attr(:allow_demote, :boolean, default: true)
  attr(:can_promote, :boolean, default: true)
  attr(:can_remove, :boolean, default: true)
  attr(:rest, :global)

  def player_row(assigns) do
    ~H"""
    <div class="flex items-center gap-3 px-2 py-2.5 border-b border-border last:border-b-0" {@rest}>
      <.avatar initials={@initials} size="md" />
      <span class="flex-1 text-sm text-fg truncate">{@name}</span>

      <%= case @role do %>
        <% "gm" -> %>
          <.chip variant="accent" icon="crown">Spielleiter</.chip>
        <% "co_gm" -> %>
          <.chip variant="accent" icon="crown">Co-Spielleiter</.chip>
        <% _ -> %>
          <.chip>Spieler:in</.chip>
      <% end %>

      <div class="inline-flex gap-1.5">
        <.icon_btn
          :if={@role == "player" and @can_promote}
          icon="crown"
          label="Zum Co-Spielleiter befördern"
          phx-click="member_promote"
          phx-value-discord_id={@id}
        />
        <.icon_btn
          :if={@role == "co_gm" and @allow_demote}
          icon="crown-off"
          label="Spielleiter-Rolle entziehen"
          phx-click="member_demote_request"
          phx-value-discord_id={@id}
        />
        <.icon_btn
          :if={@can_remove and @role != "gm"}
          icon="user-minus"
          label="Aus Kampagne entfernen"
          variant="danger"
          phx-click="member_remove_request"
          phx-value-discord_id={@id}
          data-confirm="Wirklich aus der Kampagne entfernen?"
        />
      </div>
    </div>
    """
  end

  # ─── tabler — icon wrapper (tabler_icons hex lib) ───────────────

  attr(:name, :string, required: true, doc: "Tabler icon name; hyphens → underscores")
  attr(:class, :string, default: "w-4 h-4")

  def tabler(assigns) do
    function = String.replace(assigns.name, "-", "_") |> String.to_existing_atom()

    assigns = assign(assigns, :function, function)

    ~H"""
    <TablerIcons.icon name={@function} class={@class} />
    """
  end

  # ─── ls_icon_btn_compat (legacy shim) ──────────────────────────
  # Wegwerf-Bridge für Issue #194 Bulk-Migration: nimmt das alte `kind`+
  # `title`-Pattern (z.B. `kind={:edit} title="Eintrag bearbeiten"`) und
  # rendert intern <.icon_btn>. Wird in Folge-PR entfernt — alle Aufrufer
  # sollen dann direkt <.icon_btn icon=... label=...>.

  attr(:kind, :atom, required: true)
  attr(:size, :atom, default: :sm)
  attr(:type, :string, default: "button")
  attr(:title, :string, required: true)
  attr(:class, :string, default: nil)

  attr(:rest, :global,
    include:
      ~w(phx-click phx-target phx-value-id phx-value-token phx-value-discord_id phx-value-campaign_id phx-value-session phx-value-col phx-value-stage phx-value-seq phx-value-name phx-hook phx-disable-with disabled form data-confirm data-copy-text id)
  )

  def ls_icon_btn_compat(assigns) do
    {icon, variant} = compat_kind_to_icon_variant(assigns.kind)

    assigns =
      assigns
      |> assign(:icon, icon)
      |> assign(:variant, variant)

    ~H"""
    <.icon_btn
      icon={@icon}
      label={@title}
      variant={@variant}
      type={@type}
      class={@class}
      {@rest}
    />
    """
  end

  defp compat_kind_to_icon_variant(:edit), do: {"edit", "default"}
  defp compat_kind_to_icon_variant(:delete), do: {"trash", "danger"}
  defp compat_kind_to_icon_variant(:confirm), do: {"check", "default"}
  defp compat_kind_to_icon_variant(:cancel), do: {"x", "default"}
  defp compat_kind_to_icon_variant(:add), do: {"plus", "default"}
  defp compat_kind_to_icon_variant(:create), do: {"plus", "default"}
  defp compat_kind_to_icon_variant(:revoke), do: {"trash", "danger"}
  defp compat_kind_to_icon_variant(:reset), do: {"arrow-back-up", "default"}
  defp compat_kind_to_icon_variant(:regenerate), do: {"refresh", "default"}
  defp compat_kind_to_icon_variant(:rec_start), do: {"microphone", "default"}
  defp compat_kind_to_icon_variant(:rec_stop), do: {"player-stop", "danger"}
  defp compat_kind_to_icon_variant(:rec_pause), do: {"player-pause", "default"}
  defp compat_kind_to_icon_variant(:rec_resume), do: {"player-play", "default"}
  defp compat_kind_to_icon_variant(:marker), do: {"bookmark", "default"}
  defp compat_kind_to_icon_variant(:mic_on), do: {"microphone", "default"}
  defp compat_kind_to_icon_variant(:mic_off), do: {"microphone-off", "danger"}
  defp compat_kind_to_icon_variant(:power), do: {"power", "danger"}
  defp compat_kind_to_icon_variant(:invite), do: {"link", "default"}
  defp compat_kind_to_icon_variant(:expand), do: {"layout-sidebar-right-expand", "default"}
  defp compat_kind_to_icon_variant(:collapse), do: {"layout-sidebar-right-collapse", "default"}
  defp compat_kind_to_icon_variant(:diff), do: {"file-diff", "default"}
  defp compat_kind_to_icon_variant(:demote), do: {"crown-off", "default"}
  defp compat_kind_to_icon_variant(:promote), do: {"crown", "default"}
  defp compat_kind_to_icon_variant(:cascade_delete), do: {"trash", "danger"}
  defp compat_kind_to_icon_variant(:copy), do: {"copy", "default"}
  defp compat_kind_to_icon_variant(:download), do: {"download", "default"}
  defp compat_kind_to_icon_variant(:notifications), do: {"bell", "default"}
  defp compat_kind_to_icon_variant(:test), do: {"bolt", "default"}

  # ─── initials helper ─────────────────────────────────────────────

  @doc """
  Extract 1-2 initials from a display name. Used by `<.avatar>` callers
  who don't already have initials computed.
  """
  def initials_for(nil), do: "?"
  def initials_for(""), do: "?"

  def initials_for(name) when is_binary(name) do
    name
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join("", &String.slice(&1, 0, 1))
    |> String.upcase()
    |> case do
      "" -> String.slice(name, 0, 1) |> String.upcase()
      initials -> initials
    end
  end
end
