defmodule Shared.Schema.Utterance do
  @moduledoc false

  @enforce_keys [:id, :session_id, :discord_id, :timestamp, :text]
  defstruct [
    :id,
    :session_id,
    :discord_id,
    :timestamp,
    :text,
    :confidence,
    status: :pending
  ]
end
