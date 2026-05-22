defmodule Shared.Schema.ChronikEntry do
  @moduledoc false

  @enforce_keys [:id, :campaign_id, :in_game_date]
  defstruct [
    :id,
    :campaign_id,
    :in_game_date,
    :label,
    :summary,
    :session_id
  ]
end
