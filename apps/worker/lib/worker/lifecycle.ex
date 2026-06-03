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

  @doc """
  Issue #492: kontrollierter Node-Exit fürs Self-Update. `Application.stop/1`
  fährt den Worker-Supervisor sauber runter (HubClient-WS-Leave, Sidecar-
  Subprozesse, GpuQueue-Drain), `System.stop/1` (nicht `halt`) lässt OTP
  orderly beenden (Mnesia-Flush) → Exit-Code 0. Ein externer Supervisor
  (systemd `Restart=always`) startet den Worker aus dem aktualisierten
  Deploy-Clone neu.

  Im Task gewrappt, damit der aufrufende Updater nicht blockiert. Wird NUR im
  dedizierten `worker_prod`-BEAM gerufen (Updater läuft nur bei aktivem
  Auto-Update) — im Dev-Umbrella (geteilter BEAM) ist der Updater nicht aktiv.
  """
  @spec graceful_halt() :: :ok
  def graceful_halt do
    Logger.warning("Worker.Lifecycle: graceful halt for self-update — stopping node (exit 0)")

    Task.start(fn ->
      Application.stop(:worker)
      System.stop(0)
    end)

    :ok
  end
end
