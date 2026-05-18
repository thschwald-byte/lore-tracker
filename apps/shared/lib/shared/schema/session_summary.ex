defmodule Shared.Schema.SessionSummary do
  @moduledoc false

  @enforce_keys [:session_id, :content_md, :generated_at, :source]
  defstruct [
    :session_id,
    :content_md,
    :generated_at,
    :source
  ]
end
