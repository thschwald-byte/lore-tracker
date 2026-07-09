defmodule Worker.UpdaterTest do
  @moduledoc """
  Issue #492: Entscheidungslogik des Self-Update-Updaters, isoliert getestet
  über `maybe_update/1` (@doc false public) + `idle?/0`. Der GenServer selbst
  wird NICHT gestartet — wir prüfen nur die reine Gate-Logik mit konstruierten
  State-Maps. „Update startet" wird daran erkannt, dass `updating?` true wird
  (ein Task wäre gestartet); „kein Update" daran, dass `updating?` false bleibt.
  """

  use ExUnit.Case, async: false

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

  # Issue #512: Re-Halt-Race. Ist graceful_halt einmal ausgelöst (halting?),
  # darf KEIN weiteres Drift-Event (rapid Hub-Deploys) einen zweiten Update-/
  # Halt-Zyklus starten — der Node geht ohnehin runter.
  test "halting? gesetzt → kein zweites Update trotz frischer Drift" do
    s = Updater.maybe_update(state(%{halting?: true, target_sha: "deadbeef"}))
    refute s.updating?
    assert s.task_ref == nil
  end
end
