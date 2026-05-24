defmodule HubWeb.AdminUsersLive do
  @moduledoc """
  Admin-LV (Issue #35, Userverwaltung): Liste aller User auf der Instance
  mit Role-Dropdown + „Zu Kampagne hinzufügen"-Dropdown.

  Permission-Gate: nur sichtbar für globale Rolle `:admin`. Non-admins
  werden in `mount/3` zum Dashboard redirected mit Flash.

  Datenquelle: `Hub.Reader.read(%{"kind" => "all_users"})` → der Worker
  liefert sowohl `users` (alle worker_users-rows mit role) als auch
  `campaigns` (alle worker_campaigns-rows, für das Add-Dropdown).
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

    socket =
      socket
      |> assign(:current_user, user)
      |> assign(:active_nav, :admin)
      |> assign(:current_campaign, nil)
      |> load_data()

    cond do
      socket.assigns[:no_worker?] ->
        {:ok, socket}

      not Permissions.can?(socket.assigns.perm_user, :view_admin) ->
        {:ok,
         socket
         |> put_flash(:error, "Admin-Bereich — kein Zugriff.")
         |> push_navigate(to: ~p"/")}

      true ->
        {:ok, socket}
    end
  end

  @impl true
  def handle_event("set_role", %{"discord_id" => did, "role" => role}, socket) do
    if Permissions.can?(socket.assigns.perm_user, :view_admin) do
      bridge_publish(%{
        "kind" => Shared.Events.user_role_set(),
        "discord_id" => did,
        "role" => role,
        "set_by" => socket.assigns.current_user.discord_id
      })
    end

    {:noreply, socket}
  end

  def handle_event(
        "add_to_campaign",
        %{"discord_id" => did, "campaign_id" => cid} = _params,
        socket
      ) do
    if Permissions.can?(socket.assigns.perm_user, :view_admin) and cid != "" do
      display_name =
        Enum.find_value(socket.assigns.users, did, fn u ->
          if u["discord_id"] == did, do: u["display_name"], else: nil
        end)

      bridge_publish(%{
        "kind" => Shared.Events.admin_member_added(),
        "campaign_id" => cid,
        "discord_id" => did,
        "display_name" => display_name,
        "added_by" => socket.assigns.current_user.discord_id
      })

      {:noreply, put_flash(socket, :info, "#{display_name} zu Kampagne hinzugefügt.")}
    else
      {:noreply, socket}
    end
  end

  # Issue #154 (Etappe 4c.3): Hub-LV erzeugt Events nicht mehr direkt — der
  # gewählte Worker materialisiert + sync zurück. Cold-Fail (kein passender
  # Worker online) wird nur geloggt; UserRoleSet/AdminMemberAdded sind selten
  # genug, dass das im Fehlerfall ein Admin-Retry verträgt.
  defp bridge_publish(payload) do
    case EventBridge.publish(payload) do
      :ok ->
        :ok

      {:error, :no_worker_online} ->
        Logger.warning(
          "AdminUsersLive.bridge_publish: kein Worker online (kind=#{payload["kind"]})"
        )

        :ok
    end
  end

  @impl true
  def handle_info({:event_appended, %{payload: %{"kind" => kind}}}, socket)
      when kind in [
             "UserRoleSet",
             "AdminMemberAdded",
             "UserUpserted",
             "CampaignCreated",
             "CampaignDeleted"
           ] do
    Process.send_after(self(), :reload, 150)
    {:noreply, socket}
  end

  def handle_info({:event_appended, _}, socket), do: {:noreply, socket}
  def handle_info(:reload, socket), do: {:noreply, load_data(socket)}

  def handle_info({:workers_changed, _, _}, socket), do: {:noreply, load_data(socket)}

  defp load_data(socket) do
    user = socket.assigns.current_user

    case Reader.read(%{"kind" => "all_users"}) do
      {:ok, snap} ->
        users = snap["users"] || []
        campaigns = snap["campaigns"] || []

        viewer_role =
          Enum.find_value(users, :spieler, fn u ->
            if u["discord_id"] == user.discord_id, do: String.to_atom(u["role"]), else: nil
          end)

        perm_user = %{discord_id: user.discord_id, role: viewer_role, is_member?: true}

        socket
        |> assign(
          no_worker?: false,
          users: users,
          campaigns: campaigns,
          perm_user: perm_user,
          viewer_role: viewer_role
        )

      {:error, :no_worker} ->
        socket
        |> assign(
          no_worker?: true,
          users: [],
          campaigns: [],
          perm_user: %{discord_id: user.discord_id, role: :spieler, is_member?: false},
          viewer_role: :spieler
        )

      {:error, reason} ->
        socket
        |> put_flash(:error, "Snapshot fehlgeschlagen: #{inspect(reason)}")
        |> assign(
          no_worker?: false,
          users: [],
          campaigns: [],
          perm_user: %{discord_id: user.discord_id, role: :spieler, is_member?: false},
          viewer_role: :spieler
        )
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="px-8 py-6 max-w-5xl">
      <header class="mb-6">
        <h1 class="font-display text-2xl tracking-wide">Admin — Userverwaltung</h1>
        <p class="text-ink-2 text-sm mt-1">
          Globale Rollen + Kampagnen-Zuweisungen. Nur für Admins sichtbar.
        </p>
      </header>

      <%= if @no_worker? do %>
        <div class="panel p-8 text-center text-ink-2">
          Kein Worker connected — keine User-Daten verfügbar.
        </div>
      <% else %>
        <%= if @users == [] do %>
          <div class="panel p-8 text-center text-ink-2">
            Keine User auf dieser Instance.
          </div>
        <% else %>
          <div class="panel p-0 overflow-x-auto">
            <table class="w-full text-sm">
              <thead class="text-fg-muted text-xs uppercase tracking-widest border-b border-border">
                <tr>
                  <th class="text-left px-4 py-3">User</th>
                  <th class="text-left px-4 py-3">Discord-ID</th>
                  <th class="text-left px-4 py-3">Globale Rolle</th>
                  <th class="text-left px-4 py-3">Zu Kampagne hinzufügen</th>
                </tr>
              </thead>
              <tbody>
                <%= for u <- @users do %>
                  <tr class="border-b border-border last:border-0 hover:bg-surface-2/40">
                    <td class="px-4 py-3 text-fg">
                      <div class="flex items-center gap-3">
                        <.avatar initials={initials_for(u["display_name"])} size="md" />
                        <span>{u["display_name"]}</span>
                      </div>
                    </td>
                    <td class="px-4 py-3 text-fg-muted font-mono text-xs">{u["discord_id"]}</td>
                    <td class="px-4 py-3">
                      <form phx-change="set_role">
                        <input type="hidden" name="discord_id" value={u["discord_id"]} />
                        <select
                          name="role"
                          class="bg-bg border border-border rounded px-2 py-1 text-xs text-fg focus:border-primary focus:ring-0"
                        >
                          <%= for r <- ["admin", "spielleiter", "spieler"] do %>
                            <option value={r} selected={u["role"] == r}>{r}</option>
                          <% end %>
                        </select>
                      </form>
                    </td>
                    <td class="px-4 py-3">
                      <%= if @campaigns == [] do %>
                        <span class="text-fg-muted/70 text-xs italic">keine Kampagnen</span>
                      <% else %>
                        <form phx-change="add_to_campaign">
                          <input type="hidden" name="discord_id" value={u["discord_id"]} />
                          <select
                            name="campaign_id"
                            class="bg-bg border border-border rounded px-2 py-1 text-xs text-fg focus:border-primary focus:ring-0"
                          >
                            <option value="">— wählen —</option>
                            <%= for c <- @campaigns do %>
                              <option value={c["id"]}>{c["name"]}</option>
                            <% end %>
                          </select>
                        </form>
                      <% end %>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        <% end %>

      <% end %>
    </div>
    """
  end
end
