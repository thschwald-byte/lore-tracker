defmodule HubWeb.DashboardLive.Permissions do
  @moduledoc """
  Issue #573: card-level Permission-Helpers aus `HubWeb.DashboardLive`.

  Pro Campaign-Karte werden Edit/Delete/Invite-Buttons gerendert — die hängen
  alle an `HubWeb.Permissions.can?/3` mit dem aus den Card-Members abgeleiteten
  `campaign_role`. `perm_user_for_card/3` baut diese erweiterte User-Struktur
  (Issue #474: ohne :campaign_role sah ein per-Campaign-SL ohne globale Rolle
  den Invite-Button nicht).
  """

  alias HubWeb.Permissions

  @spec can_invite_campaign?(map(), atom(), map()) :: boolean()
  def can_invite_campaign?(user, role, campaign) do
    Permissions.can?(
      perm_user_for_card(user, role, campaign),
      :invite_to_campaign,
      campaign
    )
  end

  # Issue #270: Per-Campaign-Spielleiter oder globaler Admin darf löschen.
  # campaign_role wird aus members abgeleitet (analog build_perm_user/2),
  # damit `:delete_campaign` per HubWeb.Permissions korrekt fällt.
  @spec can_delete_campaign?(map(), atom(), map()) :: boolean()
  def can_delete_campaign?(user, role, campaign) do
    Permissions.can?(
      perm_user_for_card(user, role, campaign),
      :delete_campaign,
      campaign
    )
  end

  # Issue #275: Edit-Permission gleich gelagert wie Delete — Per-Campaign-
  # Spielleiter oder Admin. `:edit_summary` ist der Standard-GM-Action-Atom.
  @spec can_edit_campaign?(map(), atom(), map()) :: boolean()
  def can_edit_campaign?(user, role, campaign) do
    Permissions.can?(
      perm_user_for_card(user, role, campaign),
      :edit_summary,
      campaign
    )
  end

  @spec perm_user_for_card(map(), atom(), map()) :: map()
  def perm_user_for_card(user, role, campaign) do
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
end
