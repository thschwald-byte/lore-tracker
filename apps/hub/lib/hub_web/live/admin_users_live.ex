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

  alias Hub.{Commands, EventBridge, Events, Reader}
  alias HubWeb.Permissions
  alias Shared.Events, as: EventKinds
  require Logger

  # Issue #569: Modul-Attribut für event-kind-Match im handle_info-Head
  # (Iron-Law #8 — kein Remote-Call im Guard).
  @reload_trigger_kinds [
    EventKinds.user_role_set(),
    EventKinds.admin_member_added(),
    EventKinds.user_upserted(),
    EventKinds.campaign_created(),
    EventKinds.campaign_deleted()
  ]

  @impl true
  def mount(_params, %{"current_user" => user}, socket) do
    # Issue #474: Gate-first über current_user_role (SidebarContext-on_mount),
    # fail-closed. Vorher fail-degraded via sync-Read-abgeleiteter Rolle.
    perm_user = Permissions.admin_perm_user(user, socket.assigns[:current_user_role])

    if Permissions.can?(perm_user, :view_admin) do
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Hub.PubSub, Events.topic())
        Phoenix.PubSub.subscribe(Hub.PubSub, Hub.WorkerRegistry.topic())
      end

      {:ok,
       socket
       |> assign(:current_user, user)
       |> assign(:perm_user, perm_user)
       |> assign(:active_nav, :admin)
       |> assign(:current_campaign, nil)
       # Issue #57: Multi-Stage Delete-Modal
       |> assign(:delete_state, nil)
       |> assign(no_worker?: false, users: [], campaigns: [])
       |> start_data_load()}
    else
      {:ok,
       socket
       |> put_flash(:error, "Admin-Bereich — kein Zugriff.")
       |> push_navigate(to: ~p"/")}
    end
  end

  # Issue #430: Helfer vor den handle_event-Block gezogen (waren dazwischen →
  # „clauses should be grouped together").
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

  defp all_resolved?(sl_campaigns, resolution) do
    Enum.all?(sl_campaigns, fn c -> Map.has_key?(resolution, c["id"]) end)
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

  # ─── Issue #57: User-Delete-Flow ────────────────────────────────────
  # 3 Stufen:
  #   delete_state == nil                                   → kein Modal sichtbar
  #   delete_state == %{stage: :preview, ...}               → Stage 1: Übersicht
  #   delete_state == %{stage: :resolve_sl, resolution, ..} → Stage 2: Last-SL-Picker
  #   delete_state == %{stage: :confirm, typed, ...}        → Stage 3: Name-Confirm

  def handle_event("delete_user_open", %{"discord_id" => target_did}, socket) do
    if not Permissions.can?(socket.assigns.perm_user, :view_admin) do
      {:noreply, socket}
    else
      cond do
        target_did == socket.assigns.current_user.discord_id ->
          {:noreply, put_flash(socket, :error, "Du kannst dich nicht selbst löschen.")}

        true ->
          # Issue #366: prefer_discord_id für deterministisches Worker-Routing.
          did = socket.assigns.current_user.discord_id

          {:noreply,
           socket
           |> assign(:delete_state, %{stage: :loading_preview, target_did: target_did})
           |> start_async(:load_delete_preview, fn ->
             Reader.read(
               %{"kind" => "user_delete_preview", "discord_id" => target_did},
               prefer_discord_id: did
             )
           end)}
      end
    end
  end

  def handle_event("delete_user_cancel", _params, socket),
    do: {:noreply, assign(socket, :delete_state, nil)}

  # Pro Last-SL-Kampagne: User wählt entweder einen Spieler zum Promoten oder
  # "archivieren". Wir tracken die Auswahl in resolution-Map; erst wenn alle
  # Last-SL-Kampagnen entschieden sind, geht Stage 2 → Stage 3.
  def handle_event(
        "delete_user_resolve",
        %{"campaign_id" => cid, "action" => action} = params,
        socket
      ) do
    state = socket.assigns.delete_state
    resolution = state.resolution

    entry =
      case action do
        "promote" -> {:promote, params["promote_did"]}
        "archive" -> :archive
        _ -> :unset
      end

    resolution =
      if entry == :unset,
        do: Map.delete(resolution, cid),
        else: Map.put(resolution, cid, entry)

    {:noreply, assign(socket, :delete_state, %{state | resolution: resolution})}
  end

  def handle_event("delete_user_resolve_next", _params, socket) do
    state = socket.assigns.delete_state
    sl_campaigns = state.preview["last_sl_campaigns"] || []

    cond do
      not all_resolved?(sl_campaigns, state.resolution) ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Bitte für jede Kampagne eine Auswahl treffen (Promote oder Archive)."
         )}

      true ->
        # Resolution-Events publishen — sequentially, so the Materializer sieht sie
        # vor dem finalen UserDeleted.
        #
        # Issue #613: Return prüfen statt ignorieren. Bei :no_worker_online
        # (kein Worker online) würden die Resolutions still verschwinden, der
        # Flow ginge trotzdem nach :confirm → ein nachfolgendes UserDeleted
        # könnte eine Kampagne ohne letzten Spielleiter zurücklassen (#57-
        # Lockout). Darum: schlägt eine Resolution fehl, NICHT nach :confirm,
        # sondern Flash + im resolve-Stage bleiben (Admin kann retryen; die
        # Resolution-Events sind idempotent).
        results =
          Enum.map(sl_campaigns, fn c ->
            case Map.get(state.resolution, c["id"]) do
              {:promote, promote_did} when is_binary(promote_did) ->
                bridge_publish(%{
                  "kind" => Shared.Events.member_role_promoted(),
                  "campaign_id" => c["id"],
                  "discord_id" => promote_did,
                  "role" => "spielleiter",
                  "set_by" => socket.assigns.current_user.discord_id
                })

              :archive ->
                bridge_publish(%{
                  "kind" => Shared.Events.campaign_archived(),
                  "campaign_id" => c["id"],
                  "archived_by" => socket.assigns.current_user.discord_id,
                  "reason" => "owner_deleted"
                })

              _ ->
                :ok
            end
          end)

        if Enum.all?(results, &(&1 == :ok)) do
          {:noreply, assign(socket, :delete_state, %{state | stage: :confirm})}
        else
          {:noreply,
           put_flash(
             socket,
             :error,
             "Resolution konnte nicht angewendet werden (kein Worker online). " <>
               "Bitte erneut versuchen — der Delete wurde NICHT fortgesetzt."
           )}
        end
    end
  end

  def handle_event("delete_user_type", %{"typed" => typed}, socket) do
    state = socket.assigns.delete_state
    {:noreply, assign(socket, :delete_state, %{state | typed: typed})}
  end

  def handle_event("delete_user_confirm", _params, socket) do
    state = socket.assigns.delete_state
    target_did = state.target_did
    display_name = get_in(state, [:preview, "user", "display_name"]) || target_did

    cond do
      state.typed != display_name ->
        {:noreply, put_flash(socket, :error, "Name stimmt nicht überein — bitte erneut tippen.")}

      true ->
        case Commands.request_user_delete(socket.assigns.current_user.discord_id, target_did) do
          :ok ->
            {:noreply,
             socket
             |> assign(:delete_state, nil)
             |> put_flash(:info, "#{display_name} gelöscht.")}

          {:error, :cannot_delete_self} ->
            {:noreply, put_flash(socket, :error, "Du kannst dich nicht selbst löschen.")}

          {:error, :last_admin} ->
            {:noreply, put_flash(socket, :error, "Letzter Admin — kann nicht gelöscht werden.")}

          {:error, {:unresolved_last_sl, ids}} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "Kampagnen #{Enum.join(ids, ", ")} brauchen noch eine Resolution (jemand anders ist demoted oder hat zwischenzeitlich gehandelt). Bitte Delete-Dialog neu öffnen."
             )
             |> assign(:delete_state, nil)}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Delete fehlgeschlagen: #{inspect(reason)}")}
        end
    end
  end

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
  # gewählte Worker materialisiert + sync zurück.
  #
  # Lokaler Cold-Fail-Wrapper (Admin-Äquivalent zu CampaignLive.Publisher,
  # das LiveView-spezifisch + Campaign-gebunden ist): loggt bei
  # :no_worker_online UND gibt das Resultat zurück. Issue #613: der Delete-
  # Resolution-Pfad prüft den Return (Abbruch statt stillem GM-Lockout); der
  # add_to_campaigns-Pfad ignoriert ihn bewusst (selten, Admin-Retry verträglich
  # — Kommentar dort).
  defp bridge_publish(payload) do
    # bridge_publish/1 IST der lokale Cold-Fail-Wrapper (s.o.) — der eine
    # legitime rohe EventBridge.publish-Call der Admin-LV.
    # credo:disable-for-next-line LoreTracker.Credo.Check.RawEventBridgePublish
    case EventBridge.publish(payload) do
      :ok ->
        :ok

      {:error, :no_worker_online} = err ->
        Logger.warning(
          "AdminUsersLive.bridge_publish: kein Worker online (kind=#{payload["kind"]})"
        )

        err
    end
  end

  @impl true
  def handle_info({:event_appended, %{payload: %{"kind" => kind}}}, socket)
      when kind in @reload_trigger_kinds do
    # Issue #569: PID-targeted Debounce — BEAM räumt pending send_after beim
    # Prozess-Tod auf (https://www.erlang.org/doc/system/ref_man_processes.html).
    # Mehrfache event_appended in <150ms queuen mehrere :reload-Messages,
    # die start_async je einen no-op-Reload triggern (idempotent).
    # credo:disable-for-next-line LoreTracker.Credo.Check.TimerWithoutCleanup
    Process.send_after(self(), :reload, 150)
    {:noreply, socket}
  end

  def handle_info({:event_appended, _}, socket), do: {:noreply, socket}

  # Issue #702: gebatchte Events durch die event_appended-Klauseln falten.
  def handle_info({:events_batch, events}, socket),
    do: HubWeb.Live.EventsBatch.fold(events, socket, &handle_info/2)

  def handle_info(:reload, socket), do: {:noreply, start_data_load(socket)}

  def handle_info({:workers_changed, _, _}, socket), do: {:noreply, start_data_load(socket)}

  @impl true
  def handle_async(:load_data, {:ok, {:ok, snap}}, socket) do
    {:noreply,
     assign(socket,
       no_worker?: false,
       users: snap["users"] || [],
       campaigns: snap["campaigns"] || []
     )}
  end

  def handle_async(:load_data, {:ok, {:error, :no_worker}}, socket) do
    {:noreply, assign(socket, no_worker?: true, users: [], campaigns: [])}
  end

  def handle_async(:load_data, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> put_flash(:error, "Snapshot fehlgeschlagen: #{inspect(reason)}")
     |> assign(no_worker?: false, users: [], campaigns: [])}
  end

  def handle_async(:load_data, {:exit, reason}, socket) do
    Logger.warning("admin_users load_data async exit: #{inspect(reason)}")
    {:noreply, socket}
  end

  def handle_async(:load_delete_preview, {:ok, {:ok, %{"last_admin" => true} = preview}}, socket) do
    state = socket.assigns.delete_state
    target_did = state && state.target_did

    user =
      preview["user"] ||
        %{"discord_id" => target_did, "display_name" => target_did || "?"}

    {:noreply,
     socket
     |> assign(:delete_state, nil)
     |> put_flash(
       :error,
       "#{user["display_name"]} ist der einzige Admin — kann nicht gelöscht werden."
     )}
  end

  def handle_async(:load_delete_preview, {:ok, {:ok, preview}}, socket) do
    state = socket.assigns.delete_state
    target_did = state && state.target_did

    stage =
      if (preview["last_sl_campaigns"] || []) == [], do: :confirm, else: :resolve_sl

    {:noreply,
     assign(socket, :delete_state, %{
       stage: stage,
       target_did: target_did,
       preview: preview,
       resolution: %{},
       typed: ""
     })}
  end

  def handle_async(:load_delete_preview, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:delete_state, nil)
     |> put_flash(:error, "Preview fehlgeschlagen: #{inspect(reason)}")}
  end

  def handle_async(:load_delete_preview, {:exit, reason}, socket) do
    Logger.warning("admin_users load_delete_preview async exit: #{inspect(reason)}")
    {:noreply, assign(socket, :delete_state, nil)}
  end

  # Issue #474: lädt NUR Daten — perm_user/Rolle kommen aus dem Gate
  # (current_user_role), nicht mehr aus diesem all_users-Read abgeleitet.
  # Issue #366: prefer_discord_id für deterministisches Worker-Routing.
  defp start_data_load(socket) do
    did = socket.assigns.current_user.discord_id

    start_async(socket, :load_data, fn ->
      Reader.read(%{"kind" => "all_users"}, prefer_discord_id: did)
    end)
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
                  <th class="text-left px-4 py-3" title="Per-User-Cap pro Monat (Issue #178). Leer = unbegrenzt.">Cap $/Monat</th>
                  <th class="text-left px-4 py-3">Zu Kampagne hinzufügen</th>
                  <th class="text-right px-4 py-3">Löschen</th>
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
                    <td class="px-4 py-3 text-right">
                      <%= if u["discord_id"] == @current_user.discord_id do %>
                        <span class="text-fg-muted/70 text-xs italic" title="Du kannst dich nicht selbst löschen.">—</span>
                      <% else %>
                        <.icon_btn
                          icon="trash"
                          label="User löschen"
                          variant="danger"
                          phx-click="delete_user_open"
                          phx-value-discord_id={u["discord_id"]}
                        />
                      <% end %>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        <% end %>

      <% end %>

      <%= if @delete_state do %>
        <.delete_user_modal delete_state={@delete_state} />
      <% end %>
    </div>
    """
  end

  # Issue #57: 3-Stage Delete-Modal als HEEx-Component innerhalb der LV.
  # Issue #569: Preview-Read läuft async (start_async), während der Lade-Phase
  # rendert die :loading_preview-Klausel ein dezentes Loading-Modal — der User
  # sieht direkt nach dem Klick, dass etwas passiert.
  attr(:delete_state, :map, required: true)

  defp delete_user_modal(%{delete_state: %{stage: :loading_preview}} = assigns) do
    ~H"""
    <.lt_modal on_close="delete_user_cancel">
      <header class="mb-4">
        <h2 class="font-display text-lg">User löschen…</h2>
        <p class="text-fg-muted text-xs font-mono mt-1">{@delete_state.target_did}</p>
      </header>
      <p class="py-8 text-center text-fg-muted text-sm italic">Preview lädt…</p>
    </.lt_modal>
    """
  end

  defp delete_user_modal(assigns) do
    user =
      assigns.delete_state.preview["user"] ||
        %{
          "display_name" => assigns.delete_state.target_did,
          "discord_id" => assigns.delete_state.target_did
        }

    sl_campaigns = assigns.delete_state.preview["last_sl_campaigns"] || []
    assigns = assign(assigns, user: user, sl_campaigns: sl_campaigns)

    ~H"""
    <.lt_modal on_close="delete_user_cancel">
      <header class="mb-4">
        <h2 class="font-display text-lg">User löschen: {@user["display_name"]}</h2>
        <p class="text-fg-muted text-xs font-mono mt-1">{@user["discord_id"]}</p>
      </header>

        <%= case @delete_state.stage do %>
          <% :resolve_sl -> %>
            <div class="space-y-4">
              <p class="text-sm text-fg-muted">
                Der User ist letzter Spielleiter von <strong>{length(@sl_campaigns)} Kampagne(n)</strong>.
                Bitte pro Kampagne entscheiden: neuen Spielleiter aus den Spielern befördern, oder die Kampagne archivieren.
              </p>
              <%= for c <- @sl_campaigns do %>
                <div class="border border-border rounded p-3 space-y-2">
                  <div class="font-medium text-sm">{c["name"]}</div>
                  <%= if (c["members"] || []) == [] do %>
                    <p class="text-fg-muted text-xs italic">Keine Spieler in dieser Kampagne — nur Archivieren möglich.</p>
                    <button
                      type="button"
                      class="text-xs px-3 py-1 rounded border border-border hover:bg-surface-2"
                      phx-click="delete_user_resolve"
                      phx-value-campaign_id={c["id"]}
                      phx-value-action="archive"
                    >
                      <%= if Map.get(@delete_state.resolution, c["id"]) == :archive do %>
                        ✓ Archivieren
                      <% else %>
                        Archivieren
                      <% end %>
                    </button>
                  <% else %>
                    <form phx-change="delete_user_resolve" class="flex items-center gap-2 text-xs">
                      <input type="hidden" name="campaign_id" value={c["id"]} />
                      <select name="action" class="bg-bg border border-border rounded px-2 py-1">
                        <option value="" selected={not Map.has_key?(@delete_state.resolution, c["id"])}>— wählen —</option>
                        <option value="promote" selected={match?({:promote, _}, Map.get(@delete_state.resolution, c["id"]))}>Spieler befördern</option>
                        <option value="archive" selected={Map.get(@delete_state.resolution, c["id"]) == :archive}>Kampagne archivieren</option>
                      </select>
                      <%= if match?({:promote, _}, Map.get(@delete_state.resolution, c["id"])) or get_in(@delete_state.resolution, [c["id"]]) == nil do %>
                        <select name="promote_did" class="bg-bg border border-border rounded px-2 py-1">
                          <option value="">— Spieler wählen —</option>
                          <%= for m <- c["members"] || [] do %>
                            <option value={m["discord_id"]} selected={Map.get(@delete_state.resolution, c["id"]) == {:promote, m["discord_id"]}}>
                              {m["display_name"]}
                            </option>
                          <% end %>
                        </select>
                      <% end %>
                    </form>
                  <% end %>
                </div>
              <% end %>
              <div class="flex justify-end gap-2 mt-4">
                <.btn variant="ghost" phx-click="delete_user_cancel">Abbrechen</.btn>
                <.btn variant="primary" phx-click="delete_user_resolve_next">Weiter</.btn>
              </div>
            </div>
          <% :confirm -> %>
            <div class="space-y-3">
              <p class="text-sm text-fg-muted">
                Damit wird der User komplett von dieser Instance entfernt. Alle Kampagnen-Mitgliedschaften werden getombstoned, der User-Eintrag hart gelöscht.
              </p>
              <p class="text-sm text-fg-muted">
                Utterances, Sessions und Marker bleiben erhalten (Audit-Trail) — die UI rendert sie als <em>[gelöschter User]</em>.
              </p>
              <form phx-change="delete_user_type" phx-submit="delete_user_confirm" class="space-y-2">
                <label class="block text-xs text-fg-muted">
                  Zur Bestätigung den vollen Display-Name tippen: <strong>{@user["display_name"]}</strong>
                </label>
                <input
                  type="text"
                  name="typed"
                  value={@delete_state.typed}
                  class="bg-bg border border-border rounded px-3 py-2 text-sm w-full focus:border-danger focus:ring-0"
                  autocomplete="off"
                  autofocus
                />
                <div class="flex justify-end gap-2 mt-3">
                  <.btn variant="ghost" type="button" phx-click="delete_user_cancel">Abbrechen</.btn>
                  <.btn
                    variant="danger"
                    type="submit"
                    disabled={@delete_state.typed != @user["display_name"]}
                  >
                    Endgültig löschen
                  </.btn>
                </div>
              </form>
            </div>
        <% end %>
    </.lt_modal>
    """
  end
end
