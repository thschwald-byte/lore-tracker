defmodule Worker.GpuQueueTest do
  @moduledoc """
  Issue #292: strikt-serielle Job-Queue für GPU/CPU-schwere Operationen.
  Issue #355: Live-Lane (high priority) + Background-Pause während aktiver
  Aufnahme.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.GpuQueue

  setup do
    # Worker.TaskSupervisor + Worker.PubSub werden vom Application gestartet;
    # falls Tests in Isolation laufen, sicherstellen dass alle drei Prozesse da
    # sind (PubSub wird vom GpuQueue.init für `recording_state` gebraucht).
    ensure_started(Worker.TaskSupervisor, fn ->
      Task.Supervisor.start_link(name: Worker.TaskSupervisor)
    end)

    ensure_started(Worker.PubSub, fn ->
      Phoenix.PubSub.Supervisor.start_link(name: Worker.PubSub)
    end)

    # Stop GpuQueue if it's running, restart it with recording_active? = false
    # to ensure clean state for each test.
    if Process.whereis(Worker.GpuQueue) do
      GenServer.stop(Worker.GpuQueue)
    end

    # Issue #476: GpuQueue.init liest any_active_recording? aus Mnesia. Ohne
    # Clear erbt der Test eine ggf. in priv/mnesia/test persistierte
    # :recording-Session (z.B. aus einem mid-Test gekillten Recording-Test) →
    # recording_active? = true → Background-Lane dauerhaft pausiert → Jobs laufen
    # nie → Timeout. Tabellen VOR start_link leeren, damit init deterministisch
    # recording_active? = false sieht — unabhängig vom vorherigen Mnesia-Inhalt.
    clear_all_tables!()

    {:ok, _pid} = GpuQueue.start_link([])

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

  describe "Phase 1 — strikt-serielle Background-Queue" do
    test "serialisiert zwei parallele Jobs (jeder ≥ 100ms Abstand)" do
      parent = self()

      Task.async(fn ->
        send(parent, {:result, GpuQueue.run(fn ->
          :timer.sleep(100)
          System.monotonic_time(:millisecond)
        end, label: "a")})
      end)

      Task.async(fn ->
        send(parent, {:result, GpuQueue.run(fn ->
          :timer.sleep(100)
          System.monotonic_time(:millisecond)
        end, label: "b")})
      end)

      assert_receive {:result, ts1}, 5_000
      assert_receive {:result, ts2}, 5_000

      diff = abs(ts2 - ts1)
      assert diff >= 80, "Jobs nicht seriell: nur #{diff}ms Abstand"
    end

    test "FIFO-Ordnung über enqueue/2" do
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

      GpuQueue.run(fn -> :ok end, label: "barrier")
      assert Agent.get(agent, & &1) == [1, 2, 3]
    end

    test "sync-Crash returnt {:error, …} und blockiert die Queue nicht" do
      result = GpuQueue.run(fn -> raise "boom" end, label: "crash-sync")
      assert {:error, {%RuntimeError{message: "boom"}, _stack}} = result
      assert GpuQueue.run(fn -> 42 end, label: "after-crash") == 42
    end

    test "async-Crash blockiert die Queue nicht" do
      GpuQueue.enqueue(fn -> raise "async-boom" end, label: "crash-async")
      assert GpuQueue.run(fn -> :ok end, label: "after-async-crash") == :ok
    end

    test "status zeigt depth + running" do
      assert %{live_depth: 0, bg_depth: 0, running: nil} = GpuQueue.status()

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
      %{running: running} = GpuQueue.status()
      assert running != nil
      assert running.label == "status-job"

      GpuQueue.run(fn -> :ok end, label: "barrier")
      assert %{bg_depth: 0, running: nil} = GpuQueue.status()
    end

    test "move_up tauscht mit Vorgänger; move_down mit Nachfolger" do
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

      for label <- ["a", "b", "c"] do
        GpuQueue.enqueue(fn -> :ok end, label: label)
      end

      %{bg_queue: q1} = GpuQueue.list()
      assert Enum.map(q1, & &1.label) == ["a", "b", "c"]
      [_, mid, _] = q1

      assert :ok = GpuQueue.move_up(mid.job_id)
      %{bg_queue: q2} = GpuQueue.list()
      assert Enum.map(q2, & &1.label) == ["b", "a", "c"]

      assert :ok = GpuQueue.move_down(mid.job_id)
      %{bg_queue: q3} = GpuQueue.list()
      assert Enum.map(q3, & &1.label) == ["a", "b", "c"]

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

      %{bg_queue: [j1, _j2]} = GpuQueue.list()
      assert :ok = GpuQueue.cancel(j1.job_id)

      %{bg_queue: q} = GpuQueue.list()
      assert Enum.map(q, & &1.label) == ["to-cancel-2"]

      assert {:error, :not_found} = GpuQueue.cancel("ghost-job-id")

      GpuQueue.run(fn -> :ok end, label: "barrier")
    end
  end

  describe "Phase 3 — Live-Lane + Recording-Pause" do
    test "Live überholt Background nach laufendem Background-Job" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      parent = self()

      # Blocker (synchron startend) — sleep 300ms damit wir Zeit für Enqueues haben.
      Task.async(fn ->
        GpuQueue.run(
          fn ->
            send(parent, :blocker_started)
            :timer.sleep(300)
            Agent.update(agent, fn l -> l ++ ["blocker"] end)
          end,
          label: "bg-blocker"
        )
      end)

      assert_receive :blocker_started, 1_000

      # 2 Background-Jobs enqueuen.
      for i <- 1..2 do
        GpuQueue.enqueue(
          fn -> Agent.update(agent, fn l -> l ++ ["bg-#{i}"] end) end,
          label: "bg-#{i}"
        )
      end

      # 1 Live-Job zwischendurch enqueuen — sollte die 2 Background überholen.
      GpuQueue.enqueue(
        fn -> Agent.update(agent, fn l -> l ++ ["live-1"] end) end,
        label: "live-1",
        priority: :live
      )

      # Warten bis alles durch ist.
      GpuQueue.run(fn -> :ok end, label: "barrier")

      order = Agent.get(agent, & &1)
      # Erwartung: blocker → live-1 → bg-1 → bg-2.
      assert order == ["blocker", "live-1", "bg-1", "bg-2"]
    end

    test "Live wartet auf bereits laufenden Background (kein Preempt)" do
      parent = self()

      Task.async(fn ->
        GpuQueue.run(
          fn ->
            send(parent, :bg_started)
            :timer.sleep(300)
            send(parent, :bg_done)
          end,
          label: "bg-long"
        )
      end)

      assert_receive :bg_started, 1_000

      Task.async(fn ->
        GpuQueue.run(
          fn -> send(parent, :live_done) end,
          label: "live-after",
          priority: :live
        )
      end)

      # Live darf NICHT vor bg_done abschließen — by-design kein Preempt.
      assert_receive :bg_done, 2_000
      assert_receive :live_done, 1_000
    end

    test "Recording-Pause: Background-Jobs warten, Live läuft" do
      # Simuliere Recording-Start via Broadcast.
      Phoenix.PubSub.broadcast(Worker.PubSub, "recording_state", {:recording_state_changed, true})
      :timer.sleep(50)
      assert %{recording_active?: true} = GpuQueue.status()

      {:ok, agent} = Agent.start_link(fn -> [] end)

      # 2 Background-Jobs enqueuen — sollten warten.
      for i <- 1..2 do
        GpuQueue.enqueue(
          fn -> Agent.update(agent, fn l -> l ++ ["bg-#{i}"] end) end,
          label: "bg-paused-#{i}"
        )
      end

      # Live-Job dazwischen — sollte trotz Recording sofort laufen.
      GpuQueue.run(
        fn -> Agent.update(agent, fn l -> l ++ ["live-during-rec"] end) end,
        label: "live-during-rec",
        priority: :live
      )

      # Background-Queue ist immer noch voll.
      %{bg_depth: bg, live_depth: live} = GpuQueue.status()
      assert bg == 2
      assert live == 0
      assert Agent.get(agent, & &1) == ["live-during-rec"]

      # Recording endet → Background drained.
      Phoenix.PubSub.broadcast(Worker.PubSub, "recording_state", {:recording_state_changed, false})
      GpuQueue.run(fn -> :ok end, label: "barrier")

      order = Agent.get(agent, & &1)
      assert order == ["live-during-rec", "bg-1", "bg-2"]
    end

    test "Recording-Mid-Flight: laufender Background läuft fertig (kein Kill)" do
      parent = self()

      Task.async(fn ->
        GpuQueue.run(
          fn ->
            send(parent, :bg_started)
            :timer.sleep(300)
            send(parent, :bg_finished)
          end,
          label: "bg-midflight"
        )
      end)

      assert_receive :bg_started, 1_000

      # Recording-Start mid-flight.
      Phoenix.PubSub.broadcast(Worker.PubSub, "recording_state", {:recording_state_changed, true})

      # Background-Job läuft trotzdem fertig.
      assert_receive :bg_finished, 2_000

      # Nächster Background bleibt aber pausiert.
      GpuQueue.enqueue(fn -> raise "shouldn't run" end, label: "bg-after-rec")
      :timer.sleep(50)
      %{bg_depth: bg, running: running} = GpuQueue.status()
      assert bg == 1
      assert running == nil

      # Cleanup: Recording-Ende + cancel den pending Job.
      Phoenix.PubSub.broadcast(Worker.PubSub, "recording_state", {:recording_state_changed, false})
      :timer.sleep(50)
    end

    test "Default-Priority ist :background; live_queue separate Tiefe" do
      Phoenix.PubSub.broadcast(Worker.PubSub, "recording_state", {:recording_state_changed, true})
      :timer.sleep(50)

      # Ohne `priority` Opt → :background → wegen Recording pause.
      GpuQueue.enqueue(fn -> :ok end, label: "default-bg")
      :timer.sleep(50)

      assert %{bg_depth: 1, live_depth: 0, running: nil} = GpuQueue.status()

      # Cleanup.
      Phoenix.PubSub.broadcast(Worker.PubSub, "recording_state", {:recording_state_changed, false})
      GpuQueue.run(fn -> :ok end, label: "barrier")
    end
  end
end
