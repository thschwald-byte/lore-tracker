defmodule Worker.Lifecycle do
  @moduledoc """
  Worker-side helpers for the `shutdown_worker` channel command.

  `Application.stop(:worker)` cleanly tears down the Worker supervisor
  (HubClient, Materializer, etc.). In a dedicated worker BEAM started via
  `mix run --no-halt`, this also lets the BEAM exit shortly after. In the
  dev umbrella where hub and worker share one BEAM, the hub keeps
  running — only the worker goes away.
  """

  require Logger

  @spec shutdown() :: :ok
  def shutdown do
    Logger.warning("Worker.Lifecycle: shutdown requested — stopping :worker application")
    Task.start(fn -> Application.stop(:worker) end)
    :ok
  end
end
