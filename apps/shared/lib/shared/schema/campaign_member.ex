defmodule Shared.Schema.CampaignMember do
  @moduledoc false

  @enforce_keys [:campaign_id, :discord_id, :role, :joined_at]
  defstruct [
    :campaign_id,
    :discord_id,
    :role,
    :joined_at,
    # Per-campaign character alias. nil → fall back to display_name → discord_id.
    :character_name
  ]
end
