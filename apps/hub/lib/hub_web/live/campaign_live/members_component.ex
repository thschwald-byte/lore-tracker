defmodule HubWeb.CampaignLive.MembersComponent do
  @moduledoc """
  Mitspieler-Bereich der CampaignLive als **erstes LiveComponent des Hubs**
  (Issue #445, Pilot-Slice). Kapselt die Mitspieler-Pillen-Leiste (#270), das
  Aktions-Popup (Promote/Demote/Entfernen, #140/#55) und das Charakter-Namen-
  Modal (#2).

  ## Warum LiveComponent

  - **Render-Isolation**: re-rendert nur, wenn sich die hereingereichten
    Assigns (members/users/character_names/perms) ändern — nicht bei jedem
    Utterance-Append oder Pipeline-Tick im Parent (#445-Render-CPU-Ziel).
  - **State-Kapselung**: die rein transienten UI-Zustände (offenes Popup,
    Alias-Modal-Modus + Draft) leben hier statt im ~60-Assign-Namespace des
    Parent-LiveView.

  ## Eigene vs. hereingereichte Assigns

  - **Vom Parent** (`update/2`): `members`, `users`, `character_names`,
    `current_user`, `campaign`, `campaign_id`, `perm_user`, `owner?`,
    `can_edit_meta?`. Der Parent bleibt Owner der Worker-Reads + des PubSub —
    Member-Daten fließen nach Events (MemberRolePromoted etc.) über den Parent
    rein und werden hier nur gerendert.
  - **Transient (LC-intern)**: `member_popup_open_for`, `alias_mode`,
    `alias_draft` — in `update/2` defaultet, von den eigenen `handle_event`-
    Klauseln mutiert.

  ## Event-Routing

  Alle Member-/Alias-Events tragen `phx-target={@myself}` → landen hier und
  delegieren an `HubWeb.CampaignLive.Members.*` (kontext-agnostisch seit #445,
  `flash/3` bridgt im LC-Fall an den Parent). **Ausnahme** `create_invite`:
  bewusst OHNE `phx-target` → bubblet zum Parent-LiveView, weil das resultierende
  `invite_url` + das Einladungs-Banner ausserhalb dieses Components (oben in der
  Seite) leben.
  """
  use HubWeb, :live_component

  import HubWeb.CampaignLive.Components, only: [display_for: 3]
  alias HubWeb.CampaignLive.Members

  @transient_defaults [member_popup_open_for: nil, alias_mode: :view, alias_draft: ""]

  @impl true
  def update(assigns, socket) do
    {:ok, socket |> assign(assigns) |> ensure_transient_defaults()}
  end

  # Transiente UI-Assigns nur initial setzen — über Parent-Re-Renders hinweg
  # erhalten (das Component persistiert pro `id`, `update/2` läuft bei jedem
  # Re-Render, darf den offenen Popup/Modal-Zustand aber nicht zurücksetzen).
  defp ensure_transient_defaults(socket) do
    Enum.reduce(@transient_defaults, socket, fn {k, v}, s ->
      if Map.has_key?(s.assigns, k), do: s, else: assign(s, k, v)
    end)
  end

  @impl true
  def handle_event("open_member_popup", %{"discord_id" => did}, socket),
    do: Members.open_popup(socket, did)

  def handle_event("close_member_popup", _, socket), do: Members.close_popup(socket)

  def handle_event("member_remove_confirm", %{"discord_id" => did}, socket),
    do: Members.remove_confirm(socket, did)

  def handle_event("member_promote", %{"discord_id" => did}, socket),
    do: Members.promote(socket, did)

  def handle_event("member_demote_confirm", %{"discord_id" => did}, socket),
    do: Members.demote_confirm(socket, did)

  def handle_event("alias_edit_start", _, socket), do: Members.alias_edit_start(socket)
  def handle_event("alias_edit_cancel", _, socket), do: Members.alias_edit_cancel(socket)
  def handle_event("alias_edit_reset", _, socket), do: Members.alias_edit_reset(socket)

  def handle_event("alias_edit_save", %{"character_name" => name}, socket),
    do: Members.alias_edit_save(socket, name)

  # Spielleiter-/Owner-Pille dieser Kampagne (für Hervorhebung + Tooltip).
  defp member_sl?(m), do: m["role"] in ["spielleiter", "owner"]

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <%!-- Issue #270: Mitspieler-Pillen sind klickbare Buttons. Click öffnet
           ein Popup mit den verfügbaren Aktionen — eigener User sieht
           "Charakter-Namen ändern", GM sieht Promote/Demote/Remove. --%>
      <div class="border-t border-bg-3/60 px-4 py-2 text-xs text-ink-2 flex items-center gap-3 bg-bg-1 flex-wrap">
        <span class="uppercase tracking-widest">Mitspieler</span>
        <%= for m <- @members do %>
          <span class="inline-flex items-center relative">
            <button
              type="button"
              phx-click="open_member_popup"
              phx-target={@myself}
              phx-value-discord_id={m["discord_id"]}
              class={[
                "pill cursor-pointer hover:bg-accent/20",
                member_sl?(m) && "pill-active"
              ]}
              title={
                if(member_sl?(m),
                  do: "Spielleiter dieser Kampagne · #{m["discord_id"]}",
                  else: m["discord_id"]
                )
              }
            >
              {display_for(m["discord_id"], @users, @character_names)}<%= if m["discord_id"] == @current_user.discord_id do %><span class="ml-1 opacity-60">✎</span><% end %>
            </button>

            <%= if @member_popup_open_for == m["discord_id"] do %>
              <div
                class="absolute z-30 left-0 bottom-full mb-1 w-60 panel p-2 space-y-1 shadow-glow"
                phx-click-away="close_member_popup"
                phx-window-keydown="close_member_popup"
                phx-target={@myself}
                phx-key="escape"
              >
                <div class="text-[10px] text-ink-2 uppercase tracking-widest px-1 pb-1 border-b border-bg-3/40">
                  {display_for(m["discord_id"], @users, @character_names)}
                </div>

                <%= cond do %>
                  <% m["discord_id"] == @current_user.discord_id -> %>
                    <.btn
                      variant="ghost"
                      icon="pencil"
                      phx-click="alias_edit_start"
                      phx-target={@myself}
                      class="w-full justify-start"
                    >
                      Charakter-Namen ändern
                    </.btn>

                  <% @can_edit_meta? -> %>
                    <%= if member_sl?(m) do %>
                      <%= unless Members.last_spielleiter?(@members, m["discord_id"]) do %>
                        <.btn
                          variant="ghost"
                          icon="user"
                          phx-click="member_demote_confirm"
                          phx-target={@myself}
                          phx-value-discord_id={m["discord_id"]}
                          data-confirm="Wirklich auf Spieler zurückstufen?"
                          class="w-full justify-start"
                        >
                          Auf Spieler zurückstufen
                        </.btn>
                      <% end %>
                    <% else %>
                      <.btn
                        variant="ghost"
                        icon="arrow-up"
                        phx-click="member_promote"
                        phx-target={@myself}
                        phx-value-discord_id={m["discord_id"]}
                        class="w-full justify-start"
                      >
                        Zum Spielleiter befördern
                      </.btn>
                    <% end %>
                    <%= unless Members.last_spielleiter?(@members, m["discord_id"]) do %>
                      <.btn
                        variant="danger"
                        icon="user-minus"
                        phx-click="member_remove_confirm"
                        phx-target={@myself}
                        phx-value-discord_id={m["discord_id"]}
                        data-confirm="Wirklich aus der Kampagne entfernen?"
                        class="w-full justify-start"
                      >
                        Aus Kampagne entfernen
                      </.btn>
                    <% end %>

                  <% true -> %>
                    <span class="text-xs text-ink-2 px-1 block">Keine Aktionen verfügbar.</span>
                <% end %>
              </div>
            <% end %>
          </span>
        <% end %>

        <%= if @owner? do %>
          <div class="flex-1"></div>
          <%!-- create_invite bewusst OHNE phx-target → bubblet zum Parent-LV
               (invite_url + Banner leben dort, ausserhalb dieses Components). --%>
          <.ls_icon_btn_compat kind={:invite} size={:sm} phx-click="create_invite" title="Einladung erstellen" />
        <% end %>
      </div>

      <%= if @alias_mode == :edit do %>
        <div class="fixed inset-0 bg-black/60 z-50 flex items-center justify-center">
          <div
            class="panel p-5 w-[420px] max-w-[90vw]"
            phx-click-away="alias_edit_cancel"
            phx-window-keydown="alias_edit_cancel"
            phx-target={@myself}
            phx-key="escape"
          >
            <h2 class="font-display text-lg mb-2">Charakter-Name</h2>
            <p class="text-xs text-ink-2 mb-3">
              Wird statt deines Discord-Namens in Protokoll, Resümees,
              Epos und Chronik dieser Kampagne angezeigt. Leer = zurücksetzen.
            </p>
            <form phx-submit="alias_edit_save" phx-target={@myself} class="space-y-3">
              <input
                type="text"
                name="character_name"
                value={@alias_draft}
                maxlength="80"
                autofocus
                placeholder="z.B. Tharion der Entdecker"
                class="block w-full bg-bg-0 border border-bg-3 rounded-md px-3 py-2 text-ink-0 text-sm focus:border-accent focus:ring-0"
              />
              <div class="flex justify-end gap-2">
                <.ls_icon_btn_compat kind={:cancel} size={:md} phx-click="alias_edit_cancel" phx-target={@myself} title="Abbrechen" />
                <.ls_icon_btn_compat kind={:reset} size={:md} phx-click="alias_edit_reset" phx-target={@myself} title="Zurücksetzen" />
                <.ls_icon_btn_compat kind={:confirm} size={:md} type="submit" title="Speichern" />
              </div>
            </form>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
