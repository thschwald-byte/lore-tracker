defmodule Shared.Commands do
  @moduledoc """
  Hub → Worker side-channel commands that are NOT events
  (i.e. don't mutate domain state and aren't replicated).

  Currently only `:shutdown_worker`; lease-related commands may join in M8.
  """
end
