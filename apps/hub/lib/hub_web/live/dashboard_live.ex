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
      # Issue #249: Stage-1 (Whisper) + Stage-2-4 (LLM) Live-Status für die
      # Card-Dots. Worker pusht pipeline_stage-Events auf dieses Topic.
      Phoenix.PubSub.subscribe(Hub.PubSub, "pipeline_status")
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
     # Issue #57: default-off Toggle für archivierte Kampagnen. Wird via
     # LocalStorage-Hook persistiert (siehe ArchiveTogglePersist hook).
     |> assign(:show_archived, false)
     |> load_campaigns()}
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

            cond do
              name == "" ->
                {:noreply, put_flash(socket, :error, "Name darf nicht leer sein.")}

              not valid_icon_url?(icon) ->
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
    do: {:noreply, load_campaigns(socket)}

  # Issue #249: Stage-Status-Stream. Worker pusht pipeline_stage-Events,
  # WorkerChannel broadcastet sie auf Hub.PubSub `"pipeline_status"`. Pro
  # campaign_id ein MapSet mit den gerade laufenden Stage-Namen. Die HEEx-
  # Card liest per `whisper_active?/2` und `llm_active?/2`.
  def handle_info(
        {:pipeline_status,
         %{"kind" => "pipeline_stage", "campaign_id" => cid, "stage" => stage, "status" => status}},
        socket
      )
      when is_binary(cid) and stage in ["stage1", "stage2", "stage3", "stage4"] do
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

  defp load_campaigns(socket) do
    scope = %{"kind" => "campaigns_for", "discord_id" => socket.assigns.current_user.discord_id}

    case Reader.read(scope) do
      {:ok, snap} ->
        role = parse_viewer_role(snap["viewer_role"])

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

  # Issue #57: Wenn der Archive-Toggle aus ist, filtern wir archivierte
  # Kampagnen raus. Status kommt vom Worker-Snapshot als String — der vom
  # CampaignArchived-Event geschriebene `:archived`-Atom wird per serialize/1
  # zu "archived".
  defp visible_for_archive(campaigns, true), do: campaigns

  defp visible_for_archive(campaigns, false) do
    Enum.reject(campaigns, fn c -> c["status"] in ["archived", :archived] end)
  end

  defp parse_viewer_role("admin"), do: :admin
  defp parse_viewer_role("spielleiter"), do: :spielleiter
  defp parse_viewer_role("spieler"), do: :spieler
  defp parse_viewer_role(_), do: :spieler

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
        <.waiting_panel />
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
                <.campaign_card
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
        can_edit?:
          can_edit_campaign?(assigns.current_user, assigns.viewer_role, assigns.campaign),
        can_delete?:
          can_delete_campaign?(assigns.current_user, assigns.viewer_role, assigns.campaign),
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

  # Issue #275: Icon-Render-Helper. Data-URI im icon_url → Bild,
  # sonst Heroicon-Fallback. Defensive Klausel für unbekannte Schemes.
  defp campaign_icon(%{"icon_url" => "data:image/" <> _ = data_uri}), do: {:img, data_uri}
  defp campaign_icon(_), do: {:heroicon, "hero-book-open"}

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

  # Issue #249: Whisper (Stage 1) — cyan-pulsierend solange Worker
  # transkribiert.
  attr(:active, :boolean, default: false)

  defp whisper_dot(%{active: true} = assigns) do
    ~H"""
    <span
      class="inline-block w-2 h-2 rounded-full bg-sky-400 animate-pulse"
      title="Whisper transkribiert"
    ></span>
    """
  end

  defp whisper_dot(assigns), do: ~H""

  # Issue #249: LLM-Pipeline (Stage 2/3/4) — grün-pulsierend solange eine
  # der Stages 2/3/4 läuft.
  attr(:active, :boolean, default: false)

  defp llm_dot(%{active: true} = assigns) do
    ~H"""
    <span
      class="inline-block w-2 h-2 rounded-full bg-emerald-400 animate-pulse"
      title="LLM-Pipeline läuft"
    ></span>
    """
  end

  defp llm_dot(assigns), do: ~H""

  defp whisper_active?(live_status, cid) do
    case Map.get(live_status, cid) do
      nil -> false
      stages -> MapSet.member?(stages, "stage1")
    end
  end

  defp llm_active?(live_status, cid) do
    case Map.get(live_status, cid) do
      nil ->
        false

      stages ->
        Enum.any?(["stage2", "stage3", "stage4"], &MapSet.member?(stages, &1))
    end
  end

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
  # die Campaign / kein Worker überhaupt) → Logger.warning + Self-Message
  # für Flash-Anzeige (Issue #215). Vor #215: silent fail.
  defp bridge_publish(payload) do
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

  defp status_pill("active"), do: "pill-active"
  defp status_pill("archived"), do: "pill-archived"
  defp status_pill(_), do: "pill-new"

  # Issue #474: campaign_role muss aus den Members aufgelöst werden (analog
  # can_delete_campaign?/can_edit_campaign?), sonst sieht ein per-Campaign-
  # Spielleiter OHNE globale SL/Admin-Rolle den Einladen-Button NICHT — obwohl
  # er einladen darf (der create_invite-Handler gated korrekt via build_perm_user).
  # Vorher: perm_user ohne :campaign_role + nur %{owner_discord_id} → can?
  # (prüft campaign_role == :spielleiter) fiel immer auf false.
  defp can_invite_campaign?(user, role, campaign) do
    Permissions.can?(
      perm_user_for_card(user, role, campaign),
      :invite_to_campaign,
      campaign
    )
  end

  # Issue #270: Per-Campaign-Spielleiter oder globaler Admin darf löschen.
  # campaign_role wird aus members abgeleitet (analog build_perm_user/2),
  # damit `:delete_campaign` per HubWeb.Permissions korrekt fällt.
  defp can_delete_campaign?(user, role, campaign) do
    Permissions.can?(
      perm_user_for_card(user, role, campaign),
      :delete_campaign,
      campaign
    )
  end

  # Issue #275: Edit-Permission gleich gelagert wie Delete — Per-Campaign-
  # Spielleiter oder Admin. `:edit_summary` ist der Standard-GM-Action-Atom.
  defp can_edit_campaign?(user, role, campaign) do
    Permissions.can?(
      perm_user_for_card(user, role, campaign),
      :edit_summary,
      campaign
    )
  end

  defp perm_user_for_card(user, role, campaign) do
    me = user.discord_id

    campaign_role =
      case Enum.find(campaign["members"] || [], &(&1["discord_id"] == me)) do
        %{"role" => "spielleiter"} -> :spielleiter
        %{"role" => "owner"} -> :spielleiter
        %{"role" => "spieler"} -> :spieler
        %{"role" => "player"} -> :spieler
        _ -> nil
      end

    %{discord_id: me, role: role, campaign_role: campaign_role}
  end

  defp card_active_invites(campaign) do
    (campaign["active_invites"] || [])
    |> Enum.filter(&(&1["status"] == "active"))
  end

  defp short_invite_path(token), do: "/invite/#{String.slice(token, 0, 8)}…"
  defp full_invite_url(token), do: HubWeb.Endpoint.url() <> "/invite/#{token}"
end
