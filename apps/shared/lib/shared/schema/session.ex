defmodule Shared.Schema.Session do
  @moduledoc false

  @enforce_keys [:id, :campaign_id, :number]
  defstruct [
    :id,
    :campaign_id,
    :number,
    :name,
    :scheduled_for,
    :started_at,
    :ended_at,
    status: :scheduled
  ]
end
