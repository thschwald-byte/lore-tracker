defmodule Worker.Lifecycle do
  @moduledoc """
  Worker-side helpers for the `shutdown_worker` channel command + das #492-
  Self-Update.

  **Dediziertes Worker-BEAM (prod, `mix run --no-halt`) vs. geteiltes Dev-BEAM:**
  `Application.stop(:worker)` allein beendet ein `--no-halt`-BEAM NICHT — der Node
  lebt mit gestoppter App weiter (Zombie). Unter systemd `Restart=always` sieht
  der externe Supervisor den PID weiterleben → kein Restart → der Worker bleibt
  weg (nicht im Hub). Im dedizierten BEAM muss der Node daher hart halten
  (`System.halt(0)` nach graceful Teardown, exit 0) → systemd startet neu →
  Worker reconnected. (`System.stop/1` reichte NICHT — siehe #498: der "careful"
  :init.stop hängt am Sidecar-Port und halt't den `--no-halt`-Node nie.)

  Im **geteilten Dev-Umbrella-BEAM** (`iex -S mix`, `:hub` läuft im selben Node)
  darf der Node NICHT halten — sonst stirbt der Hub mit. Dort genügt
  `Application.stop(:worker)` (nur der Worker geht weg, Hub bleibt).

  Discriminator: läuft `:hub` in diesem Node? (`Application.started_applications/0`).
  Siehe Issue #496 (Discriminator) + #498 (harter Halt statt System.stop).
  """

  require Logger

  # Issue #498: Backstop — spätestens nach dieser Zeit hart halten, falls der
  # graceful Teardown (Application.stop/:mnesia.stop) hängt.
  @halt_grace_ms 15_000

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

      # Issue #571: fire-and-forget — wenn der Application.stop-Task crasht,
      # ist der Worker nachgelagert sowieso in einem inkonsistenten Zustand;
      # ein Supervisor-Restart würde nichts beheben.
      # credo:disable-for-next-line LoreTracker.Credo.Check.UnsupervisedTaskStart
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

  # Issue #498 (Folge von #496): `System.stop/1` beendete den
  # `elixir --no-halt -S mix run`-Daemon-Node NICHT zuverlässig — der "careful"
  # :init.stop (alle Apps smooth runter, alle Ports zu, dann halt) hängt am
  # nicht-schließenden uvicorn-Sidecar-Port und erreicht den finalen halt nie →
  # App gestoppt, BEAM lebt weiter (Zombie), systemd (Restart=always) sieht den
  # PID → kein Restart → Worker offline.
  #
  # Daher: graceful Teardown (Worker-Tree sauber runter: HubClient-WS-Leave,
  # Sidecar-SIGTERM, GpuQueue-Drain) + Mnesia sauber stoppen (disc_copies-Flush),
  # dann HART halten (`System.halt/1`, garantierter Exit → systemd-Restart greift
  # verlässlich). Plus ein unbedingter Backstop-Halt: hängt Application.stop oder
  # :mnesia.stop, stirbt der Node nach @halt_grace_ms trotzdem.
  # Issue #589 (Cut 4): die beiden spawn/Task.start-Closures enden bewusst in
  # System.halt/0 (no_return) — das ist genau ihr Job (Backstop + Graceful-Halt).
  # Dialyzer flaggt die anon Closures als no_return; es gibt keinen sauberen
  # @spec für anon fns, daher nowarn auf der umschließenden Funktion.
  @dialyzer {:nowarn_function, halt_node: 1}
  defp halt_node(reason) do
    Logger.warning("Worker.Lifecycle: #{reason} — halting node (exit 0 → systemd-Restart)")

    # Backstop: der Node MUSS sterben, egal ob der graceful Pfad hängt (#498).
    spawn(fn ->
      Process.sleep(@halt_grace_ms)
      System.halt(0)
    end)

    # Issue #571: fire-and-forget — der Backstop-spawn oben killt den Node
    # in jedem Fall nach @halt_grace_ms. Crasht der Graceful-Teardown,
    # garantiert der Backstop trotzdem den Exit (genau das ist sein Job).
    # credo:disable-for-next-line LoreTracker.Credo.Check.UnsupervisedTaskStart
    Task.start(fn ->
      Application.stop(:worker)
      safe_mnesia_stop()
      System.halt(0)
    end)

    :ok
  end

  # Mnesia ist eine eigene OTP-App (von Application.stop(:worker) nicht erfasst).
  # Sauber stoppen flusht disc_copies; bei hartem Halt ohne das recovered Mnesia
  # zwar aus dem Transaction-Log, aber der saubere Dump ist verlustärmer.
  defp safe_mnesia_stop do
    :mnesia.stop()
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # True, wenn dies ein dedizierter Worker-BEAM ist (kein `:hub` im selben Node)
  # — dann muss ein Shutdown den BEAM halten, nicht nur die App stoppen (#496).
  @doc false
  def dedicated_worker_beam? do
    not List.keymember?(Application.started_applications(), :hub, 0)
  end
end
