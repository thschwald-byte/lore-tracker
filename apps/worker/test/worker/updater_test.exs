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
    # CampaignReplay/GpuQueue laufen im Test nicht → idle? schlägt
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

  describe "frage_busy?/0 (#1259)" do
    alias Worker.Jack.Frage.{Dienst, Gespraech}

    setup do
      clear_all_tables!()

      ensure_started(Worker.TaskSupervisor, fn ->
        Task.Supervisor.start_link(name: Worker.TaskSupervisor)
      end)

      ensure_started(Dienst.registry(), fn ->
        Registry.start_link(keys: :unique, name: Dienst.registry())
      end)

      :ok
    end

    # Der Halter ist ein Singleton im Anwendungsbaum und überlebt Testdateien:
    # In der vollen Suite lagen Gespräche aus `dienst_test.exs` darin, und
    # `anzahl() == 1` war eine Annahme über fremden Zustand. Geleert wird
    # deshalb beim Start, nicht gezählt was zufällig übrig ist.
    defp start_gespraech! do
      ensure_started(Gespraech, fn -> Gespraech.start_link([]) end)
      :sys.replace_state(Process.whereis(Gespraech), fn _ -> %{} end)
      :ok
    end

    test "Gespraech-Prozess nicht erreichbar → konservativ busy (fail-closed)" do
      # Wie bei `gpu_busy?`: ein hängender Prozess darf kein Update
      # durchlassen. Die Gegenrichtung wäre schlimmer — ein Update mitten im
      # Gespräch verliert den Verlauf still.
      if pid = Process.whereis(Gespraech) do
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end

      assert Updater.frage_busy?()
    end

    test "nichts läuft, kein Gespräch → nicht busy" do
      start_gespraech!()
      refute Updater.frage_busy?()
    end

    test "ein offenes Gespräch verhindert das Update — auch ohne laufenden Job" do
      # DER Fall dieses Tickets: Zwischen zwei Fragen rechnet nichts. Ohne
      # diesen Riegel hielte sich der Worker für untätig, startete neu, und der
      # Verlauf wäre weg — im Fenster stünde weiter „Chat max 3".
      start_gespraech!()
      refute Updater.frage_busy?()

      Gespraech.merken("g-offen", %{auftrag: "A", verlauf: [%{role: :user, content: "x"}]})
      # Der Merk-Weg ist ein Cast; auf die Antwort des nächsten Calls warten.
      assert Gespraech.anzahl() == 1

      assert Updater.frage_busy?(), "ein offenes Gespräch muss ein Update verhindern"

      Gespraech.verwerfen("g-offen")
      assert Gespraech.anzahl() == 0
      refute Updater.frage_busy?()
    end

    test "ein verfallenes Gespräch zählt NICHT mehr" do
      # Sonst hielte ein Eintrag, den der Sweep noch nicht geholt hat, das
      # Update bis zu fünf Minuten länger auf, ohne dass es jemandem nützt.
      start_gespraech!()

      Gespraech.merken("g-alt", %{auftrag: "A", verlauf: []})
      assert Gespraech.anzahl() == 1

      :sys.replace_state(Process.whereis(Gespraech), fn st ->
        Map.update!(
          st,
          "g-alt",
          &%{&1 | ts: System.monotonic_time(:millisecond) - 10 * Gespraech.ttl_ms()}
        )
      end)

      refute Updater.frage_busy?()
      assert Gespraech.anzahl() == 1, "gezählt wird gegen die Frist, nicht gelöscht"
    end

    test "ein registrierter Lauf verhindert das Update, auch vor dem Karten-Erwerb" do
      # Zwischen `Registry.register` und `GpuQueue.run_frei` ist die Karte frei
      # und der Task existiert trotzdem. `gpu_busy?` sieht dieses Fenster nicht.
      start_gespraech!()
      refute Updater.frage_busy?()

      me = self()

      task =
        Task.async(fn ->
          {:ok, _} = Registry.register(Dienst.registry(), "lauf-1", :frage)
          send(me, :registriert)

          receive do
            :fertig -> :ok
          after
            5_000 -> :timeout
          end
        end)

      assert_receive :registriert, 2_000
      assert Updater.frage_busy?(), "ein registrierter Frage-Lauf muss ein Update verhindern"

      send(task.pid, :fertig)
      Task.await(task)
    end
  end

  describe "die Verdrahtung (#1259)" do
    @updater "lib/worker/updater.ex"

    test "idle?/0 ruft frage_busy?/0 — ohne das ist der Riegel wirkungslos" do
      # Ein fehlender Aufruf erzeugt keinen Fehler: `frage_busy?/0` wäre nur
      # eine Funktion, die niemand ruft, und ein Update mitten im Gespräch
      # käme weiterhin durch. Nichts würde rot (#1090-Klasse).
      code = File.read!(@updater)
      [idle, _] = String.split(code, "def gpu_busy?", parts: 2)

      assert idle =~ "not frage_busy?()",
             "idle?/0 fragt den Frage-Pfad nicht — der Riegel ist tot"
    end
  end
end
