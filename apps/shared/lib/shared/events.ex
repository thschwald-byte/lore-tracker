defmodule Shared.Events do
  @moduledoc """
  Event types that travel through `Hub.EventLog`.

  Each event is an Elixir struct in a submodule. The hub appends them
  with a monotonic `seq` and broadcasts to all connected workers; workers
  materialize them into their local Mnesia via `Worker.Materializer.apply_event/2`.

  Concrete event modules are added milestone-by-milestone (see plan M4+).
  """
end
