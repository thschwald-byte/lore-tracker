defmodule Worker.Lifecycle do
  @moduledoc """
  Worker-side helpers for the `shutdown_worker` channel command + das #492-
  Self-Update.

  **Dediziertes Worker-BEAM (prod, `mix run --no-halt`) vs. geteiltes Dev-BEAM:**
  `Application.stop(:worker)` allein beendet ein `--no-halt`-BEAM NICHT — der Node
  lebt mit gestoppter App weiter (Zombie). Unter systemd `Restart=always` sieht
  der externe Supervisor den PID weiterleben → kein Restart → der Worker bleibt
  weg (nicht im Hub). Im dedizierten BEAM muss der Node daher sauber halten
  (`System.stop(0)`, exit 0) → systemd startet neu → Worker reconnected.

  Im **geteilten Dev-Umbrella-BEAM** (`iex -S mix`, `:hub` läuft im selben Node)
  darf der Node NICHT halten — sonst stirbt der Hub mit. Dort genügt
  `Application.stop(:worker)` (nur der Worker geht weg, Hub bleibt).

  Discriminator: läuft `:hub` in diesem Node? (`Application.started_applications/0`).
  Siehe Issue #496 — vorher strandete `shutdown_worker` den prod-Daemon.
  """

  require Logger

  @doc """
  `shutdown_worker`-Channel-Command. Im dedizierten Worker-BEAM = Node-Halt
  (exit 0 → systemd-Restart → Worker kommt zurück); im geteilten Dev-BEAM nur
  App-Stop (Hub überlebt).
  """
  @spec shutdown() :: :ok
  def shutdown do
    if dedicated_worker_beam?() do
      halt_node("shutdown_worker — dediziertes Worker-BEAM")
    else
      Logger.warning(
        "Worker.Lifecycle: shutdown_worker — stopping :worker application (geteiltes Dev-BEAM, Hub bleibt)"
      )

      Task.start(fn -> Application.stop(:worker) end)
      :ok
    end
  end

  @doc """
  Issue #492: kontrollierter Node-Exit fürs Self-Update. Externer Supervisor
  (systemd `Restart=always`) startet den Worker aus dem aktualisierten Deploy-
  Clone neu. Halt-Mechanik identisch zu `shutdown/0` im dedizierten BEAM.
  """
  @spec graceful_halt() :: :ok
  def graceful_halt, do: halt_node("graceful halt for self-update")

  # `Application.stop/1` fährt den Worker-Supervisor sauber runter (HubClient-WS-
  # Leave, Sidecar-Subprozesse, GpuQueue-Drain); `System.stop/1` (nicht `halt`)
  # lässt OTP orderly beenden (Mnesia-Flush) → Exit-Code 0. Im Task gewrappt,
  # damit der Aufrufer nicht blockiert.
  defp halt_node(reason) do
    Logger.warning("Worker.Lifecycle: #{reason} — stopping node (exit 0 → systemd-Restart)")

    Task.start(fn ->
      Application.stop(:worker)
      System.stop(0)
    end)

    :ok
  end

  # True, wenn dies ein dedizierter Worker-BEAM ist (kein `:hub` im selben Node)
  # — dann muss ein Shutdown den BEAM halten, nicht nur die App stoppen (#496).
  @doc false
  def dedicated_worker_beam? do
    not List.keymember?(Application.started_applications(), :hub, 0)
  end
end
