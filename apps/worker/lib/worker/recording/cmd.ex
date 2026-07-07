defmodule Worker.Recording.Cmd do
  @moduledoc """
  Runner für externe Stage-1-Tools (ffmpeg / whisper-cli / VAD) mit hartem
  Timeout **und echtem OS-Prozess-Kill** (Issue #470/#704).

  FRÜHER lief das über `Task.async` + `System.cmd` + `Task.shutdown(:brutal_kill)`
  in `Worker.Recording.Transcribe`. Das killt aber nur den BEAM-Task, NICHT den
  OS-Prozess: eine datei-lesende ffmpeg (kein stdin) ignoriert den Port-Close und
  lief als **Orphan** weiter (#704: schrieb die WAV nach dem „Timeout" fertig).

  JETZT Port-basiert: der Port exponiert `os_pid` → bei Timeout `kill -9`. Killt
  auch hängende whisper/vad wirklich (OS-Level) statt sie nur zu detachen. In ein
  eigenes Modul gezogen (#704), damit `Transcribe` unter der God-Module-Grenze
  (#544) bleibt und der Runner direkt testbar ist.

  Wall-Clock-Deadline (kein per-Message-`after`): whisper/ffmpeg streamen
  `{:data,_}`-Chunks; ein per-Message-Timeout würde bei jedem Chunk resetten und
  nie feuern. `remaining` wird pro Loop aus der absoluten Deadline berechnet.

  Rückgabe: `{:ok, stdout}` | `{:error, {:exit, code, out}}` |
  `{:error, {:exception, msg}}` | `{:error, {:timeout, ms}}`.
  """
  require Logger

  @spec run(String.t(), [String.t()], pos_integer()) ::
          {:ok, binary()}
          | {:error, {:exit, integer(), binary()}}
          | {:error, {:exception, String.t()}}
          | {:error, {:timeout, pos_integer()}}
  def run(bin, args, timeout_ms) do
    exec = System.find_executable(bin) || bin

    port =
      Port.open({:spawn_executable, exec}, [
        :binary,
        :exit_status,
        :hide,
        :stderr_to_stdout,
        args: args
      ])

    ref = Port.monitor(port)
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    collect_port(port, ref, deadline, timeout_ms, [])
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  defp collect_port(port, ref, deadline, timeout_ms, acc) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {^port, {:data, data}} ->
        collect_port(port, ref, deadline, timeout_ms, [acc, data])

      {^port, {:exit_status, code}} ->
        Port.demonitor(ref, [:flush])
        out = IO.iodata_to_binary(acc)
        if code == 0, do: {:ok, out}, else: {:error, {:exit, code, out}}

      {:DOWN, ^ref, :port, ^port, reason} ->
        {:error, {:exception, "port down: #{inspect(reason)}"}}
    after
      remaining ->
        kill_port_os_process(port)
        Port.demonitor(ref, [:flush])
        flush_port_messages(port)
        {:error, {:timeout, timeout_ms}}
    end
  end

  # Killt den OS-Prozess hinter dem Port hart (SIGKILL — der Prozess hängt evtl.
  # in einem Read/GPU-Stall und reagiert nicht auf SIGTERM). Linux-Target.
  # BEST-EFFORT: ein fehlendes/nicht-auflösbares `kill`-Binary (minimaler
  # Container ohne procps/util-linux) darf das {:timeout}-Ergebnis NICHT zu
  # einem {:exception,:enoent} verfälschen — deshalb try/rescue drumherum.
  defp kill_port_os_process(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        try do
          System.cmd(System.find_executable("kill") || "kill", [
            "-9",
            Integer.to_string(os_pid)
          ])
        rescue
          _ -> :ok
        end

      _ ->
        :ok
    end

    try do
      Port.close(port)
    rescue
      _ -> :ok
    end
  end

  defp flush_port_messages(port) do
    receive do
      {^port, _} -> flush_port_messages(port)
    after
      0 -> :ok
    end
  end
end
