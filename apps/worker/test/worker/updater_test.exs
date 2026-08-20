defmodule Worker.UpdaterTest do
  @moduledoc """
  Issue #492: Entscheidungslogik des Self-Update-Updaters, isoliert getestet
  über `maybe_update/1` (@doc false public) + `idle?/0`. Der GenServer selbst
  wird NICHT gestartet — wir prüfen nur die reine Gate-Logik mit konstruierten
  State-Maps. „Update startet" wird daran erkannt, dass `updating?` true wird
  (ein Task wäre gestartet); „kein Update" daran, dass `updating?` false bleibt.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Updater

  defp state(overrides \\ %{}) do
    Map.merge(
      %{
        deploy_repo: "/tmp/nonexistent-deploy-repo",
        target_sha: nil,
        updating?: false,
        halting?: false,
        task_ref: nil,
        backoff_until: nil
      },
      overrides
    )
  end

  test "kein target_sha → kein Update" do
    s = Updater.maybe_update(state())
    refute s.updating?
  end

  test "target_sha == lokale sha → kein Update (aktuell)" do
    local = Worker.Version.current().sha
    s = Updater.maybe_update(state(%{target_sha: local}))
    refute s.updating?
  end

  test "bereits updating? → unverändert, kein zweiter Task" do
    s = Updater.maybe_update(state(%{updating?: true, target_sha: "deadbeef"}))
    assert s.updating?
    assert s.task_ref == nil
  end

  test "Backoff aktiv → kein Update trotz Drift" do
    future = System.monotonic_time(:millisecond) + 60_000
    s = Updater.maybe_update(state(%{target_sha: "deadbeef", backoff_until: future}))
    refute s.updating?
  end

  test "Drift aber nicht idle (Status-Server im Test nicht gestartet) → deferred, kein Update" do
    # Probelauf/CampaignReplay/GpuQueue laufen im Test nicht → idle? schlägt
    # defensiv auf false → maybe_update deferret statt zu updaten.
    s = Updater.maybe_update(state(%{target_sha: "deadbeef"}))
    refute s.updating?
  end

  test "idle?/0 crasht nicht wenn Status-GenServer fehlen und liefert einen Bool" do
    assert is_boolean(Updater.idle?())
  end

  # Issue #775: laufende Pipeline zählt als busy — vorher schoss der Update-Halt
  # einen laufenden Verify ab (Watchdog-ABRT 2026-07-09).
  test "Pipeline.busy?/0: false wenn nichts läuft (Roundtrip der Status-API)" do
    # Pipeline-GenServer läuft in dieser Suite nicht von allein — supervised
    # starten (Kill-Wait-Pattern nicht nötig, Name ist frei).
    start_supervised!(Worker.Recording.Pipeline)
    refute Worker.Recording.Pipeline.busy?()
  end

  # Issue #1055: der Idle-Check kannte die Transkription nicht. Er las
  # `recording_active?` — also ob eine AUFNAHME läuft, nicht ob ein GPU-Job
  # läuft. Ein Deploy während der Nach-Transkription schoss damit den
  # laufenden Whisper ab (real am 13.08.2026).
  describe "gpu_busy?/0 (#1055)" do
    setup do
      # Issue #476: GpuQueue.init liest `any_active_recording?` aus Mnesia.
      # Ohne Clear erbt der Test eine persistierte :recording-Session aus einem
      # anderen Testfile — die Queue startet dann mit pausierter Background-Lane
      # und `recording_active? == true`.
      clear_all_tables!()

      ensure_started(Worker.TaskSupervisor, fn ->
        Task.Supervisor.start_link(name: Worker.TaskSupervisor)
      end)

      ensure_started(Worker.PubSub, fn ->
        Phoenix.PubSub.Supervisor.start_link(name: Worker.PubSub)
      end)

      :ok
    end

    test "GpuQueue nicht erreichbar → konservativ busy (fail-closed)" do
      # Der abgelöste Check war hier fail-OPEN (`_ -> false`) und liess bei
      # hängender Queue ein Update durch — anders als `pipeline_busy?` daneben.
      if pid = Process.whereis(Worker.GpuQueue) do
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end

      assert Updater.gpu_busy?()
    end

    test "leere Queue, nichts läuft → nicht busy" do
      start_gpu_queue!()
      refute Updater.gpu_busy?()
    end

    test "laufender Job → busy (genau der Fall, der die Transkription abschoss)" do
      start_gpu_queue!()

      me = self()

      Worker.GpuQueue.enqueue(
        fn ->
          send(me, {:job_laeuft, self()})

          receive do
            :fertig -> :ok
          after
            5_000 -> :timeout
          end
        end,
        label: "transcribe:test"
      )

      assert_receive {:job_laeuft, job_pid}, 2_000
      assert Updater.gpu_busy?(), "ein laufender GPU-Job muss ein Update verhindern"

      # Zweiter Job wartet hinter dem ersten — auch WARTEN zählt, weil ein Halt
      # ihn ersatzlos verliert (die Queue hält Closures, nicht persistierbar).
      Worker.GpuQueue.enqueue(fn -> :ok end, label: "wartet")
      assert Updater.gpu_busy?()

      # Den blockierenden Job freigeben, statt ihn in sein Timeout laufen zu
      # lassen — sonst hängt er über das Testende hinaus in der Queue und der
      # nächste Test sähe sie fälschlich als belegt.
      send(job_pid, :fertig)
    end
  end

  defp start_gpu_queue! do
    if pid = Process.whereis(Worker.GpuQueue) do
      try do
        GenServer.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end

    start_supervised!(Worker.GpuQueue)
  end

  # Issue #512: Re-Halt-Race. Ist graceful_halt einmal ausgelöst (halting?),
  # darf KEIN weiteres Drift-Event (rapid Hub-Deploys) einen zweiten Update-/
  # Halt-Zyklus starten — der Node geht ohnehin runter.
  test "halting? gesetzt → kein zweites Update trotz frischer Drift" do
    s = Updater.maybe_update(state(%{halting?: true, target_sha: "deadbeef"}))
    refute s.updating?
    assert s.task_ref == nil
  end
end
