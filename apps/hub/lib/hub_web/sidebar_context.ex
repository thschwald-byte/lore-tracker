defmodule HubWeb.SidebarContext do
  @moduledoc """
  on_mount-Hook für die Sidebar (Issue #387).

  Setzt zwei Sidebar-relevante Assigns, die sonst pro Page-LV dupliziert
  werden müssten:

  1. **`:current_user_role`** — die GLOBALE Rolle (`:admin` / `:spielleiter` /
     `:spieler`). Der Session-Cookie enthält den User nur mit
     `discord_id` + `display_name` + `avatar_url` (siehe `HubWeb.AuthController`),
     KEINE Rolle. Wir laden sie hier via `Hub.Reader.read(%{"kind" => "all_users"})`
     vom Worker nach. Separater Assign (nicht `:current_user` erweitert),
     damit die `assign(:current_user, user)`-Zeilen in jedem Page-LV nicht
     den frisch geladenen Wert überschreiben.

  2. **`:current_campaign`** — die zuletzt besuchte Kampagne, deren ID der
     Browser via LocalStorage (`lore.last_campaign_id`) und LiveSocket-
     Connect-Params durchreicht. So bleibt das Sidebar-Item
     „Kampagne: <name>" auch auf Pages wie `/settings`, `/admin/*`,
     Dashboard klickbar.

  ## Wichtige Details

  - **`current_user` aus dem `session`-Map lesen** — nicht aus
    `socket.assigns`. Es gibt keinen Auth-`on_mount`-Hook, jedes LV
    setzt `current_user` selbst in `mount/3` aus dem Session-Argument.
    `on_mount` läuft VOR `mount/3`, also wären die Assigns hier leer.

  - **CampaignLive wird beim Campaign-Lookup übergangen**: dort wird
    `current_campaign` von der LV selbst gesetzt (mit reicherer
    Snapshot-Shape). Reader-Call wäre Doppelarbeit. Die globale Rolle
    setzen wir aber auch in CampaignLive — sonst hätte ein globaler
    Admin als Kampagnen-Spieler die Admin-Nav-Items disabled.

  - **Trust-Boundary**: `last_campaign_id` ist user-controlled
    (LocalStorage). `viewer_discord_id` aber server-known
    (aus `current_user`). Manipulierte Campaign-IDs liefern maximal
    Kampagnen die der User sehen darf — sonst `{:error}` → nil.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [get_connect_params: 1]

  alias Hub.Reader

  def on_mount(:default, _params, session, socket) do
    user = session["current_user"]

    socket =
      socket
      |> assign(:current_user_role, load_role(user))
      |> maybe_assign_last_campaign(user)

    {:cont, socket}
  end

  # Issue #387: separater Assign-Key `:sidebar_campaign` (nicht
  # `:current_campaign`), weil die Page-LVs (EinstellungenLive, AdminXxxLive,
  # DashboardLive) im `mount/3` ein `assign(:current_campaign, nil)` machen
  # und mount/3 NACH on_mount läuft — würden sonst unseren Hook-Wert mit nil
  # überschreiben. Layout liest `assigns[:sidebar_campaign]` direkt für die
  # Sidebar; in CampaignLive setzt apply_snapshot zusätzlich
  # `:sidebar_campaign` neben dem internen `:current_campaign`.
  defp maybe_assign_last_campaign(socket, user) do
    if socket.view == HubWeb.CampaignLive do
      socket
    else
      assign(socket, :sidebar_campaign, load_last_campaign(socket, user))
    end
  end

  defp load_role(%{discord_id: did}) when is_binary(did) do
    # Issue #366: bevorzugt den eigenen Worker des Viewers — diese Rolle-Auflösung
    # läuft auf jeder Nicht-Campaign-Seite, deterministisch statt switchend.
    case Reader.read(%{"kind" => "all_users"}, prefer_discord_id: did) do
      {:ok, %{"users" => users}} when is_list(users) ->
        Enum.find_value(users, :spieler, fn u ->
          if u["discord_id"] == did, do: parse_role(u["role"])
        end)

      _ ->
        :spieler
    end
  end

  defp load_role(_), do: :spieler

  defp parse_role("admin"), do: :admin
  defp parse_role("spielleiter"), do: :spielleiter
  defp parse_role("spieler"), do: :spieler
  defp parse_role(role) when is_atom(role), do: role
  defp parse_role(_), do: :spieler

  defp load_last_campaign(_socket, nil), do: nil

  defp load_last_campaign(socket, %{discord_id: did}) when is_binary(did) do
    with %{} = params <- get_connect_params(socket),
         cid when is_binary(cid) <- params["last_campaign_id"],
         {:ok, snap} <-
           Reader.read(%{
             "kind" => "campaign",
             "id" => cid,
             "viewer_discord_id" => did
           }) do
      snap["campaign"]
    else
      _ -> nil
    end
  end

  defp load_last_campaign(_, _), do: nil
end
