defmodule HubWeb.DashboardLive do
  @moduledoc """
  Mockup-3 ("Haupt-Panel") dashboard: campaign card grid + search + bell +
  "+ Kampagne gründen" modal. Subscribes to `Hub.Events`'s PubSub topic
  and re-fetches the campaign list when a `Campaign*` event fires.
  """

  use HubWeb, :live_view

  alias Hub.{EventBridge, Events, Reader}
  require Logger
  alias HubWeb.Permissions

  @impl true
  def mount(_params, %{"current_user" => user}, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Hub.PubSub, Events.topic())
      Phoenix.PubSub.subscribe(Hub.PubSub, Hub.WorkerRegistry.topic())
    end

    {:ok,
     socket
     |> assign(:current_user, user)
     |> assign(:active_nav, :dashboard)
     |> assign(:current_campaign, nil)
     |> assign(:search, "")
     |> assign(:show_new_modal, false)
     |> assign(:new_name, "")
     |> load_campaigns()}
  end

  @impl true
  def handle_event("open_new_modal", _, socket) do
    if socket.assigns.can_create_campaign? do
      {:noreply, assign(socket, :show_new_modal, true)}
    else
      {:noreply,
       put_flash(socket, :error, "Nur Spielleiter oder Admin dürfen Kampagnen anlegen.")}
    end
  end

  def handle_event("close_new_modal", _, socket) do
    {:noreply, assign(socket, show_new_modal: false, new_name: "")}
  end

  def handle_event("create_campaign", %{"name" => name}, socket)
      when is_binary(name) and byte_size(name) > 0 do
    if not socket.assigns.can_create_campaign? do
      raise "create_campaign blocked by Permissions — UI gate bypassed?"
    end

    payload = %{
      "kind" => Shared.Events.campaign_created(),
      "id" => UUIDv7.generate(),
      "name" => name,
      "icon_url" => nil,
      "theme_blurb" => nil,
      "owner_discord_id" => socket.assigns.current_user.discord_id,
      "owner_display_name" => socket.assigns.current_user.display_name
    }

    bridge_publish(payload)
    {:noreply, assign(socket, show_new_modal: false, new_name: "")}
  end

  def handle_event("create_campaign", _, socket), do: {:noreply, socket}

  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, assign(socket, :search, q)}
  end

  def handle_event("create_invite", %{"campaign_id" => campaign_id}, socket) do
    campaign = Enum.find(socket.assigns.campaigns, &(&1["id"] == campaign_id))

    perm_user = build_perm_user(socket, campaign)

    if campaign && Permissions.can?(perm_user, :invite_to_campaign, %{id: campaign_id}) do
      token = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

      bridge_publish(%{
        "kind" => Shared.Events.invite_created(),
        "token" => token,
        "campaign_id" => campaign_id,
        "created_by_discord_id" => socket.assigns.current_user.discord_id,
        "expires_at" => nil
      })
    end

    {:noreply, socket}
  end

  def handle_event("revoke_invite", %{"token" => token, "campaign_id" => campaign_id}, socket) do
    campaign = Enum.find(socket.assigns.campaigns, &(&1["id"] == campaign_id))

    perm_user = build_perm_user(socket, campaign)

    if campaign && Permissions.can?(perm_user, :invite_to_campaign, %{id: campaign_id}) do
      bridge_publish(%{
        "kind" => Shared.Events.invite_revoked(),
        "token" => token,
        "campaign_id" => campaign_id
      })
    end

    {:noreply, socket}
  end

  # Issue #140: per-Campaign-Rolle aus der Members-Liste der jeweiligen
  # Campaign ableiten, damit Permissions.can?/3 die per-Campaign-Rechte
  # korrekt auswerten kann.
  defp build_perm_user(socket, nil) do
    %{
      discord_id: socket.assigns.current_user.discord_id,
      role: socket.assigns.viewer_role,
      campaign_role: nil
    }
  end

  defp build_perm_user(socket, campaign) do
    me = socket.assigns.current_user.discord_id

    # Backward-Compat: alte Worker (<0.13.0) liefern noch `:owner`/`:player`.
    # Siehe CampaignLive — Multi-Worker-Setups können beides gleichzeitig
    # zeigen, bis alle Worker auf >=0.13.0 sind.
    campaign_role =
      case Enum.find(campaign["members"] || [], &(&1["discord_id"] == me)) do
        %{"role" => "spielleiter"} -> :spielleiter
        %{"role" => "owner"} -> :spielleiter
        %{"role" => "spieler"} -> :spieler
        %{"role" => "player"} -> :spieler
        _ -> nil
      end

    %{
      discord_id: me,
      role: socket.assigns.viewer_role,
      campaign_role: campaign_role
    }
  end

  def handle_event("copy_success", _, socket),
    do: {:noreply, put_flash(socket, :info, "Einladungs-Link kopiert!")}

  def handle_event("copy_failed", _, socket),
    do:
      {:noreply,
       put_flash(socket, :error, "Kopieren fehlgeschlagen — bitte URL manuell markieren.")}

  @impl true
  def handle_info({:event_appended, %{payload: %{"kind" => kind}}}, socket)
      when kind in [
             "CampaignCreated",
             "CampaignUpdated",
             "CampaignDeleted",
             "SessionStarted",
             "SessionEnded",
             "RecordingStateChanged",
             "UserRoleSet",
             "AdminMemberAdded",
             "InviteCreated",
             "InviteRevoked"
           ] do
    Process.send_after(self(), :reload, 150)
    {:noreply, socket}
  end

  def handle_info({:event_appended, _}, socket), do: {:noreply, socket}
  def handle_info(:reload, socket), do: {:noreply, load_campaigns(socket)}

  # A worker (re)connected or disconnected — re-fetch so "Warte auf Worker"
  # disappears the moment one is available.
  def handle_info({:workers_changed, _joins, _leaves}, socket),
    do: {:noreply, load_campaigns(socket)}

  defp load_campaigns(socket) do
    scope = %{"kind" => "campaigns_for", "discord_id" => socket.assigns.current_user.discord_id}

    case Reader.read(scope) do
      {:ok, snap} ->
        role = (snap["viewer_role"] || "spieler") |> String.to_atom()

        socket
        |> assign(
          waiting?: false,
          campaigns: snap["campaigns"] || [],
          users: snap["users"] || %{},
          viewer_role: role,
          can_create_campaign?: role in [:admin, :spielleiter]
        )
        |> backfill_viewer_user(snap["users"] || %{})

      {:error, :no_worker} ->
        socket
        |> assign(
          waiting?: true,
          campaigns: [],
          users: %{},
          viewer_role: :spieler,
          can_create_campaign?: false
        )

      {:error, reason} ->
        socket
        |> put_flash(:error, "Snapshot-Read fehlgeschlagen: #{inspect(reason)}")
        |> assign(
          waiting?: false,
          campaigns: [],
          users: %{},
          viewer_role: :spieler,
          can_create_campaign?: false
        )
    end
  end

  defp filtered(campaigns, ""), do: campaigns

  defp filtered(campaigns, q) do
    needle = String.downcase(q)
    Enum.filter(campaigns, &String.contains?(String.downcase(&1["name"]), needle))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="px-8 py-6 max-w-7xl">
      <header class="flex items-center justify-between gap-6 mb-8">
        <h1 class="font-display text-2xl tracking-wide">Haupt-Panel</h1>
        <form phx-change="search" class="flex-1 max-w-md">
          <div class="relative">
            <span class="hero-magnifying-glass-mini w-4 h-4 absolute left-3 top-2.5 text-ink-2">
            </span>
            <input
              name="q"
              type="text"
              value={@search}
              placeholder="Suche…"
              class="w-full bg-bg-1 border border-bg-3 rounded-md pl-9 pr-3 py-2 text-sm text-ink-0 placeholder:text-ink-2 focus:border-accent focus:ring-0"
            />
          </div>
        </form>
        <div class="flex items-center gap-3">
          <.ls_icon_btn variant={:ghost} size={:md} icon="bell" label="Benachrichtigungen (kommt später)" phx-click="noop" disabled />
          <div class="flex items-center gap-2 text-ink-1 text-sm">
            <span class="hero-user-circle-solid w-7 h-7 text-accent"></span>
            <span class="hidden lg:inline">{@current_user.display_name}</span>
          </div>
        </div>
      </header>

      <%= if @waiting? do %>
        <.waiting_panel />
      <% else %>
        <div class="flex items-center justify-end mb-4">
          <%= if @can_create_campaign? do %>
            <.ls_btn variant={:primary} size={:md} icon="plus" phx-click="open_new_modal">
              Kampagne gründen
            </.ls_btn>
          <% end %>
        </div>

        <%= case filtered(@campaigns, @search) do %>
          <% [] -> %>
            <div class="panel p-10 text-center text-ink-2">
              <%= if @campaigns == [] do %>
                <%= if @can_create_campaign? do %>
                  Noch keine Kampagne. Klick oben rechts auf <em>Kampagne gründen</em>,
                  oder lass dich von jemandem einladen.
                <% else %>
                  Noch keine Kampagne. Lass dich von einem Spielleiter einladen.
                <% end %>
              <% else %>
                Keine Kampagne passt zu „{@search}".
              <% end %>
            </div>
          <% list -> %>
            <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
              <%= for c <- list do %>
                <.campaign_card campaign={c} users={@users} current_user={@current_user} viewer_role={@viewer_role} />
              <% end %>
            </div>
        <% end %>

        <section class="mt-10 panel p-5">
          <h2 class="font-display text-sm tracking-widest uppercase text-ink-1 mb-3">
            Anstehende Sitzungen
          </h2>
          <p class="text-ink-2 text-sm">
            Scheduler kommt in M6 — bis dahin sind hier keine Termine sichtbar.
          </p>
        </section>
      <% end %>
    </div>

    <%= if @show_new_modal do %>
      <div
        class="fixed inset-0 z-50 bg-bg-0/80 flex items-center justify-center p-4"
        phx-window-keydown="close_new_modal"
        phx-key="escape"
      >
        <div class="panel max-w-lg w-full p-6 shadow-glow" phx-click-away="close_new_modal">
          <h2 class="font-display text-xl tracking-wide mb-4">Neue Kampagne</h2>
          <form phx-submit="create_campaign" class="space-y-4">
            <label class="block">
              <span class="text-sm text-ink-1">Name</span>
              <input
                name="name"
                type="text"
                required
                autofocus
                placeholder="z.B. The Shadowed Spire"
                value={@new_name}
                class="mt-1 block w-full bg-bg-1 border border-bg-3 rounded-md px-3 py-2 text-ink-0 focus:border-accent focus:ring-0"
              />
            </label>
            <div class="flex justify-end gap-2 pt-2">
              <.ls_btn variant={:ghost} size={:md} phx-click="close_new_modal">Abbrechen</.ls_btn>
              <.ls_btn_epic icon="book-open" type="submit">Kampagne gründen</.ls_btn_epic>
            </div>
          </form>
        </div>
      </div>
    <% end %>
    """
  end

  defp waiting_panel(assigns) do
    ~H"""
    <div class="panel p-10 text-center">
      <span class="hero-cloud-arrow-down w-10 h-10 mx-auto text-accent block mb-3"></span>
      <h2 class="font-display text-lg tracking-wide mb-2">Warte auf Worker</h2>
      <p class="text-ink-2">Keiner deiner Worker ist gerade online.</p>
    </div>
    """
  end

  defp campaign_card(assigns) do
    assigns =
      assign(assigns,
        can_invite?:
          can_invite_campaign?(assigns.current_user, assigns.viewer_role, assigns.campaign),
        first_invite: assigns.campaign |> card_active_invites() |> List.first(),
        extra_invite_count: max(0, length(card_active_invites(assigns.campaign)) - 1)
      )

    ~H"""
    <div class="card block group">
      <.link navigate={~p"/campaigns/#{@campaign["id"]}"} class="block">
        <div class="flex items-start gap-3">
          <div class="w-12 h-12 rounded-md bg-bg-1 border border-bg-3 flex items-center justify-center text-accent shadow-glow-sm">
            <span class="hero-book-open w-6 h-6"></span>
          </div>
          <div class="flex-1 min-w-0">
            <div class="flex items-baseline gap-2 justify-between">
              <h3 class="font-display text-base text-ink-0 truncate group-hover:text-accent transition-colors flex items-center gap-2">
                <.recording_dot state={@campaign["active_recording"]} />
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

      <%= if @can_invite? do %>
        <div class="mt-3 pt-3 border-t border-bg-3">
          <%= if @first_invite do %>
            <div class="flex items-center gap-1.5 text-xs">
              <span class="hero-link w-3.5 h-3.5 text-accent shrink-0"></span>
              <input
                type="text"
                readonly
                value={short_invite_path(@first_invite["token"])}
                title={full_invite_url(@first_invite["token"])}
                class="flex-1 min-w-0 bg-transparent text-ink-1 truncate cursor-pointer outline-none text-xs"
                onclick="this.select()"
              />
              <.ls_icon_btn
                variant={:outline}
                size={:sm}
                icon="clipboard-document"
                label="In Zwischenablage kopieren"
                id={"copy-#{@first_invite["token"]}"}
                phx-hook="CopyToClipboard"
                data-copy-text={full_invite_url(@first_invite["token"])}
                class="shrink-0"
              />
              <.ls_icon_btn
                variant={:danger}
                size={:sm}
                icon="no-symbol"
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
            <.ls_icon_btn
              variant={:primary}
              size={:sm}
              icon="link"
              label="Einladung erstellen"
              phx-click="create_invite"
              phx-value-campaign_id={@campaign["id"]}
            />
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # Players (members with role != owner), max 5 names, then "+N weitere".
  defp players_text(%{"members" => members, "owner_discord_id" => owner_id}, users)
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

  defp players_text(_, _), do: ""

  defp player_dids(%{"members" => members, "owner_discord_id" => owner_id})
       when is_list(members) do
    members
    |> Enum.reject(fn m -> m["discord_id"] == owner_id end)
    |> Enum.map(& &1["discord_id"])
  end

  defp player_dids(_), do: []

  attr(:state, :string, default: nil)

  defp recording_dot(%{state: "recording"} = assigns) do
    ~H"""
    <span
      class="inline-block w-2 h-2 rounded-full bg-rec-soft animate-pulse"
      title="Aufnahme läuft"
    ></span>
    """
  end

  defp recording_dot(%{state: "paused"} = assigns) do
    ~H"""
    <span class="inline-block w-2 h-2 rounded-full bg-ink-2" title="Pausiert"></span>
    """
  end

  defp recording_dot(assigns), do: ~H""

  defp display_for(discord_id, users) when is_map(users) do
    case Map.get(users, discord_id) do
      %{"display_name" => name} -> name
      name when is_binary(name) -> name
      _ -> discord_id
    end
  end

  defp display_for(discord_id, _), do: discord_id

  # Discord-CDN default avatar derived from the discord_id snowflake.
  # Per Discord-Dev-Docs: `(snowflake >> 22) % 6` picks one of six embed
  # avatar files. If discord_id isn't numeric, fall back to bucket 0.
  defp default_avatar_url(discord_id) when is_binary(discord_id) do
    bucket =
      case Integer.parse(discord_id) do
        {n, ""} -> rem(Bitwise.bsr(n, 22), 6)
        _ -> 0
      end

    "https://cdn.discordapp.com/embed/avatars/#{bucket}.png"
  end

  defp default_avatar_url(_), do: "https://cdn.discordapp.com/embed/avatars/0.png"

  defp avatar_url_for(discord_id, users) when is_map(users) do
    case Map.get(users, discord_id) do
      %{"avatar_url" => url} when is_binary(url) and url != "" -> url
      _ -> default_avatar_url(discord_id)
    end
  end

  defp avatar_url_for(discord_id, _), do: default_avatar_url(discord_id)

  defp backfill_viewer_user(socket, users) do
    user = socket.assigns.current_user
    snap_display = display_for(user && user.discord_id, users)

    cond do
      is_nil(user) or is_nil(user.discord_id) or is_nil(user.display_name) ->
        socket

      snap_display == user.display_name ->
        socket

      true ->
        # Auth callback now also emits UserUpserted; this is the safety net
        # for sessions that pre-date the callback hook or for cross-worker
        # name drifts.
        bridge_publish(%{
          "kind" => Shared.Events.user_upserted(),
          "discord_id" => user.discord_id,
          "display_name" => user.display_name
        })

        socket
    end
  end

  # Issue #154 (Etappe 4c.3): Hub-LV delegiert Event-Erzeugung an einen
  # online Worker via EventBridge. Cold-Fail (kein passender Worker für
  # die Campaign / kein Worker überhaupt) → Logger.warning, kein Crash.
  defp bridge_publish(payload) do
    case EventBridge.publish(payload) do
      :ok ->
        :ok

      {:error, :no_worker_online} ->
        Logger.warning(
          "DashboardLive.bridge_publish: kein Worker online (kind=#{payload["kind"]})"
        )

        :ok
    end
  end

  defp status_pill("active"), do: "pill-active"
  defp status_pill("archived"), do: "pill-archived"
  defp status_pill(_), do: "pill-new"

  defp can_invite_campaign?(user, role, campaign) do
    Permissions.can?(
      %{discord_id: user.discord_id, role: role},
      :invite_to_campaign,
      %{owner_discord_id: campaign["owner_discord_id"]}
    )
  end

  defp card_active_invites(campaign) do
    (campaign["active_invites"] || [])
    |> Enum.filter(&(&1["status"] == "active"))
  end

  defp short_invite_path(token), do: "/invite/#{String.slice(token, 0, 8)}…"
  defp full_invite_url(token), do: HubWeb.Endpoint.url() <> "/invite/#{token}"
end
