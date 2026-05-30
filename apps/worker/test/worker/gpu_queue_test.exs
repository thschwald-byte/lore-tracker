defmodule Worker.GpuQueueTest do
  @moduledoc """
  Issue #292: strikt-serielle Job-Queue für GPU/CPU-schwere Operationen.
  """

  use ExUnit.Case, async: false

  alias Worker.GpuQueue

  setup do
    # Worker.TaskSupervisor wird vom Application gestartet; falls Tests in
    # Isolation laufen (nur dieser ExUnit-Fall), sicherstellen dass beide
    # Prozesse da sind.
    ensure_started(Worker.TaskSupervisor, fn ->
      Task.Supervisor.start_link(name: Worker.TaskSupervisor)
    end)

    ensure_started(Worker.GpuQueue, fn -> GpuQueue.start_link([]) end)

    :ok
  end

  defp ensure_started(name, starter) do
    case Process.whereis(name) do
      nil ->
        case starter.() do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _}} -> :ok
        end

      _pid ->
        :ok
    end
  end

  test "serialisiert zwei parallele Jobs (jeder ≥ 100ms)" do
    parent = self()

    Task.async(fn ->
      send(parent, {:result, GpuQueue.run(fn -> :timer.sleep(100); System.monotonic_time(:millisecond) end, label: "a")})
    end)

    Task.async(fn ->
      send(parent, {:result, GpuQueue.run(fn -> :timer.sleep(100); System.monotonic_time(:millisecond) end, label: "b")})
    end)

    assert_receive {:result, ts1}, 5_000
    assert_receive {:result, ts2}, 5_000

    diff = abs(ts2 - ts1)

    assert diff >= 80,
           "expected jobs to be serialized (≥80ms apart), got #{diff}ms — Queue ist nicht strikt seriell?"
  end

  test "behält FIFO-Ordnung über enqueue/3" do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    for i <- 1..3 do
      GpuQueue.enqueue(
        fn ->
          :timer.sleep(20)
          Agent.update(agent, fn list -> list ++ [i] end)
        end,
        label: "fifo:#{i}"
      )
    end

    # Letzten Job sync abwarten — danach sind alle drei durch.
    GpuQueue.run(fn -> :ok end, label: "barrier")

    assert Agent.get(agent, & &1) == [1, 2, 3]
  end

  test "sync-Crash returnt {:error, …} und blockiert die Queue nicht" do
    result = GpuQueue.run(fn -> raise "boom" end, label: "crash-sync")
    assert {:error, {%RuntimeError{message: "boom"}, _stack}} = result

    # Nachfolgender Job läuft normal durch.
    assert GpuQueue.run(fn -> 42 end, label: "after-crash") == 42
  end

  test "async-Crash blockiert die Queue nicht" do
    GpuQueue.enqueue(fn -> raise "async-boom" end, label: "crash-async")
    # Sync-Job nach dem Crash muss durchgehen.
    assert GpuQueue.run(fn -> :ok end, label: "after-async-crash") == :ok
  end

  test "status zeigt depth + running" do
    # Idle: depth=0, running=nil.
    assert %{depth: 0, running: nil} = GpuQueue.status()

    parent = self()

    Task.async(fn ->
      GpuQueue.run(
        fn ->
          send(parent, :inside)
          :timer.sleep(150)
        end,
        label: "status-job"
      )
    end)

    assert_receive :inside, 1_000
    %{running: running, depth: _} = GpuQueue.status()
    assert running != nil
    assert running.label == "status-job"

    # Warte bis fertig.
    GpuQueue.run(fn -> :ok end, label: "barrier")
    assert %{depth: 0, running: nil} = GpuQueue.status()
  end
end
