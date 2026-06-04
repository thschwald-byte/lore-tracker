defmodule HubWeb.DebugController do
  @moduledoc """
  Issue #144: Admin-Debug-Endpoint zur Diagnose von LV-Permission-Bugs.

  Liefert für eine (target_did, campaign_id)-Kombination:
  - Snapshot (Worker-Reader-Output)
  - Berechnete LV-assigns aus `HubWeb.CampaignLive.derive_assigns/2`
  - Permission-Matrix (`HubWeb.Permissions.can?` für GM- und Member-Actions)
  - Optional: aktive LV-Process(es) des Target-Users (mit `?include_live=1`)

  Gates:
  - Caller muss `role == :admin` haben
  - Target-User muss aktiv `Hub.DebugConsent.grant/2` in den Einstellungen
    aktiviert haben

  Audit: jeder Aufruf wird mit `Logger.info` geloggt (admin_did, target_did,
  campaign_id, include_live?). Hub bleibt stateless — kein Audit-Persist.
  """

  use HubWeb, :controller

  alias Hub.Reader
  alias HubWeb.{CampaignLive, Permissions}

  require Logger

  # Issue #474: delete_session + assign_speaker werden von permissions.ex
  # ebenfalls als GM-Actions gegatet (meta.ex:58 / campaign_live.ex:973), fehlten
  # aber in dieser Diagnose-Matrix — der Debug-Endpoint (das Permission-Diagnose-
  # Tool) zeigte sie nie an.
  @gm_actions ~w(
    delete_campaign delete_session edit_summary edit_epos edit_chronik edit_flavor
    edit_vocab add_utterance assign_speaker invite_to_campaign regenerate_session
    regenerate_campaign promote_member demote_member
  )a

  @member_actions ~w(join_mic set_own_alias)a

  def campaign(conn, %{"id" => campaign_id} = params) do
    caller = Hub.Auth.current_user(conn) || %{}
    caller_did = caller[:discord_id] || caller["discord_id"]
    target_did = params["target_did"] || params["did"]
    include_live? = params["include_live"] in ["1", "true"]

    cond do
      is_nil(caller_did) ->
        send_json(conn, 401, %{"error" => "not logged in"})

      not admin?(caller_did) ->
        send_json(conn, 403, %{"error" => "admin only"})

      is_nil(target_did) or target_did == "" ->
        send_json(conn, 400, %{"error" => "target_did query param required"})

      not Hub.DebugConsent.valid?(target_did) ->
        send_json(conn, 403, %{
          "error" => "consent missing",
          "hint" =>
            "Target-User muss in /settings den Debug-Zugriff aktivieren (Issue #144)."
        })

      true ->
        do_dump(conn, campaign_id, target_did, include_live?, caller_did)
    end
  end

  # Caller-Role-Lookup via Worker-Snapshot. `current_user`-Session hält nur
  # discord_id + display_name; die globale Rolle (:admin/:spielleiter/
  # :spieler) lebt im Worker-Mnesia und kommt via Reader. Bei
  # `no_worker`-Fehler darf der Caller defensiv NICHT auf das Debug-
  # Interface zugreifen (Failure closed).
  defp admin?(caller_did) do
    case Reader.read(%{"kind" => "campaigns_for", "discord_id" => caller_did}) do
      {:ok, %{"viewer_role" => "admin"}} -> true
      _ -> false
    end
  end

  defp do_dump(conn, campaign_id, target_did, include_live?, caller_did) do
    Logger.info(
      "DebugController: admin=#{caller_did} target=#{target_did} " <>
        "campaign=#{campaign_id} include_live=#{include_live?}"
    )

    scope = %{"kind" => "campaign", "id" => campaign_id, "viewer_discord_id" => target_did}

    case Reader.read(scope) do
      {:ok, %{"forbidden" => true}} ->
        send_json(conn, 200, %{
          "campaign_id" => campaign_id,
          "target_did" => target_did,
          "snapshot_forbidden" => true,
          "hint" => "Target ist kein Member dieser Campaign — Worker liefert keinen Snapshot."
        })

      {:ok, %{"not_found" => true}} ->
        send_json(conn, 404, %{"error" => "campaign not found"})

      {:ok, snap} ->
        derived = CampaignLive.derive_assigns(snap, target_did)

        permissions = %{
          "gm_actions" => permission_matrix(derived.perm_user, @gm_actions, derived.campaign),
          "member_actions" =>
            permission_matrix(derived.perm_user, @member_actions, derived.campaign)
        }

        body = %{
          "campaign_id" => campaign_id,
          "target_did" => target_did,
          "snapshot" => snap,
          "derived_assigns" => serialize_derived(derived),
          "permissions" => permissions
        }

        body =
          if include_live?, do: Map.put(body, "live_lv_states", live_lv_states(target_did)), else: body

        send_json(conn, 200, body)

      {:error, reason} ->
        send_json(conn, 502, %{"error" => "reader error", "reason" => inspect(reason)})
    end
  end

  defp permission_matrix(perm_user, actions, campaign) do
    Enum.into(actions, %{}, fn action ->
      {Atom.to_string(action), Permissions.can?(perm_user, action, campaign)}
    end)
  end

  defp serialize_derived(derived) do
    %{
      "role" => Atom.to_string(derived.role),
      "campaign_role" =>
        case derived.campaign_role do
          nil -> nil
          a -> Atom.to_string(a)
        end,
      "is_member?" => derived.is_member?,
      "owner?" => derived.owner?,
      "can_edit_meta?" => derived.can_edit_meta?,
      "can_regenerate_session?" => derived.can_regenerate_session?,
      "can_regenerate_campaign?" => derived.can_regenerate_campaign?,
      "perm_user" => %{
        "discord_id" => derived.perm_user.discord_id,
        "role" => Atom.to_string(derived.perm_user.role),
        "is_member?" => derived.perm_user.is_member?,
        "campaign_role" =>
          case derived.perm_user.campaign_role do
            nil -> nil
            a -> Atom.to_string(a)
          end
      }
    }
  end

  # Iteriert alle Phoenix.LiveView-Prozesse mit dem Target-User als
  # `current_user`. Out-of-scope für v1 — Issue #144 listet das als
  # opt-in via ?include_live=1, aber die Implementation braucht Zugriff
  # auf das LiveView-SocketRegistry, das pro Endpoint privat ist. Stub
  # bis konkretes Bedürfnis besteht.
  defp live_lv_states(_target_did),
    do: %{"note" => "LV-Process-Iteration out-of-scope für v1 — siehe Issue-Body Out-of-scope"}

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
