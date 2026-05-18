defmodule Shared.Schema.Marker do
  @moduledoc false

  @enforce_keys [:id, :session_id, :at_ts]
  defstruct [
    :id,
    :session_id,
    :at_ts,
    :label,
    kind: :plot
  ]
end
