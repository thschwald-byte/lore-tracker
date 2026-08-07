defmodule HubWeb.CampaignLive.Derive do
  @moduledoc """
  Issue #144: berechnet aus einem Campaign-Snapshot + viewer-discord_id die
  Permission-Assigns (campaign_role, perm_user, owner?, is_member?, alle can_*).

  Ausgelagert aus `HubWeb.CampaignLive` (Issue #915, Slice 1 — God-Module-
  Entlastung: die reine Snapshot→Permission-Ableitung lebt vor dem Modus-Umbau
  in einem eigenen Modul, damit `campaign_live.ex` unter der 1000-Zeilen-Grenze
  Luft für die Feature-Delegationen bekommt). `CampaignLive` behält die
  öffentliche `derive_assigns/2`-API via `defdelegate` — der Snapshot-Apply
  (`apply_snapshot/2`) und der `HubWeb.DebugController` nutzen beide denselben
  Pfad (kein Drift bei künftigen Permission-Refactors).
  """

  alias HubWeb.Permissions

  @doc """
  Aus einem Campaign-Snapshot + viewer-discord_id die Permission-Assigns
  berechnen. Siehe Moduledoc.
  """
  @spec derive_assigns(map(), String.t() | nil) :: map()
  def derive_assigns(snap, viewer_did) do
    c = snap["campaign"]
    members = snap["members"] || []

    viewer_member =
      Enum.find(members, fn m -> m["discord_id"] == viewer_did end)

    is_member? = viewer_member != nil

    # Issue #140: per-Campaign-Rolle aus der Member-Liste ableiten.
    # `nil` wenn nicht Member; `:spielleiter` | `:spieler` sonst.
    # Backward-Compat: Worker auf Versionen <0.13.0 liefern noch die
    # alten Atoms `:owner` / `:player`.
    campaign_role =
      case viewer_member && viewer_member["role"] do
        "spielleiter" -> :spielleiter
        "owner" -> :spielleiter
        "spieler" -> :spieler
        "player" -> :spieler
        _ -> nil
      end

    role = Permissions.parse_role(snap["viewer_role"])

    perm_user = %{
      discord_id: viewer_did,
      role: role,
      is_member?: is_member?,
      campaign_role: campaign_role
    }

    %{
      campaign: c,
      members: members,
      role: role,
      campaign_role: campaign_role,
      is_member?: is_member?,
      perm_user: perm_user,
      # Issue #140/#464: `owner?` = „per-Campaign-GM" (per-Campaign-:spielleiter
      # ODER globaler :admin), `can_edit_meta?` = „darf Campaign-Inhalte editieren".
      # Issue #464: NICHT mehr die Regel `role == :admin or campaign_role ==
      # :spielleiter` von Hand nachbauen (Drift-Risiko gegenüber Permissions) —
      # stattdessen über Permissions.can?/3 ableiten, sodass die GM-Regel an genau
      # EINER Stelle lebt. `:delete_campaign` ist die repräsentative GM-only-Action
      # (owner?), `:edit_summary` die repräsentative Edit-Action (can_edit_meta?);
      # beide reduzieren in Permissions auf dieselbe Bedingung.
      owner?: Permissions.can?(perm_user, :delete_campaign, c),
      can_edit_meta?: Permissions.can?(perm_user, :edit_summary, c),
      can_regenerate_session?: Permissions.can?(perm_user, :regenerate_session, c),
      can_regenerate_campaign?: Permissions.can?(perm_user, :regenerate_campaign, c),
      can_assign_speaker?: Permissions.can?(perm_user, :assign_speaker, c),
      # #720: vorher als einziger Permission-Check im Template (heex Z. 75)
      # bei jedem Re-Render neu berechnet — jetzt vorberechnet wie alle can_*.
      can_vocab?: Permissions.can?(perm_user, :edit_vocab, c),
      # Issue #724 Slice F2: Kampagnen-Kalender editieren.
      can_calendar?: Permissions.can?(perm_user, :edit_calendar, c),
      # Issue #915 (Cut 1): Gate für den Lesen|Bearbeiten-Toggle — reine
      # UI-Convenience, NIE die Schranke (jeder Edit-Command prüft sein Recht
      # serverseitig selbst). Wahr, sobald der Viewer IRGENDEIN Kurations-/Edit-
      # Recht in dieser Kampagne hat: GM (`:edit_summary`) ODER Member-Kurator
      # (`:curate_threads`/`:curate_luecken`). Das später ergänzte Member-Recht
      # `:flag_raise` (Slice 6) hat dieselbe Bedingung wie `:curate_threads` und
      # ändert das Ergebnis nicht.
      can_edit_mode?:
        Permissions.can?(perm_user, :edit_summary, c) or
          Permissions.can?(perm_user, :curate_threads, c) or
          Permissions.can?(perm_user, :curate_luecken, c) or
          Permissions.can?(perm_user, :curate_facts, c)
    }
  end
end
