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

  test "move_up tauscht mit Vorgänger; move_down mit Nachfolger" do
    # Erstmal die Queue blockieren mit einem langsamen Job, damit unsere
    # Test-Enqueues nicht direkt loslaufen.
    parent = self()

    Task.async(fn ->
      GpuQueue.run(
        fn ->
          send(parent, :blocker_started)
          :timer.sleep(800)
        end,
        label: "blocker"
      )
    end)

    assert_receive :blocker_started, 1_000

    # Drei Jobs in Reihenfolge enqueuen.
    for label <- ["a", "b", "c"] do
      GpuQueue.enqueue(fn -> :ok end, label: label)
    end

    %{queue: q1} = GpuQueue.list()
    assert Enum.map(q1, & &1.label) == ["a", "b", "c"]
    [_, mid, _] = q1

    # move_up von "b" → ["b", "a", "c"]
    assert :ok = GpuQueue.move_up(mid.job_id)
    %{queue: q2} = GpuQueue.list()
    assert Enum.map(q2, & &1.label) == ["b", "a", "c"]

    # move_down von "b" (jetzt index 0) → ["a", "b", "c"]
    assert :ok = GpuQueue.move_down(mid.job_id)
    %{queue: q3} = GpuQueue.list()
    assert Enum.map(q3, & &1.label) == ["a", "b", "c"]

    # Cleanup: warten bis alles durch ist.
    GpuQueue.run(fn -> :ok end, label: "barrier")
  end

  test "cancel entfernt einen wartenden Job" do
    parent = self()

    Task.async(fn ->
      GpuQueue.run(
        fn ->
          send(parent, :blocker_started)
          :timer.sleep(800)
        end,
        label: "blocker-cancel"
      )
    end)

    assert_receive :blocker_started, 1_000

    GpuQueue.enqueue(fn -> :ok end, label: "to-cancel-1")
    GpuQueue.enqueue(fn -> :ok end, label: "to-cancel-2")

    %{queue: [j1, _j2]} = GpuQueue.list()
    assert :ok = GpuQueue.cancel(j1.job_id)

    %{queue: q} = GpuQueue.list()
    assert Enum.map(q, & &1.label) == ["to-cancel-2"]

    # Unbekannter Job-ID → :not_found.
    assert {:error, :not_found} = GpuQueue.cancel("ghost-job-id")

    GpuQueue.run(fn -> :ok end, label: "barrier")
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
