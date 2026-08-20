defmodule Worker.Recording.AudioBufferPeriodicRecoveryTest do
  @moduledoc """
  Issue #1055: der Recovery-Scan läuft periodisch statt nur beim Boot — und
  darf dabei die **laufende** Aufnahme nicht anfassen.

  Beim Boot war das kein Thema: `state.sessions` ist dort leer. Periodisch
  liegt die aktive Sitzung im selben `audio_dir` wie die verwaisten. Griffe der
  Scan sie auf, bekäme sie mitten im Betrieb ein nachgeholtes `SessionEnded`
  und liefe ein zweites Mal durch Whisper.

  Getestet wird die **Verdrahtung**, nicht die reine Einsortierung (die liegt
  in `Recovery.plan/4`, s. `audio_buffer_recovery_plan_test.exs`): reicht
  `recover_orphaned_sessions/1` die offenen Sitzungen wirklich durch? Der
  Nachweis läuft über das nachgeholte `SessionEnded` — `Worker.Intents.publish/1`
  appliet lokal sofort, der Statuswechsel ist also in Mnesia sichtbar, ohne
  dass ein Hub antworten muss.

  Der positive Fall steht bewusst daneben: ohne ihn wäre der negative vakuum-
  grün — er würde auch dann bestehen, wenn der Scan überhaupt nichts täte.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Recording.AudioBuffer
  alias Worker.Schema.Builder

  @cid "camp-recovery"

  setup do
    clear_all_tables!()

    ensure_started(Worker.TaskSupervisor, fn ->
      Task.Supervisor.start_link(name: Worker.TaskSupervisor)
    end)

    ensure_started(Worker.PubSub, fn ->
      Phoenix.PubSub.Supervisor.start_link(name: Worker.PubSub)
    end)

    mat = ensure_materializer!()

    tmp =
      Path.join(
        System.tmp_dir!(),
        "lore-recovery-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    vorher = Worker.Settings.get(:audio_dir)
    Worker.Settings.put(:audio_dir, tmp)

    on_exit(fn ->
      if vorher, do: Worker.Settings.put(:audio_dir, vorher)
      File.rm_rf(tmp)
      if mat && Process.alive?(mat), do: Process.exit(mat, :kill)
    end)

    Builder.write!(Builder.campaign(@cid))

    {:ok, tmp: tmp}
  end

  defp start_buffer! do
    if pid = Process.whereis(AudioBuffer) do
      try do
        GenServer.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end

    start_supervised!(AudioBuffer)
  end

  defp fake_track!(tmp, session_id) do
    dir = Path.join(tmp, session_id)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "alice.webm"), "nicht wirklich webm")
    dir
  end

  defp status(session_id) do
    case Worker.Repo.get_session(session_id) do
      %{status: s} -> s
      nil -> nil
    end
  end

  # Nach `send/2` ist nur die Zustellung sicher, nicht die Verarbeitung. Ein
  # `call` danach läuft hinter der `handle_info`-Klausel durch dieselbe Mailbox.
  defp scan_und_warte(pid) do
    send(pid, :recover_orphans)
    _ = AudioBuffer.open_session_ids()
    :sys.get_state(pid)
    :ok
  end

  test "eine OFFENE Session wird vom Scan nicht angefasst", %{tmp: tmp} do
    sid = "sess-offen"
    Builder.write!(Builder.session(sid, @cid, status: :recording))

    pid = start_buffer!()
    :ok = AudioBuffer.open_session(sid, @cid)
    fake_track!(tmp, sid)

    scan_und_warte(pid)

    assert status(sid) == :recording,
           "der Scan hat einer laufenden Aufnahme ein SessionEnded untergeschoben"

    assert sid in AudioBuffer.open_session_ids(),
           "die Session ist nicht mehr offen — der Scan hat sie übernommen"
  end

  test "ein VERWAISTES Verzeichnis wird aufgegriffen (Gegenprobe)", %{tmp: tmp} do
    sid = "sess-verwaist"
    Builder.write!(Builder.session(sid, @cid, status: :recording))

    pid = start_buffer!()
    fake_track!(tmp, sid)

    scan_und_warte(pid)

    assert status(sid) == :completed,
           "der Scan hat das verwaiste Verzeichnis nicht aufgegriffen — dann ist " <>
             "der Negativtest oben vakuum-grün"
  end

  test "ein Verzeichnis ohne .webm bleibt unberührt", %{tmp: tmp} do
    sid = "sess-leer"
    Builder.write!(Builder.session(sid, @cid, status: :recording))

    pid = start_buffer!()
    File.mkdir_p!(Path.join(tmp, sid))

    scan_und_warte(pid)

    assert status(sid) == :recording
  end

  test "der Scan plant sich selbst neu — sonst wäre er wieder Boot-only" do
    # Ein laufender Timer ist von aussen nicht beobachtbar (er lebt im
    # Timer-Wheel, nicht in Prozess-Info), und 15 Minuten abzuwarten ist kein
    # Test. Geprüft wird deshalb die Quelle — dieselbe Bauart wie die
    # Reihenfolge-Wächter aus #1011 und #1060: die Klausel MUSS sich neu
    # einplanen, sonst ist der Scan wieder das, was #1055 beschreibt.
    quelle = File.read!("lib/worker/recording/audio_buffer.ex")

    [_vor, rest] =
      String.split(quelle, "def handle_info(:recover_orphans, state) do", parts: 2)

    [klausel, _nach] = String.split(rest, "\n  end\n", parts: 2)

    assert klausel =~ "Process.send_after(self(), :recover_orphans, recover_interval_ms())",
           "die :recover_orphans-Klausel plant sich nicht neu — dann wird ein " <>
             "Auftrag, der ohne Neustart verlorengeht, bis zum nächsten Boot " <>
             "nicht mehr angefasst (#1055)"
  end
end
