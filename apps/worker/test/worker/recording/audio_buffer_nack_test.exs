defmodule Worker.Recording.AudioBufferNackTest do
  @moduledoc """
  Issue #772: Wrong-Worker-Drop sichtbar machen. Kriegt ein Worker einen Chunk
  für eine Session, die er nicht hält (kein offener Sink), verwirft der
  `AudioBuffer` ihn — meldet den Drop aber per `Worker.HubClient.audio_nack/2`
  an den Hub, statt ihn still zu schlucken.

  Der HubClient-Stub forwardet hier alle empfangenen Nachrichten an den Test,
  damit `audio_nack` (bzw. dessen Abwesenheit) beobachtbar ist.
  """

  use ExUnit.Case, async: false

  alias Worker.Recording.AudioBuffer

  setup do
    {:atomic, :ok} = :mnesia.clear_table(Worker.Schema.Mnesia.worker_state())

    test_pid = self()
    stub = spawn(fn -> forward_loop(test_pid) end)
    Process.register(stub, Worker.HubClient)

    {:ok, ab} = AudioBuffer.start_link(:test)

    dir = Path.join(System.tmp_dir!(), "lore_audio_nack_#{System.unique_integer([:positive])}")
    :ok = Worker.Settings.put(:audio_dir, dir)
    Application.put_env(:worker, :env, :prod)

    on_exit(fn ->
      if Process.alive?(ab), do: GenServer.stop(ab, :normal)
      if Process.alive?(stub), do: Process.exit(stub, :kill)
      File.rm_rf!(dir)
      Application.delete_env(:worker, :env)
    end)

    %{}
  end

  # Forwardet jede HubClient-Nachricht (audio_nack, session_held, publish_status …)
  # an den Test-Prozess. Antwortet auf nichts — genau wie der No-Op-Stub in den
  # anderen AudioBuffer-Tests (publish_status/announce_* sind alle fire-and-forget).
  defp forward_loop(test_pid) do
    receive do
      msg -> send(test_pid, {:hubclient, msg})
    end

    forward_loop(test_pid)
  end

  test "Chunk für UNBEKANNTE Session → HubClient.audio_nack an den Hub" do
    # Kein open_session → diesem Worker ist die Session unbekannt (kein Sink).
    AudioBuffer.append("ghost-session", "did-alice", :per_player, Base.encode64("opus-bytes"))
    # streamers/1 (call) flusht den vorangegangenen append-cast.
    assert AudioBuffer.streamers("ghost-session") == []

    assert_receive {:hubclient, {:audio_nack, "ghost-session", "did-alice"}}, 1_000
  end

  test "Chunk für OFFENE Session → KEIN audio_nack (normaler Schreibpfad)" do
    assert :ok = AudioBuffer.open_session("real-session", "camp")
    AudioBuffer.append("real-session", "did-bob", :per_player, Base.encode64("opus-bytes"))
    # flush
    assert AudioBuffer.streamers("real-session") == ["did-bob"]

    refute_receive {:hubclient, {:audio_nack, "real-session", _}}, 300
  end
end
