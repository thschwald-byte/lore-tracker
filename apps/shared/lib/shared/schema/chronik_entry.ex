defmodule Shared.Schema.ChronikEntry do
  @moduledoc false

  @enforce_keys [:id, :campaign_id, :in_game_date, :in_game_sort_key]
  defstruct [
    :id,
    :campaign_id,
    :in_game_date,
    :in_game_sort_key,
    :label,
    :summary,
    :session_id
  ]
end
