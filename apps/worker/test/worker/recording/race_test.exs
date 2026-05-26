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
  """

  use ExUnit.Case, async: false

  alias Worker.Recording.AudioBuffer

  setup do
    # Test.Supervisor starten falls in einer reinen Test-Umgebung noch nicht da
    case Task.Supervisor.start_link(name: Worker.TaskSupervisor) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    # AudioBuffer starten falls noch nicht laufend
    case AudioBuffer.start_link([]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
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

    # Warten bis Task fertig ist + DOWN-Message gehandelt
    Process.sleep(700)

    refute AudioBuffer.has_pending_transcribe?(session_id)
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

    # Warten bis Task crashed + AudioBuffer den :DOWN gehandelt hat
    Process.sleep(200)

    refute AudioBuffer.has_pending_transcribe?(session_id)
  end
end
