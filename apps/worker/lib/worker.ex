defmodule Worker do
  @moduledoc """
  LoreTracker Worker — local daemon. Holds a fully replicated Mnesia view of the
  event log, owns the local LLM/Whisper pipeline in Phase 2.

  See `Worker.Application` for the supervision tree.
  """
end
