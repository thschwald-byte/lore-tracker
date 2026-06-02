defmodule Worker.Recording.AudioBufferTest do
  @moduledoc """
  Smoke tests for AudioBuffer's `open_session/2,3` (mode resolution +
  single-source recording).

  AudioBuffer is a named GenServer; we restart a fresh instance per test
  to keep session state clean.
  """

  use ExUnit.Case, async: false

  alias Worker.Recording.AudioBuffer
  alias Worker.Settings

  setup do
    {:atomic, :ok} = :mnesia.clear_table(Worker.Schema.Mnesia.worker_state())

    # AudioBuffer fan-outs hit Worker.HubClient (publish_status) which is a
    # named GenServer that doesn't exist in the test. Register a no-op
    # stub under that name so the sends don't crash.
    hub_stub = stub_named_process(Worker.HubClient)

    {:ok, pid} = AudioBuffer.start_link(:test)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal)
      if hub_stub && Process.alive?(hub_stub), do: Process.exit(hub_stub, :kill)
      Application.delete_env(:worker, :env)
    end)

    %{audio_buffer: pid}
  end

  defp stub_named_process(name) do
    case Process.whereis(name) do
      nil ->
        pid = spawn(fn -> stub_loop() end)
        Process.register(pid, name)
        pid

      _ ->
        nil
    end
  end

  defp stub_loop do
    receive do
      _ -> stub_loop()
    end
  end

  describe "open_session/2 — default (batch) mode" do
    test "default mode is always accepted (kein listen-gate mehr, #418)" do
      Application.put_env(:worker, :env, :prod)
      assert :ok = AudioBuffer.open_session("test-session-batch", "test-campaign")
    end
  end

  describe "open_session/3 — :single_source mode (Issue #19)" do
    test "schreibt alle Chunks in EINE Datei, egal welche discord_id" do
      dir = Path.join(System.tmp_dir!(), "lore_audio_test_#{System.unique_integer([:positive])}")
      :ok = Settings.put(:audio_dir, dir)
      Application.put_env(:worker, :env, :prod)

      sid = "ss-session"
      assert :ok = AudioBuffer.open_session(sid, "camp", :single_source)

      # Zwei verschiedene discord_ids — beide müssen in single_source.webm landen.
      chunk = Base.encode64("opus-bytes-here")
      AudioBuffer.append(sid, "did-alice", chunk)
      AudioBuffer.append(sid, "did-bob", chunk)

      # streamers/1 ist ein call → flusht die vorangegangenen casts.
      streamers = AudioBuffer.streamers(sid)
      assert streamers == ["single_source"]

      files = File.ls!(Path.join(dir, sid)) |> Enum.reject(&(&1 == "live"))
      assert files == ["single_source.webm"]

      File.rm_rf!(dir)
    end

    test ":single_source ist in prod erlaubt (kein listen-gate)" do
      Application.put_env(:worker, :env, :prod)
      assert :ok = AudioBuffer.open_session("ss-prod", "camp", :single_source)
    end
  end
end
