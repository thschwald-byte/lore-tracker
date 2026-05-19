defmodule Worker.Recording.AudioBufferTest do
  @moduledoc """
  Smoke tests for AudioBuffer's `open_session/2`, focused on the
  `:listen`-mode dev gate.

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

  describe "open_session/2 — listen mode" do
    test "refuses :listen in prod env" do
      Application.put_env(:worker, :env, :prod)
      :ok = Settings.put(:transcribe_mode, :listen)

      assert {:error, :listen_in_prod} =
               AudioBuffer.open_session("test-session-1", "test-campaign")
    end

    test "accepts :listen in dev env" do
      Application.put_env(:worker, :env, :dev)
      :ok = Settings.put(:transcribe_mode, :listen)

      assert :ok = AudioBuffer.open_session("test-session-2", "test-campaign")
    end

    test "accepts :listen in test env (any non-prod)" do
      Application.put_env(:worker, :env, :test)
      :ok = Settings.put(:transcribe_mode, :listen)

      assert :ok = AudioBuffer.open_session("test-session-3", "test-campaign")
    end

    test ":batch in prod is always fine" do
      Application.put_env(:worker, :env, :prod)
      :ok = Settings.put(:transcribe_mode, :batch)

      assert :ok = AudioBuffer.open_session("test-session-4", "test-campaign")
    end
  end
end
