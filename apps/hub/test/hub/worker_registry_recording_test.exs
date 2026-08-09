defmodule Hub.WorkerRegistryRecordingTest do
  @moduledoc """
  Issue #703: WorkerRegistry.any_active_recording?/0 — Deploy-Gate-Signal.
  Nutzt dasselbe held_sessions-Tracking wie #468, keine neue State-Quelle.
  """

  use ExUnit.Case, async: false

  alias Hub.WorkerRegistry

  defp track_and_hold(worker_id, session_id) do
    parent = self()

    pid =
      spawn_link(fn ->
        {:ok, _} = WorkerRegistry.track(worker_id, "admin-test")

        if session_id do
          {:ok, _} = WorkerRegistry.add_held_session(worker_id, session_id)
        end

        send(parent, :tracked)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :tracked, 2_000
    pid
  end

  defp wait_until(fun) do
    Enum.reduce_while(1..50, false, fn _, _ ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(20)
        {:cont, false}
      end
    end)
  end

  test "kein Worker verbunden -> false" do
    refute WorkerRegistry.any_active_recording?()
  end

  test "Worker verbunden, aber ohne held_sessions -> false" do
    worker_id = "w-rec-empty-#{System.unique_integer([:positive])}"
    pid = track_and_hold(worker_id, nil)

    wait_until(fn ->
      Enum.any?(WorkerRegistry.list(), fn {id, _} -> id == worker_id end)
    end)

    refute WorkerRegistry.any_active_recording?()
    send(pid, :stop)
  end

  test "ein Worker hält eine Session -> true" do
    worker_id = "w-rec-holds-#{System.unique_integer([:positive])}"
    pid = track_and_hold(worker_id, "sess-1")

    wait_until(fn -> WorkerRegistry.any_active_recording?() end)

    assert WorkerRegistry.any_active_recording?()
    send(pid, :stop)
  end

  test "mehrere Worker, nur einer hält eine Session -> true" do
    idle_id = "w-rec-idle-#{System.unique_integer([:positive])}"
    holder_id = "w-rec-holder-#{System.unique_integer([:positive])}"

    idle_pid = track_and_hold(idle_id, nil)
    holder_pid = track_and_hold(holder_id, "sess-2")

    wait_until(fn ->
      Enum.any?(WorkerRegistry.list(), fn {id, meta} ->
        id == holder_id and MapSet.size(Map.get(meta, :held_sessions, MapSet.new())) > 0
      end)
    end)

    assert WorkerRegistry.any_active_recording?()
    send(idle_pid, :stop)
    send(holder_pid, :stop)
  end
end
