# Issue #571: TimerWithoutCleanup disabled — Self-Reschedule-Forever-Watchdog
# (handle_info(:ping) → send_after(:ping)). Timer-Ref nicht gespeichert weil
# Cancel sinnlos: der Watchdog soll bis Process-Tod weiter pingen. Folge-
# Cut für Check-Tune (Self-Reschedule-Pattern erkennen) ist offen.
# credo:disable-for-this-file LoreTracker.Credo.Check.TimerWithoutCleanup
defmodule Worker.SystemdWatchdog do
  @moduledoc """
  Issue #512: externer Zombie-Killer via systemd-Watchdog.

  Der Self-Update-Pfad (#492/#498) konnte in einen Zustand laufen, in dem die
  `worker`-Application gestoppt ist, der BEAM aber weiterlebt (`System.halt/0`
  hat den Node nicht terminiert). systemd sah den lebenden Main-PID → kein
  Restart → Worker unbemerkt offline.

  Dieser GenServer hängt im **worker**-Supervisor-Tree und pingt, solange er
  lebt, periodisch `WATCHDOG=1` an den systemd-Notify-Socket. Stoppt die App
  (Zombie), stirbt dieser Prozess → die Pings hören auf → systemd lässt
  `WatchdogSec` ablaufen und tötet den BEAM hart (SIGABRT) + startet ihn neu
  (`Restart=always`). Das schließt die Zombie-Lücke **generisch**, unabhängig
  davon WARUM der saubere Halt nicht durchkam.

  **Opt-in über die Umgebung**: läuft nur, wenn systemd `NOTIFY_SOCKET` +
  `WATCHDOG_USEC` gesetzt hat (d.h. die Unit hat `WatchdogSec=` + erlaubt
  Notify). Dev-/PR-Test-Worker ohne systemd starten kein Watchdog (`:ignore`).

  Notify-Protokoll: ein AF_UNIX-DGRAM-Datagram mit dem Body `WATCHDOG=1` an den
  Pfad aus `NOTIFY_SOCKET` (sd_notify(3)). Abstract Sockets (`@`-Prefix) werden
  auf den Null-Byte-Namespace abgebildet.
  """
  use GenServer

  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    with {:ok, path} <- notify_socket_path(),
         {:ok, interval_ms} <- watchdog_interval_ms(),
         {:ok, sock} <- open_socket() do
      st = %{sock: sock, addr: socket_addr(path), interval_ms: interval_ms}
      # READY=1: harmlos auch bei Type=simple; signalisiert „oben".
      notify(st, "READY=1")
      Process.send_after(self(), :ping, interval_ms)

      Logger.info("Worker.SystemdWatchdog: aktiv (ping alle #{interval_ms}ms an #{path})")

      {:ok, st}
    else
      :disabled ->
        # Kein systemd-Watchdog in dieser Umgebung — Prozess gar nicht starten.
        :ignore

      {:error, reason} ->
        Logger.warning(
          "Worker.SystemdWatchdog: NOTIFY_SOCKET/WATCHDOG_USEC gesetzt, aber Setup " <>
            "fehlgeschlagen (#{inspect(reason)}) — kein Watchdog-Ping. systemd killt den " <>
            "Node ggf. fälschlich; Unit-Config prüfen."
        )

        :ignore
    end
  end

  @impl true
  def handle_info(:ping, st) do
    notify(st, "WATCHDOG=1")
    Process.send_after(self(), :ping, st.interval_ms)
    {:noreply, st}
  end

  def handle_info(_msg, st), do: {:noreply, st}

  # ─── Notify-Send ───────────────────────────────────────────────────

  defp notify(%{sock: sock, addr: addr}, payload) do
    case :socket.sendto(sock, payload, addr) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Worker.SystemdWatchdog: sd_notify #{payload} fehlgeschlagen: #{inspect(reason)}"
        )

        :error
    end
  rescue
    e -> Logger.warning("Worker.SystemdWatchdog: sd_notify raise: #{Exception.message(e)}")
  end

  # ─── Env / Socket-Setup ────────────────────────────────────────────

  defp notify_socket_path do
    case System.get_env("NOTIFY_SOCKET") do
      p when is_binary(p) and p != "" -> {:ok, p}
      _ -> :disabled
    end
  end

  # systemd setzt WATCHDOG_USEC aus WatchdogSec. Ping auf der Hälfte des
  # Intervalls (sd_watchdog_enabled(3)-Empfehlung), min. 1s.
  defp watchdog_interval_ms do
    case System.get_env("WATCHDOG_USEC") do
      usec when is_binary(usec) and usec != "" ->
        case Integer.parse(usec) do
          {n, _} when n > 0 -> {:ok, max(div(n, 2_000), 1_000)}
          _ -> :disabled
        end

      _ ->
        :disabled
    end
  end

  defp open_socket do
    :socket.open(:local, :dgram)
  end

  # Abstract Socket (`@name`) → Null-Byte-Prefix im AF_UNIX-Namespace.
  defp socket_addr("@" <> rest), do: %{family: :local, path: <<0>> <> rest}
  defp socket_addr(path), do: %{family: :local, path: path}
end
