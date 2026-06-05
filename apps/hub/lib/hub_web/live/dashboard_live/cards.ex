defmodule HubWeb.DashboardLive.Cards do
  @moduledoc """
  Issue #573: render-Helpers für `HubWeb.DashboardLive` — Campaign-Karten,
  Live-Status-Dots (Recording/Whisper/LLM), Waiting-Panel, Avatar-/Display-
  Resolver und Invite-URL-Helfer.

  Function-Components werden vom Top-Level-render via `<Cards.foo … />`
  aufgerufen. Plain-Helpers (`whisper_active?/2`, `display_for/2`, ...) sind
  reine Funktionen ohne `~H`-Sigil.
  """

  use HubWeb, :html

  alias HubWeb.DashboardLive.Permissions, as: CardPermissions

  def waiting_panel(assigns) do
    ~H"""
    <div class="panel p-10 text-center">
      <span class="hero-cloud-arrow-down w-10 h-10 mx-auto text-accent block mb-3"></span>
      <h2 class="font-display text-lg tracking-wide mb-2">Warte auf Worker</h2>
      <p class="text-ink-2">Keiner deiner Worker ist gerade online.</p>
    </div>
    """
  end

  def campaign_card(assigns) do
    assigns =
      assign(assigns,
        can_invite?:
          CardPermissions.can_invite_campaign?(
            assigns.current_user,
            assigns.viewer_role,
            assigns.campaign
          ),
        can_edit?:
          CardPermissions.can_edit_campaign?(
            assigns.current_user,
            assigns.viewer_role,
            assigns.campaign
          ),
        can_delete?:
          CardPermissions.can_delete_campaign?(
            assigns.current_user,
            assigns.viewer_role,
            assigns.campaign
          ),
        first_invite: assigns.campaign |> card_active_invites() |> List.first(),
        extra_invite_count: max(0, length(card_active_invites(assigns.campaign)) - 1)
      )

    ~H"""
    <div class={["card block group", @campaign["status"] in ["archived", :archived] && "opacity-60"]}>
      <.link navigate={~p"/campaigns/#{@campaign["id"]}"} class="block">
        <div class="flex items-start gap-3">
          <%!-- Issue #275: Icon-Slot 96×96 statt 48×48 — entweder hochgeladenes
               Bild (Data-URI in icon_url) oder Heroicon-Fallback. --%>
          <div class="w-24 h-24 rounded-md bg-bg-1 border border-bg-3 flex items-center justify-center text-accent shadow-glow-sm overflow-hidden shrink-0">
            <%= case campaign_icon(@campaign) do %>
              <% {:img, src} -> %>
                <img src={src} alt="" class="w-full h-full object-cover" loading="lazy" />
              <% {:heroicon, slug} -> %>
                <span class={[slug, "w-10 h-10"]}></span>
            <% end %>
          </div>
          <div class="flex-1 min-w-0">
            <div class="flex items-baseline gap-2 justify-between">
              <h3 class="font-display text-base text-ink-0 truncate group-hover:text-accent transition-colors flex items-center gap-2">
                <.recording_dot state={@campaign["active_recording"]} />
                <.whisper_dot active={whisper_active?(@live_status, @campaign["id"])} />
                <.llm_dot active={llm_active?(@live_status, @campaign["id"])} />
                {@campaign["name"]}
              </h3>
              <span class={["pill", status_pill(@campaign["status"])]}>
                {@campaign["status"]}
              </span>
            </div>
            <p class="mt-2 text-xs text-ink-2 line-clamp-2">
              {@campaign["theme_blurb"] || "(noch keine Beschreibung)"}
            </p>
            <p class="mt-3 text-[11px] uppercase tracking-wider text-ink-2 flex items-center gap-2">
              <span>Spielleiter:</span>
              <img
                src={avatar_url_for(@campaign["owner_discord_id"], @users)}
                alt=""
                class="w-5 h-5 rounded-full bg-bg-2"
                loading="lazy"
              />
              <span class="text-ink-1 normal-case tracking-normal">{display_for(@campaign["owner_discord_id"], @users)}</span>
            </p>
            <%= if players_text(@campaign, @users) != "" do %>
              <p class="mt-1 text-[11px] uppercase tracking-wider text-ink-2 flex items-center gap-2 flex-wrap">
                <span>Spieler:</span>
                <span class="flex -space-x-1.5">
                  <%= for did <- player_dids(@campaign) |> Enum.take(5) do %>
                    <img
                      src={avatar_url_for(did, @users)}
                      title={display_for(did, @users)}
                      alt=""
                      class="w-5 h-5 rounded-full bg-bg-2 ring-1 ring-bg-0"
                      loading="lazy"
                    />
                  <% end %>
                </span>
                <span class="text-ink-1 normal-case tracking-normal">{players_text(@campaign, @users)}</span>
              </p>
            <% end %>
          </div>
        </div>
      </.link>

      <%!-- Issue #275: Action-Bar unten — Invite links, Edit + Delete rechts. --%>
      <%= if @can_invite? or @can_edit? or @can_delete? do %>
        <div class="mt-3 pt-3 border-t border-bg-3 flex items-center justify-between gap-2">
          <%!-- LINKS: Invite-Block --%>
          <div class="flex-1 min-w-0">
            <%= if @can_invite? do %>
              <%= if @first_invite do %>
                <div class="flex items-center gap-1.5 text-xs min-w-0">
                  <span class="hero-link w-3.5 h-3.5 text-accent shrink-0"></span>
                  <input
                    type="text"
                    readonly
                    value={short_invite_path(@first_invite["token"])}
                    title={full_invite_url(@first_invite["token"])}
                    class="flex-1 min-w-0 bg-transparent text-ink-1 truncate cursor-pointer outline-none text-xs"
                    onclick="this.select()"
                  />
                  <.icon_btn
                    icon="copy"
                    label="In Zwischenablage kopieren"
                    id={"copy-#{@first_invite["token"]}"}
                    phx-hook="CopyToClipboard"
                    data-copy-text={full_invite_url(@first_invite["token"])}
                    class="shrink-0"
                  />
                  <.icon_btn
                    icon="trash"
                    variant="danger"
                    label="Einladung widerrufen"
                    phx-click="revoke_invite"
                    phx-value-token={@first_invite["token"]}
                    phx-value-campaign_id={@campaign["id"]}
                    data-confirm="Einladung widerrufen?"
                    class="shrink-0"
                  />
                </div>
                <%= if @extra_invite_count > 0 do %>
                  <.link
                    navigate={~p"/campaigns/#{@campaign["id"]}"}
                    class="mt-1 text-[10px] text-ink-2 hover:text-accent block"
                  >
                    + {@extra_invite_count} weitere — in Kampagne verwalten
                  </.link>
                <% end %>
              <% else %>
                <.icon_btn
                  icon="link"
                  label="Einladung erstellen"
                  phx-click="create_invite"
                  phx-value-campaign_id={@campaign["id"]}
                />
              <% end %>
            <% end %>
          </div>

          <%!-- RECHTS: Bearbeiten + Löschen --%>
          <div class="flex items-center gap-2 shrink-0">
            <%= if @can_edit? do %>
              <.icon_btn
                icon="edit"
                label="Kampagne bearbeiten"
                phx-click="open_edit_modal"
                phx-value-id={@campaign["id"]}
              />
            <% end %>
            <%= if @can_delete? do %>
              <.icon_btn
                icon="trash"
                variant="danger"
                label="Kampagne löschen"
                phx-click="open_delete_modal"
                phx-value-id={@campaign["id"]}
                phx-value-name={@campaign["name"]}
              />
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  attr :state, :string, default: nil

  def recording_dot(%{state: "recording"} = assigns) do
    ~H"""
    <span
      class="inline-block w-2 h-2 rounded-full bg-rec-soft animate-pulse"
      title="Aufnahme läuft"
    ></span>
    """
  end

  def recording_dot(%{state: "paused"} = assigns) do
    ~H"""
    <span class="inline-block w-2 h-2 rounded-full bg-ink-2" title="Pausiert"></span>
    """
  end

  def recording_dot(assigns), do: ~H""

  # Issue #249: Whisper (Stage 1) — cyan-pulsierend solange Worker transkribiert.
  attr :active, :boolean, default: false

  def whisper_dot(%{active: true} = assigns) do
    ~H"""
    <span
      class="inline-block w-2 h-2 rounded-full bg-sky-400 animate-pulse"
      title="Whisper transkribiert"
    ></span>
    """
  end

  def whisper_dot(assigns), do: ~H""

  # Issue #249: LLM-Pipeline (Stage 2/3/4) — grün-pulsierend solange eine
  # der Stages 2/3/4 läuft.
  attr :active, :boolean, default: false

  def llm_dot(%{active: true} = assigns) do
    ~H"""
    <span
      class="inline-block w-2 h-2 rounded-full bg-emerald-400 animate-pulse"
      title="LLM-Pipeline läuft"
    ></span>
    """
  end

  def llm_dot(assigns), do: ~H""

  # ─── Plain Helpers ────────────────────────────────────────────────

  @spec whisper_active?(map(), String.t()) :: boolean()
  def whisper_active?(live_status, cid) do
    case Map.get(live_status, cid) do
      nil -> false
      stages -> MapSet.member?(stages, "stage1")
    end
  end

  @spec llm_active?(map(), String.t()) :: boolean()
  def llm_active?(live_status, cid) do
    case Map.get(live_status, cid) do
      nil ->
        false

      stages ->
        Enum.any?(["stage2", "stage3", "stage4"], &MapSet.member?(stages, &1))
    end
  end

  # Issue #275: Icon-Render-Helper. Data-URI im icon_url → Bild,
  # sonst Heroicon-Fallback. Defensive Klausel für unbekannte Schemes.
  def campaign_icon(%{"icon_url" => "data:image/" <> _ = data_uri}), do: {:img, data_uri}
  def campaign_icon(_), do: {:heroicon, "hero-book-open"}

  # Players (members with role != owner), max 5 names, then "+N weitere".
  def players_text(%{"members" => members, "owner_discord_id" => owner_id}, users)
      when is_list(members) do
    players =
      members
      |> Enum.reject(fn m -> m["discord_id"] == owner_id end)
      |> Enum.map(fn m -> display_for(m["discord_id"], users) end)

    case players do
      [] ->
        ""

      list when length(list) <= 5 ->
        Enum.join(list, ", ")

      list ->
        shown = Enum.take(list, 5) |> Enum.join(", ")
        rest = length(list) - 5
        "#{shown} +#{rest} weitere"
    end
  end

  def players_text(_, _), do: ""

  def player_dids(%{"members" => members, "owner_discord_id" => owner_id})
      when is_list(members) do
    members
    |> Enum.reject(fn m -> m["discord_id"] == owner_id end)
    |> Enum.map(& &1["discord_id"])
  end

  def player_dids(_), do: []

  @spec display_for(String.t() | nil, map() | term()) :: String.t() | nil
  def display_for(discord_id, users) when is_map(users) do
    case Map.get(users, discord_id) do
      %{"display_name" => name} -> name
      name when is_binary(name) -> name
      _ -> discord_id
    end
  end

  def display_for(discord_id, _), do: discord_id

  # Discord-CDN default avatar derived from the discord_id snowflake.
  # Per Discord-Dev-Docs: `(snowflake >> 22) % 6` picks one of six embed
  # avatar files. If discord_id isn't numeric, fall back to bucket 0.
  @spec default_avatar_url(String.t() | term()) :: String.t()
  def default_avatar_url(discord_id) when is_binary(discord_id) do
    bucket =
      case Integer.parse(discord_id) do
        {n, ""} -> rem(Bitwise.bsr(n, 22), 6)
        _ -> 0
      end

    "https://cdn.discordapp.com/embed/avatars/#{bucket}.png"
  end

  def default_avatar_url(_), do: "https://cdn.discordapp.com/embed/avatars/0.png"

  @spec avatar_url_for(String.t() | nil, map() | term()) :: String.t()
  def avatar_url_for(discord_id, users) when is_map(users) do
    case Map.get(users, discord_id) do
      %{"avatar_url" => url} when is_binary(url) and url != "" -> url
      _ -> default_avatar_url(discord_id)
    end
  end

  def avatar_url_for(discord_id, _), do: default_avatar_url(discord_id)

  @spec status_pill(String.t() | atom() | nil) :: String.t()
  def status_pill("active"), do: "pill-active"
  def status_pill("archived"), do: "pill-archived"
  def status_pill(_), do: "pill-new"

  @spec card_active_invites(map()) :: [map()]
  def card_active_invites(campaign) do
    (campaign["active_invites"] || [])
    |> Enum.filter(&(&1["status"] == "active"))
  end

  @spec short_invite_path(String.t()) :: String.t()
  def short_invite_path(token), do: "/invite/#{String.slice(token, 0, 8)}…"

  @spec full_invite_url(String.t()) :: String.t()
  def full_invite_url(token), do: HubWeb.Endpoint.url() <> "/invite/#{token}"
end
