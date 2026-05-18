defmodule Shared.Schema.CampaignMember do
  @moduledoc false

  @enforce_keys [:campaign_id, :discord_id, :role, :joined_at]
  defstruct [
    :campaign_id,
    :discord_id,
    :role,
    :joined_at
  ]
end
