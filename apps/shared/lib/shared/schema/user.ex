defmodule Shared.Schema.User do
  @moduledoc false

  @enforce_keys [:discord_id, :joined_at]
  defstruct [
    :discord_id,
    :display_name,
    :joined_at
  ]
end
