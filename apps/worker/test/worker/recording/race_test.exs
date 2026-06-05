defmodule Worker.Recording.RaceTest do
  @moduledoc """
  Issue #233: Race-Condition zwischen `AudioBuffer.finalize/1` (das den
  Transcribe-Task async startet) und einem späten Hub-Push `stop_recording`,
  der bei `:not_recording`-Antwort einen Fallback-`SessionEnded` publisht.

  Vor dem Fix: doppelter SessionEnded → Pipeline läuft 2× mit halbem
  Transcript.

  Nach dem Fix: Während ein Transcribe-Task pending ist, returnt
  `AudioBuffer.has_pending_transcribe?/1 == true` und der HubClient
  unterdrückt den Fallback.

  Issue #577: Test war CI-flaky. Zwei Ursachen behoben:
  1. Die `setup` linkte `Worker.TaskSupervisor` via `start_link` an den
     Test-Prozess → der Supervisor starb nach dem Test, und später laufende
     Tests (GpuQueue/Pipeline) crashten beim Call gegen den toten Namen
     (`no process`). Jetzt `start_supervised!` (ExUnit-managed, deterministisch
     pro Test gestartet + abgebaut).
  2. `Process.sleep(N) + refute` war timing-abhängig → auf langsamer CI war
     der `:DOWN` noch nicht gehandelt, wenn die Assertion lief. Jetzt
     deterministisches `wait_until/1`-Polling.
  """

  use ExUnit.Case, async: false

  alias Worker.Recording.AudioBuffer

  setup do
    ensure_supervised!({Task.Supervisor, name: Worker.TaskSupervisor})
    ensure_supervised!(AudioBuffer)
    :ok
  end

  # start_supervised, tolerant gegen einen schon laufenden (von einem vorherigen
  # async:false-Test geleakten) Prozess — sonst würde ein Leak-Restzustand den
  # Test fälschlich rot färben statt ihn robust zu machen.
  defp ensure_supervised!(child) do
    case start_supervised(child) do
      {:ok, _} -> :ok
      {:error, {{:already_started, _}, _}} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, reason} -> raise "konnte #{inspect(child)} nicht starten: #{inspect(reason)}"
    end
  end

  # Pollt `fun` bis true oder Timeout — ersetzt fixe Sleeps, die unter
  # CI-Timing flakten.
  defp wait_until(fun, timeout \\ 2_000, interval \\ 10)
  defp wait_until(_fun, timeout, _interval) when timeout <= 0, do: :timeout

  defp wait_until(fun, timeout, interval) do
    if fun.() do
      :ok
    else
      Process.sleep(interval)
      wait_until(fun, timeout - interval, interval)
    end
  end

  test "has_pending_transcribe?/1 ist false für unbekannte Session" do
    refute AudioBuffer.has_pending_transcribe?("unknown-session-id")
  end

  test "has_pending_transcribe?/1 ist true solange supervised Task läuft" do
    # Simuliere einen Pending-Transcribe via direkten GenServer-Cast: wir
    # spawnen einen sleeper Task über den Worker.TaskSupervisor, fügen ihn
    # in den pending_transcribes-State ein.
    session_id = "test-pending-session-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Task.Supervisor.start_child(Worker.TaskSupervisor, fn ->
        Process.sleep(500)
      end)

    # Wir injizieren via :sys.replace_state — Test-Hack, sonst müssten wir
    # einen echten finalize-Flow nachstellen mit Mnesia-Sessions etc.
    :sys.replace_state(AudioBuffer, fn state ->
      Process.monitor(pid)
      %{state | pending_transcribes: Map.put(state.pending_transcribes, pid, session_id)}
    end)

    assert AudioBuffer.has_pending_transcribe?(session_id)

    # Deterministisch warten bis Task fertig + :DOWN gehandelt — kein fixes Sleep.
    assert wait_until(fn -> not AudioBuffer.has_pending_transcribe?(session_id) end) == :ok
  end

  test "DOWN-Message räumt pending_transcribes auf auch bei Crash" do
    session_id = "test-crash-session-#{System.unique_integer([:positive])}"

    # Spawne Task der crasht
    {:ok, pid} =
      Task.Supervisor.start_child(Worker.TaskSupervisor, fn ->
        Process.sleep(50)
        raise "simulated transcribe crash"
      end)

    :sys.replace_state(AudioBuffer, fn state ->
      Process.monitor(pid)
      %{state | pending_transcribes: Map.put(state.pending_transcribes, pid, session_id)}
    end)

    assert AudioBuffer.has_pending_transcribe?(session_id)

    # Deterministisch warten bis Task crashed + AudioBuffer den :DOWN gehandelt hat.
    assert wait_until(fn -> not AudioBuffer.has_pending_transcribe?(session_id) end) == :ok
  end
end
