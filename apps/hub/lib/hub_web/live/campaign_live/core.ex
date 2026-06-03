defmodule HubWeb.CampaignLive.Core do
  @moduledoc """
  Domänen-übergreifende Helfer der CampaignLive (Issue #434, Cut 4), die von
  mehreren Kontext-Modulen genutzt werden und deshalb nicht in eines davon
  gehören. Importiert von den Domänen-Modulen + von `HubWeb.CampaignLive`.
  """

  @doc """
  Snapshot-Campaign (String-keyed) → die von `HubWeb.Permissions.can?/3`
  erwartete `%{id: ...}`-Form (Atom-Key). Issue #140: Permission-Gating geht
  über `user.campaign_role`, nicht mehr über owner_discord_id.
  """
  def perm_campaign(socket) do
    c = socket.assigns[:campaign] || %{}
    %{id: c["id"]}
  end
end
