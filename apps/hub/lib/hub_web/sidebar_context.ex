defmodule HubWeb.SidebarContext do
  @moduledoc """
  on_mount-Hook für die Sidebar (Issue #387, async-Campaign seit Issue #569).

  Setzt zwei Sidebar-relevante Assigns, die sonst pro Page-LV dupliziert
  werden müssten:

  1. **`:current_user_role`** — die GLOBALE Rolle (`:admin` / `:spielleiter` /
     `:spieler`). Der Session-Cookie enthält den User nur mit
     `discord_id` + `display_name` + `avatar_url` (siehe `HubWeb.AuthController`),
     KEINE Rolle. Wir laden sie hier via `Hub.Reader.read(%{"kind" => "all_users"})`
     vom Worker nach. Separater Assign (nicht `:current_user` erweitert),
     damit die `assign(:current_user, user)`-Zeilen in jedem Page-LV nicht
     den frisch geladenen Wert überschreiben.

  2. **`:sidebar_campaign`** — die zuletzt besuchte Kampagne, deren ID der
     Browser via LocalStorage (`lore.last_campaign_id`) und LiveSocket-
     Connect-Params durchreicht. So bleibt das Sidebar-Item
     „Kampagne: <name>" auch auf Pages wie `/settings`, `/admin/*`,
     Dashboard klickbar.

  ## Lade-Modell (Issue #569)

  - **`:current_user_role`** wird **synchron** geladen. Page-LVs (insbesondere
    die Admin-LVs unter `/admin/*` und `/settings`) gaten ihren Mount auf
    `Permissions.can?(%{role: current_user_role}, :view_admin)` und müssen
    den Wert zur mount-Zeit kennen. Würde die Rolle async geladen, wären
    Admins beim ersten Connect kurzzeitig `:spieler` (Default) → der
    Gate-Check failt → push_navigate(/) → der Admin sieht Dashboard statt
    der gewünschten Admin-Page (Issue #575 plant Role-im-Session-Cookie,
    dann ist auch dieser Read entbehrlich).
  - **`:sidebar_campaign`** wird via `start_async/3` geladen. Der
    Campaign-Snapshot ist deutlich teurer (Sessions + Members +
    Utterances), und die Sidebar-Anzeige „Kampagne: …" ist kein
    Permission-Gate — ein Loading-Default (nil) im disconnected Mount ist
    UX-unschädlich. `attach_hook(:handle_async)` fängt das Resultat ab,
    ohne dass jedes Page-LV einen eigenen Callback braucht.

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

  - **`prefer_discord_id` (Issue #366)**: Reader-Reads geben den User-DID
    als Routing-Präferenz mit, damit der Snapshot bevorzugt vom eigenen
    Worker kommt (deterministischer als globaler Leader-Pickup).

  - **Trust-Boundary**: `last_campaign_id` ist user-controlled
    (LocalStorage). `viewer_discord_id` aber server-known
    (aus `current_user`). Manipulierte Campaign-IDs liefern maximal
    Kampagnen die der User sehen darf — sonst `{:error}` → nil.

  - **Campaign-Read inline im `fn -> … end`**: damit der Credo-AST-Check
    (#544 `SyncReaderInMount`) ihn strukturell im `start_async`-Subtree
    sieht. Auslagern in eine private Helper-Funktion würde den Check
    rotfärben.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, get_connect_params: 1, start_async: 3]

  alias Hub.Reader

  def on_mount(:default, _params, session, socket) do
    user = session["current_user"]

    socket =
      socket
      |> assign(:current_user_role, load_role(user))
      |> assign(:sidebar_campaign, nil)
      |> attach_hook(:sidebar_async, :handle_async, &handle_sidebar_async/3)
      |> maybe_start_campaign_load(user)

    {:cont, socket}
  end

  # Sync — Page-LVs müssen den Wert zur mount-Zeit kennen für ihren
  # Permission-Gate (Issue #569 / #575).
  defp load_role(%{discord_id: did}) when is_binary(did) do
    # Issue #366: bevorzugt den eigenen Worker des Viewers — diese Rolle-
    # Auflösung läuft auf jeder Nicht-Campaign-Seite, deterministisch statt
    # switchend.
    # credo:disable-for-next-line LoreTracker.Credo.Check.SyncReaderInMount
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

  defp maybe_start_campaign_load(%{view: HubWeb.CampaignLive} = socket, _user), do: socket

  defp maybe_start_campaign_load(socket, %{discord_id: did}) when is_binary(did) do
    cid =
      if connected?(socket) do
        case get_connect_params(socket) do
          %{"last_campaign_id" => cid} when is_binary(cid) -> cid
          _ -> nil
        end
      end

    if cid do
      start_async(socket, :sidebar_campaign, fn ->
        case Reader.read(
               %{
                 "kind" => "campaign",
                 "id" => cid,
                 "viewer_discord_id" => did
               },
               prefer_discord_id: did
             ) do
          {:ok, snap} -> snap["campaign"]
          _ -> nil
        end
      end)
    else
      socket
    end
  end

  defp maybe_start_campaign_load(socket, _), do: socket

  defp handle_sidebar_async(:sidebar_campaign, {:ok, campaign}, socket) do
    {:halt, assign(socket, :sidebar_campaign, campaign)}
  end

  defp handle_sidebar_async(:sidebar_campaign, _other, socket) do
    {:halt, socket}
  end

  defp handle_sidebar_async(_name, _result, socket), do: {:cont, socket}

  defp parse_role("admin"), do: :admin
  defp parse_role("spielleiter"), do: :spielleiter
  defp parse_role("spieler"), do: :spieler
  defp parse_role(role) when is_atom(role), do: role
  defp parse_role(_), do: :spieler
end
