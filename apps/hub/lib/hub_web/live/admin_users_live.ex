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

  # Issue #178: Spend-Cap pro User (USD/Monat). Leerer String / "0" / "none"
  # → nil = kein Cap. Sonst Float parsen.
  def handle_event("set_spend_cap", %{"discord_id" => did, "cap_usd" => raw}, socket) do
    if Permissions.can?(socket.assigns.perm_user, :view_admin) do
      cap_usd = parse_cap_input(raw)

      bridge_publish(%{
        "kind" => Shared.Events.user_spend_cap_changed(),
        "discord_id" => did,
        "cap_usd" => cap_usd,
        "changed_by" => socket.assigns.current_user.discord_id
      })

      label =
        case cap_usd do
          nil -> "Cap entfernt (unbegrenzt)"
          n -> "Cap: $#{n}/Monat"
        end

      {:noreply, put_flash(socket, :info, "#{did}: #{label}")}
    else
      {:noreply, socket}
    end
  end

  defp parse_cap_input(raw) when is_binary(raw) do
    case String.trim(raw) do
      "" ->
        nil

      "0" ->
        nil

      str ->
        case Float.parse(str) do
          {f, _} when f > 0 -> f
          _ -> nil
        end
    end
  end

  defp parse_cap_input(_), do: nil

  # Issue #56: Multi-Campaign-Add via `<select multiple>` + Submit. Backend
  # emittiert n separate AdminMemberAdded-Events (Materializer ist idempotent,
  # ein Event pro Membership ist sauber im Audit-Log).
  def handle_event(
        "add_to_campaigns",
        %{"discord_id" => did} = params,
        socket
      ) do
    if Permissions.can?(socket.assigns.perm_user, :view_admin) do
      campaign_ids =
        params
        |> Map.get("campaign_ids", [])
        |> List.wrap()
        |> Enum.reject(&(&1 == "" or is_nil(&1)))

      if campaign_ids == [] do
        {:noreply, put_flash(socket, :error, "Mindestens eine Kampagne auswählen.")}
      else
        display_name =
          Enum.find_value(socket.assigns.users, did, fn u ->
            if u["discord_id"] == did, do: u["display_name"], else: nil
          end)

        Enum.each(campaign_ids, fn cid ->
          bridge_publish(%{
            "kind" => Shared.Events.admin_member_added(),
            "campaign_id" => cid,
            "discord_id" => did,
            "display_name" => display_name,
            "added_by" => socket.assigns.current_user.discord_id
          })
        end)

        campaign_names =
          campaign_ids
          |> Enum.map(fn cid ->
            Enum.find_value(socket.assigns.campaigns, cid, fn c ->
              if c["id"] == cid, do: c["name"], else: nil
            end)
          end)
          |> Enum.join(", ")

        {:noreply,
         put_flash(
           socket,
           :info,
           "#{display_name} zu #{length(campaign_ids)} Kampagne(n) hinzugefügt: #{campaign_names}"
         )}
      end
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
            if u["discord_id"] == user.discord_id, do: parse_role(u["role"]), else: nil
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

  defp parse_role("admin"), do: :admin
  defp parse_role("spielleiter"), do: :spielleiter
  defp parse_role("spieler"), do: :spieler
  defp parse_role(_), do: :spieler

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
                  <th class="text-left px-4 py-3" title="Per-User-Cap pro Monat (Issue #178). Leer = unbegrenzt.">Cap $/Monat</th>
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
                      <form phx-submit="set_spend_cap" class="flex items-center gap-2">
                        <input type="hidden" name="discord_id" value={u["discord_id"]} />
                        <input
                          type="number"
                          name="cap_usd"
                          value={u["monthly_spend_cap_usd"]}
                          step="0.01"
                          min="0"
                          placeholder="∞"
                          title="USD pro Monat. Leer / 0 = kein Cap (unbegrenzt)."
                          class="bg-bg border border-border rounded px-2 py-1 text-xs text-fg focus:border-primary focus:ring-0 w-20"
                        />
                        <.icon_btn icon="check" label="Speichern" type="submit" />
                      </form>
                    </td>
                    <td class="px-4 py-3">
                      <%= if @campaigns == [] do %>
                        <span class="text-fg-muted/70 text-xs italic">keine Kampagnen</span>
                      <% else %>
                        <form phx-submit="add_to_campaigns" class="flex items-start gap-2">
                          <input type="hidden" name="discord_id" value={u["discord_id"]} />
                          <select
                            name="campaign_ids[]"
                            multiple
                            size={min(length(@campaigns), 4)}
                            class="bg-bg border border-border rounded px-2 py-1 text-xs text-fg focus:border-primary focus:ring-0 min-w-[140px]"
                            title="Strg/Cmd + Klick für Mehrfachauswahl"
                          >
                            <%= for c <- @campaigns do %>
                              <option value={c["id"]}>{c["name"]}</option>
                            <% end %>
                          </select>
                          <.btn variant="primary" icon="plus" type="submit">
                            Hinzufügen
                          </.btn>
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
