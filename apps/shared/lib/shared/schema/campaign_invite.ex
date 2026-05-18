defmodule Shared.Schema.CampaignInvite do
  @moduledoc false

  @enforce_keys [:token, :campaign_id, :created_by_discord_id, :created_at, :status]
  defstruct [
    :token,
    :campaign_id,
    :created_by_discord_id,
    :created_at,
    :expires_at,
    :status,
    :redeemed_by_discord_id
  ]
end
