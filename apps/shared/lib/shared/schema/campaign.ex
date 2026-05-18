defmodule Shared.Schema.Campaign do
  @moduledoc false

  @enforce_keys [:id, :name, :owner_discord_id, :created_at]
  defstruct [
    :id,
    :name,
    :icon_url,
    :theme_blurb,
    :owner_discord_id,
    :created_at,
    status: :active
  ]
end
