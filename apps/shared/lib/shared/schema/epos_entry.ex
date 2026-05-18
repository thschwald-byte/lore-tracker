defmodule Shared.Schema.EposEntry do
  @moduledoc false

  @enforce_keys [:id, :campaign_id, :content_md, :updated_at]
  defstruct [
    :id,
    :campaign_id,
    :parent_id,
    :content_md,
    :updated_at
  ]
end

defmodule Shared.Schema.EposHistory do
  @moduledoc false

  @enforce_keys [:id, :entry_id, :content_md, :edited_at, :source]
  defstruct [
    :id,
    :entry_id,
    :content_md,
    :edited_at,
    :edited_by,
    :source
  ]
end
