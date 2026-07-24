defmodule HubWeb.DashboardLive do
  @moduledoc """
  Mockup-3 ("Haupt-Panel") dashboard: campaign card grid + search + bell +
  "+ Kampagne gründen" modal. Subscribes to `Hub.Events`'s PubSub topic
  and re-fetches the campaign list when a `Campaign*` event fires.

  Issue #573: Card-Render-Helpers + Card-Permissions sind nach
  `HubWeb.DashboardLive.Cards` / `.Permissions` extrahiert.
  """

  use HubWeb, :live_view

  alias Hub.{EventBridge, Events, InputCaps, Reader}
  alias HubWeb.DashboardLive.Cards
  alias HubWeb.Permissions
  alias Shared.Events, as: EventKinds
  require Logger

  # Issue #569: Modul-Attribut für event-kind-Match im handle_info-Head
  # (Iron-Law #8 — kein Remote-Call im Guard).
  @reload_trigger_kinds [
    EventKinds.campaign_created(),
    EventKinds.campaign_updated(),
    EventKinds.campaign_deleted(),
    EventKinds.session_started(),
    EventKinds.session_ended(),
    EventKinds.recording_state_changed(),
    EventKinds.user_role_set(),
    EventKinds.admin_member_added(),
    EventKinds.invite_created(),
    EventKinds.invite_revoked()
  ]

  @impl true
  def mount(_params, %{"current_user" => user}, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Hub.PubSub, Events.topic())
      Phoenix.PubSub.subscribe(Hub.PubSub, Hub.WorkerRegistry.topic())
      # Issue #249/#401: Stage-1 (Whisper) + Stage-2-4 (LLM) Live-Status für die
      # Card-Dots. Seit #401 pro Kampagne ein eigener Topic — die konkreten
      # Subscriptions setzt sync_status_subscriptions/2 NACH dem Campaigns-Load
      # (hier ist die Liste noch nicht da), inkl. Diff bei jedem Reload.
    end

    {:ok,
     socket
     |> assign(:current_user, user)
     |> assign(:active_nav, :dashboard)
     |> assign(:current_campaign, nil)
     |> assign(:search, "")
     |> assign(:show_new_modal, false)
     |> assign(:new_name, "")
     # Issue #270: Delete-Modal. nil = closed; sonst Map mit id/name/typed.
     |> assign(:delete_modal, nil)
     # Issue #275: Edit-Modal. nil = closed; sonst %{"id", "name",
     # "theme_blurb", "icon_url"}. Drafts werden beim phx-change synchronisiert.
     |> assign(:edit_modal, nil)
     # Issue #249: %{campaign_id => MapSet.t(stage_name)}. Whisper-Dot pulst
     # solange "stage1" drin ist, LLM-Dot solange eine der "stage2|3|4" drin
     # ist. Started fügt rein, ended/failed räumt raus.
     |> assign(:live_status, %{})
     # Issue #401: MapSet der campaign_ids, deren pipeline_status:<cid>-Topic
     # aktuell abonniert ist. sync_status_subscriptions/2 diff't dagegen.
     |> assign(:status_topics, MapSet.new())
     # Issue #57: default-off Toggle für archivierte Kampagnen. Wird via
     # LocalStorage-Hook persistiert (siehe ArchiveTogglePersist hook).
     |> assign(:show_archived, false)
     |> assign(
       waiting?: true,
       campaigns: [],
       users: %{},
       viewer_role: :spieler,
       can_create_campaign?: false
     )
     |> start_campaigns_load()}
  end

  # Issue #430: Helfer vor den handle_event-Block gezogen (waren dazwischen →
  # „clauses should be grouped together").

  # Aus dem Snapshot-Member-Eintrag die per-Campaign-Rolle für Permissions.can?/3.
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
    campaign_role =
      case Enum.find(campaign["members"] || [], &(&1["discord_id"] == me)) do
        %{"role" => "spielleiter"} -> :spielleiter
        %{"role" => "owner"} -> :spielleiter
        %{"role" => "spieler"} -> :spieler
        %{"role" => "player"} -> :spieler
        _ -> nil
      end

    %{discord_id: me, role: socket.assigns.viewer_role, campaign_role: campaign_role}
  end

  defp nullify(""), do: nil
  defp nullify(s), do: s

  # Data-URI-Validierung: nil/leer erlaubt, sonst data:image/(png|jpeg|webp);base64,…
  # mit max 200 KB Gesamtlänge.
  # Issue #564: ein Icon ist ok, wenn es UNVERÄNDERT ggü. dem bestehenden
  # campaign-Icon ist (egal ob das bestehende formal valide ist — Speichern
  # anderer Felder darf nicht an einem Alt-Icon scheitern; wir machen es nicht
  # schlimmer) ODER neu UND valide. Der Edit-Form befüllt icon_url mit dem
  # bestehenden Icon, daher würde sonst jedes Speichern ohne Bild-Änderung an
  # einer URL / einem >200 KB-Alt-data:image scheitern.
  @doc false
  def icon_ok?(icon, existing_icon), do: icon == existing_icon or valid_icon_url?(icon)

  defp valid_icon_url?(nil), do: true
  defp valid_icon_url?(""), do: true

  defp valid_icon_url?("data:image/" <> rest = full) do
    byte_size(full) <= 200_000 and String.match?(rest, ~r/^(png|jpe?g|webp);base64,/)
  end

  defp valid_icon_url?(_), do: false

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

  # Issue #57: Toggle "Archivierte zeigen". Default off — archivierte Kampagnen
  # (CampaignArchived → status :archived) sind ausgeblendet. Wert wird via
  # ArchiveTogglePersist-Hook in LocalStorage gepinnt.
  def handle_event("toggle_archived", _params, socket) do
    {:noreply, assign(socket, :show_archived, not socket.assigns.show_archived)}
  end

  def handle_event("hydrate_show_archived", %{"value" => v}, socket) do
    {:noreply, assign(socket, :show_archived, v == true or v == "true")}
  end

  def handle_event("create_campaign", %{"name" => name}, socket)
      when is_binary(name) and byte_size(name) > 0 do
    if not socket.assigns.can_create_campaign? do
      raise "create_campaign blocked by Permissions — UI gate bypassed?"
    end

    # Issue #636: Server-Cap. Draft (`new_name`) behalten — User kürzt und speichert erneut.
    case InputCaps.check(:campaign_name, name) do
      :ok ->
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

      {:error, {:too_long, cap}} ->
        {:noreply, put_flash(socket, :error, InputCaps.error_message(:campaign_name, cap))}
    end
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

  # Issue #270: Delete-Modal-Flow auf der Dashboard-Card.
  def handle_event("open_delete_modal", %{"id" => id, "name" => name}, socket) do
    campaign = Enum.find(socket.assigns.campaigns, &(&1["id"] == id))
    perm_user = build_perm_user(socket, campaign)

    if campaign && Permissions.can?(perm_user, :delete_campaign, campaign) do
      {:noreply, assign(socket, :delete_modal, %{"id" => id, "name" => name, "typed" => ""})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("delete_modal_cancel", _, socket) do
    {:noreply, assign(socket, :delete_modal, nil)}
  end

  def handle_event("delete_modal_typing", %{"name" => typed}, socket) do
    case socket.assigns.delete_modal do
      nil -> {:noreply, socket}
      m -> {:noreply, assign(socket, :delete_modal, Map.put(m, "typed", typed))}
    end
  end

  def handle_event("delete_modal_confirm", %{"name" => typed}, socket) do
    case socket.assigns.delete_modal do
      %{"id" => id, "name" => name} when typed == name ->
        campaign = Enum.find(socket.assigns.campaigns, &(&1["id"] == id))
        perm_user = build_perm_user(socket, campaign)

        if campaign && Permissions.can?(perm_user, :delete_campaign, campaign) do
          bridge_publish(%{
            "kind" => Shared.Events.campaign_deleted(),
            "campaign_id" => id,
            "deleted_by" => socket.assigns.current_user.discord_id
          })

          {:noreply,
           socket
           |> assign(:delete_modal, nil)
           |> put_flash(:info, "Kampagne „#{name}“ gelöscht.")}
        else
          {:noreply, assign(socket, :delete_modal, nil)}
        end

      _ ->
        {:noreply, socket}
    end
  end

  # Issue #275: Edit-Modal-Flow (Name + Beschreibung + Bild-Upload).
  def handle_event("open_edit_modal", %{"id" => id}, socket) do
    campaign = Enum.find(socket.assigns.campaigns, &(&1["id"] == id))
    perm_user = build_perm_user(socket, campaign)

    if campaign && Permissions.can?(perm_user, :edit_summary, campaign) do
      draft = %{
        "id" => id,
        "name" => campaign["name"] || "",
        "theme_blurb" => campaign["theme_blurb"] || "",
        "icon_url" => campaign["icon_url"] || ""
      }

      {:noreply, assign(socket, :edit_modal, draft)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("edit_modal_cancel", _, socket) do
    {:noreply, assign(socket, :edit_modal, nil)}
  end

  def handle_event("edit_modal_typing", params, socket) do
    case socket.assigns.edit_modal do
      nil ->
        {:noreply, socket}

      m ->
        next =
          m
          |> Map.put("name", Map.get(params, "name", m["name"]))
          |> Map.put("theme_blurb", Map.get(params, "theme_blurb", m["theme_blurb"]))
          |> Map.put("icon_url", Map.get(params, "icon_url", m["icon_url"]))

        {:noreply, assign(socket, :edit_modal, next)}
    end
  end

  def handle_event("edit_modal_clear_icon", _, socket) do
    case socket.assigns.edit_modal do
      nil -> {:noreply, socket}
      m -> {:noreply, assign(socket, :edit_modal, Map.put(m, "icon_url", ""))}
    end
  end

  def handle_event("edit_modal_save", params, socket) do
    case socket.assigns.edit_modal do
      %{"id" => id} ->
        campaign = Enum.find(socket.assigns.campaigns, &(&1["id"] == id))
        perm_user = build_perm_user(socket, campaign)

        cond do
          is_nil(campaign) or not Permissions.can?(perm_user, :edit_summary, campaign) ->
            {:noreply, assign(socket, :edit_modal, nil)}

          true ->
            name = params |> Map.get("name", "") |> String.trim()
            blurb = params |> Map.get("theme_blurb", "") |> String.trim()
            icon = params |> Map.get("icon_url", "") |> String.trim()

            existing_icon = (campaign["icon_url"] || "") |> to_string() |> String.trim()

            cond do
              name == "" ->
                {:noreply, put_flash(socket, :error, "Name darf nicht leer sein.")}

              # Issue #636: Server-Caps auf name + theme_blurb. Bei Verstoß Modal
              # + Draft behalten — User kürzt und speichert erneut.
              match?({:error, {:too_long, _}}, InputCaps.check(:campaign_name, name)) ->
                {:error, {:too_long, cap}} = InputCaps.check(:campaign_name, name)

                {:noreply,
                 put_flash(socket, :error, InputCaps.error_message(:campaign_name, cap))}

              match?({:error, {:too_long, _}}, InputCaps.check(:theme_blurb, blurb)) ->
                {:error, {:too_long, cap}} = InputCaps.check(:theme_blurb, blurb)
                {:noreply, put_flash(socket, :error, InputCaps.error_message(:theme_blurb, cap))}

              not icon_ok?(icon, existing_icon) ->
                {:noreply,
                 put_flash(
                   socket,
                   :error,
                   "Bild ungültig (max 200 KB, Format JPEG/PNG/WebP)."
                 )}

              true ->
                payload = %{
                  "kind" => Shared.Events.campaign_updated(),
                  "id" => id,
                  "name" => name,
                  "theme_blurb" => nullify(blurb),
                  "icon_url" => nullify(icon)
                }

                bridge_publish(payload)

                {:noreply,
                 socket
                 |> assign(:edit_modal, nil)
                 |> put_flash(:info, "Kampagne aktualisiert.")}
            end
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("copy_success", _, socket),
    do: {:noreply, put_flash(socket, :info, "Einladungs-Link kopiert!")}

  def handle_event("copy_failed", _, socket),
    do:
      {:noreply,
       put_flash(socket, :error, "Kopieren fehlgeschlagen — bitte URL manuell markieren.")}

  @impl true
  def handle_info({:event_appended, %{payload: %{"kind" => kind}}}, socket)
      when kind in @reload_trigger_kinds do
    # Issue #569: PID-targeted Debounce — BEAM räumt pending send_after beim
    # Prozess-Tod auf (https://www.erlang.org/doc/system/ref_man_processes.html).
    # credo:disable-for-next-line LoreTracker.Credo.Check.TimerWithoutCleanup
    Process.send_after(self(), :reload, 150)
    {:noreply, socket}
  end

  def handle_info({:event_appended, _}, socket), do: {:noreply, socket}

  # Issue #702: gebatchte Events durch die event_appended-Klauseln falten.
  def handle_info({:events_batch, events}, socket),
    do: HubWeb.Live.EventsBatch.fold(events, socket, &handle_info/2)

  def handle_info(:reload, socket), do: {:noreply, start_campaigns_load(socket)}

  # Issue #215: bridge_publish/1 schickt diese Self-Message bei :no_worker_online,
  # damit der User die fehlgeschlagene Aktion sieht (vorher silent fail).
  def handle_info({:bridge_publish_failed, _kind}, socket) do
    {:noreply,
     put_flash(
       socket,
       :error,
       "Aktion konnte gerade nicht ausgeführt werden — kein passender Worker für diese Kampagne online. Bitte gleich nochmal versuchen."
     )}
  end

  # A worker (re)connected or disconnected — re-fetch so "Warte auf Worker"
  # disappears the moment one is available.
  def handle_info({:workers_changed, _joins, _leaves}, socket),
    do: {:noreply, start_campaigns_load(socket)}

  # Issue #249/#401: Stage-Status-Stream. Worker pusht pipeline_stage-Events,
  # WorkerChannel broadcastet sie seit #401 auf den per-Campaign-Topic
  # `pipeline_status:<cid>` (das Dashboard abonniert einen pro angezeigter
  # Kampagne, siehe sync_status_subscriptions/2). Pro campaign_id ein MapSet
  # mit den laufenden Stage-Namen. Die HEEx-Card liest per `whisper_active?/2`
  # und `llm_active?/2`.
  def handle_info(
        {:pipeline_status,
         %{"kind" => "pipeline_stage", "campaign_id" => cid, "stage" => stage, "status" => status}},
        socket
      )
      when is_binary(cid) and
             stage in ["stage1", "extract", "verify", "render", "timeline", "render_epos"] do
    {:noreply, update_live_status(socket, cid, stage, status)}
  end

  def handle_info({:pipeline_status, _}, socket), do: {:noreply, socket}

  defp update_live_status(socket, cid, stage, status) do
    update(socket, :live_status, fn map ->
      current = Map.get(map, cid, MapSet.new())

      next =
        case status do
          "started" -> MapSet.put(current, stage)
          _ -> MapSet.delete(current, stage)
        end

      if MapSet.size(next) == 0, do: Map.delete(map, cid), else: Map.put(map, cid, next)
    end)
  end

  @impl true
  def handle_async(:load_campaigns, {:ok, {:ok, snap}}, socket) do
    role = Permissions.parse_role(snap["viewer_role"])

    {:noreply,
     socket
     |> assign(
       waiting?: false,
       campaigns: snap["campaigns"] || [],
       users: snap["users"] || %{},
       viewer_role: role,
       can_create_campaign?: role in [:admin, :spielleiter]
     )
     |> sync_status_subscriptions(snap["campaigns"] || [])
     |> backfill_viewer_user(snap["users"] || %{})}
  end

  def handle_async(:load_campaigns, {:ok, {:error, :no_worker}}, socket) do
    {:noreply,
     socket
     |> assign(
       waiting?: true,
       campaigns: [],
       users: %{},
       viewer_role: :spieler,
       can_create_campaign?: false
     )
     |> sync_status_subscriptions([])}
  end

  def handle_async(:load_campaigns, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> put_flash(:error, "Snapshot-Read fehlgeschlagen: #{inspect(reason)}")
     |> assign(
       waiting?: false,
       campaigns: [],
       users: %{},
       viewer_role: :spieler,
       can_create_campaign?: false
     )
     |> sync_status_subscriptions([])}
  end

  def handle_async(:load_campaigns, {:exit, reason}, socket) do
    Logger.warning("dashboard load_campaigns async exit: #{inspect(reason)}")
    {:noreply, socket}
  end

  defp start_campaigns_load(socket) do
    discord_id = socket.assigns.current_user.discord_id

    start_async(socket, :load_campaigns, fn ->
      Reader.read(%{"kind" => "campaigns_for", "discord_id" => discord_id})
    end)
  end

  # Issue #401: pro angezeigter Kampagne den per-Campaign-pipeline_status-Topic
  # abonnieren (Stage-Dots via handle_info {:pipeline_status, %{"kind" =>
  # "pipeline_stage", ...}}). Diff gegen die bereits abonnierten Topics, damit
  # Reloads (workers_changed/:reload) neue Kampagnen nach-abonnieren und
  # entfallene sauber ab-abonnieren — kein doppeltes Delivery, kein Leak.
  # Nur bei verbundener LiveView (Subscriptions ergeben im statischen Render
  # keinen Sinn); malformte Einträge ohne binäre id werden übersprungen.
  defp sync_status_subscriptions(socket, campaigns) do
    if connected?(socket) do
      old = socket.assigns[:status_topics] || MapSet.new()
      new = MapSet.new(for c <- campaigns, is_binary(c["id"]), do: c["id"])

      Enum.each(MapSet.difference(old, new), fn cid ->
        Phoenix.PubSub.unsubscribe(Hub.PubSub, HubWeb.PipelineStatus.topic(cid))
      end)

      Enum.each(MapSet.difference(new, old), fn cid ->
        Phoenix.PubSub.subscribe(Hub.PubSub, HubWeb.PipelineStatus.topic(cid))
      end)

      assign(socket, :status_topics, new)
    else
      socket
    end
  end

  defp filtered(campaigns, ""), do: campaigns

  defp filtered(campaigns, q) do
    needle = String.downcase(q)
    Enum.filter(campaigns, &String.contains?(String.downcase(&1["name"]), needle))
  end

  # Issue #57: Wenn der Archive-Toggle aus ist, filtern wir archivierte
  # Kampagnen raus. Status kommt vom Worker-Snapshot als String — der vom
  # CampaignArchived-Event geschriebene `:archived`-Atom wird per serialize/1
  # zu "archived".
  defp visible_for_archive(campaigns, true), do: campaigns

  defp visible_for_archive(campaigns, false) do
    Enum.reject(campaigns, fn c -> c["status"] in ["archived", :archived] end)
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
          <.icon_btn icon="bell" label="Benachrichtigungen (kommt später)" phx-click="noop" disabled />
          <div class="flex items-center gap-2 text-ink-1 text-sm">
            <span class="hero-user-circle-solid w-7 h-7 text-accent"></span>
            <span class="hidden lg:inline">{@current_user.display_name}</span>
          </div>
        </div>
      </header>

      <%= if @waiting? do %>
        <Cards.waiting_panel />
      <% else %>
        <div
          id="dashboard-archive-toggle"
          phx-hook="ArchiveTogglePersist"
          class="flex items-center justify-between mb-4"
        >
          <label class="flex items-center gap-2 text-xs text-fg-muted cursor-pointer">
            <input
              type="checkbox"
              checked={@show_archived}
              phx-click="toggle_archived"
              class="accent-primary"
            />
            <span>Archivierte Kampagnen zeigen</span>
          </label>
          <%= if @can_create_campaign? do %>
            <.btn variant="primary" icon="plus" phx-click="open_new_modal">
              Kampagne gründen
            </.btn>
          <% end %>
        </div>

        <%= case @campaigns |> visible_for_archive(@show_archived) |> filtered(@search) do %>
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
                <Cards.campaign_card
                  campaign={c}
                  users={@users}
                  current_user={@current_user}
                  viewer_role={@viewer_role}
                  live_status={@live_status}
                />
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

    <%!-- Issue #270: Delete-Campaign-Modal mit Namens-Bestätigung. --%>
    <%= if @delete_modal do %>
      <div
        class="fixed inset-0 z-50 bg-bg-0/80 flex items-center justify-center p-4"
        phx-window-keydown="delete_modal_cancel"
        phx-key="escape"
      >
        <div class="panel max-w-lg w-full p-6 shadow-glow border border-rec-soft/40" phx-click-away="delete_modal_cancel">
          <div class="flex items-center gap-2 text-rec-soft mb-3">
            <span class="text-xl">⚠</span>
            <h2 class="font-display text-lg tracking-wide">Kampagne unwiderruflich löschen</h2>
          </div>
          <p class="text-sm text-ink-2 mb-4">
            Alle Sessions, Protokolle, Resümees, Epos und Chronik dieser Kampagne werden mit gelöscht.
          </p>
          <form phx-submit="delete_modal_confirm" phx-change="delete_modal_typing" class="space-y-3">
            <label class="block">
              <span class="text-xs text-ink-2">
                Tippe den Kampagnennamen zur Bestätigung:
                <code class="text-rec-soft">{@delete_modal["name"]}</code>
              </span>
              <input
                name="name"
                type="text"
                autofocus
                autocomplete="off"
                value={@delete_modal["typed"]}
                placeholder={@delete_modal["name"]}
                class="mt-1 block w-full bg-bg-0 border border-bg-3 rounded-md px-3 py-2 text-ink-0 font-mono focus:border-accent focus:ring-0"
              />
            </label>
            <div class="flex justify-end gap-2 pt-2">
              <.btn variant="ghost" phx-click="delete_modal_cancel">Abbrechen</.btn>
              <.btn
                variant="danger"
                icon="trash"
                type="submit"
                disabled={String.trim(@delete_modal["typed"] || "") != @delete_modal["name"]}
              >
                Endgültig löschen
              </.btn>
            </div>
          </form>
        </div>
      </div>
    <% end %>

    <%!-- Issue #275: Bearbeiten-Modal (Name + Beschreibung + Bild-Upload). --%>
    <%= if @edit_modal do %>
      <div
        class="fixed inset-0 z-50 bg-bg-0/80 flex items-center justify-center p-4"
        phx-window-keydown="edit_modal_cancel"
        phx-key="escape"
      >
        <div class="panel max-w-lg w-full p-6 shadow-glow" phx-click-away="edit_modal_cancel">
          <h2 class="font-display text-xl tracking-wide mb-4">Kampagne bearbeiten</h2>
          <form phx-submit="edit_modal_save" phx-change="edit_modal_typing" class="space-y-4">
            <label class="block">
              <span class="text-sm text-ink-1">Name</span>
              <input
                name="name"
                type="text"
                required
                autofocus
                value={@edit_modal["name"]}
                class="mt-1 block w-full bg-bg-1 border border-bg-3 rounded-md px-3 py-2 text-ink-0 focus:border-accent focus:ring-0"
              />
            </label>

            <label class="block">
              <span class="text-sm text-ink-1">Beschreibung</span>
              <textarea
                name="theme_blurb"
                rows="3"
                placeholder="z.B. Liebesgeschichte in Verona"
                class="mt-1 block w-full bg-bg-1 border border-bg-3 rounded-md px-3 py-2 text-ink-0 focus:border-accent focus:ring-0"
              ><%= @edit_modal["theme_blurb"] %></textarea>
            </label>

            <div>
              <span class="text-sm text-ink-1 block mb-2">Bild (quadratisch, max 200 KB)</span>
              <div
                id="icon-upload"
                phx-hook="IconUpload"
                phx-update="ignore"
                data-target-input="edit-icon-url"
                class="border-2 border-dashed border-bg-3 rounded p-4 text-center cursor-pointer hover:border-accent transition-colors"
              >
                <%= if @edit_modal["icon_url"] && String.starts_with?(@edit_modal["icon_url"], "data:image/") do %>
                  <img
                    src={@edit_modal["icon_url"]}
                    class="w-24 h-24 mx-auto rounded object-cover"
                    alt=""
                  />
                  <p class="text-xs text-ink-2 mt-2">Klicken oder Datei ziehen, um zu ersetzen</p>
                  <button
                    type="button"
                    phx-click="edit_modal_clear_icon"
                    class="text-xs text-rec-soft hover:underline mt-1"
                  >
                    Bild entfernen
                  </button>
                <% else %>
                  <span class="hero-photo w-8 h-8 mx-auto text-ink-2 block"></span>
                  <p class="text-xs text-ink-2 mt-2">Klicken oder Datei hierher ziehen</p>
                  <p class="text-[10px] text-ink-2/60">JPEG / PNG / WebP — wird auf 512×512 zugeschnitten</p>
                <% end %>
              </div>
              <input
                id="edit-icon-url"
                type="hidden"
                name="icon_url"
                value={@edit_modal["icon_url"] || ""}
              />
            </div>

            <div class="flex justify-end gap-2 pt-2">
              <.btn variant="ghost" phx-click="edit_modal_cancel">Abbrechen</.btn>
              <.btn variant="primary" icon="check" type="submit">Speichern</.btn>
            </div>
          </form>
        </div>
      </div>
    <% end %>

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
              <.btn variant="ghost" phx-click="close_new_modal">Abbrechen</.btn>
              <.btn variant="primary" icon="plus" type="submit">Kampagne gründen</.btn>
            </div>
          </form>
        </div>
      </div>
    <% end %>
    """
  end

  defp backfill_viewer_user(socket, users) do
    user = socket.assigns.current_user
    snap_display = Cards.display_for(user && user.discord_id, users)

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
  # die Campaign / kein Worker überhaupt) → Logger.warning + Self-Message
  # für Flash-Anzeige (Issue #215). Vor #215: silent fail.
  #
  # Issue #613: legitimer lokaler Cold-Fail-Wrapper (Dashboard ist nicht
  # Campaign-gebunden, daher nicht via CampaignLive.Publisher) — Cold-Fail wird
  # geloggt + via Self-Message geflasht, kein silent fail.
  defp bridge_publish(payload) do
    # credo:disable-for-next-line LoreTracker.Credo.Check.RawEventBridgePublish
    case EventBridge.publish(payload) do
      :ok ->
        :ok

      {:error, :no_worker_online} ->
        Logger.warning(
          "DashboardLive.bridge_publish: kein Worker online (kind=#{payload["kind"]})"
        )

        send(self(), {:bridge_publish_failed, payload["kind"]})
        :ok
    end
  end
end
