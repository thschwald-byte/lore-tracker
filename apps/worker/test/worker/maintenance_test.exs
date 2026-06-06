defmodule Worker.MaintenanceTest do
  @moduledoc """
  Issue #608: Smoke für `Worker.Maintenance.purge_live/0` — eine destruktive
  Prod-Operation (via RPC), bisher ohne Coverage. Sichert den Klassifizierungs-
  Vertrag: Sessions mit live+batch-Rows sind clearable, Sessions mit NUR live-
  Rows sind orphan (Datenschutz — kein Löschen ohne Batch-Backup).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Worker.TestHelper

  alias Worker.Maintenance
  alias Worker.Schema.Builder

  setup do
    clear_all_tables!()
    mat = ensure_materializer!()
    on_exit(fn -> if mat && Process.alive?(mat), do: Process.exit(mat, :kill) end)
    :ok
  end

  test "purge_live/0 — clearable (live+batch) wird gepurged, orphan (nur live) geschont" do
    # Session A: 2 live + 1 batch → clearable (live-Rows sicher löschbar).
    Builder.write!(Builder.session("s-a", "c-1", number: 1))
    Builder.write!(Builder.utterance("a-live-1", "s-a", status: :live))
    Builder.write!(Builder.utterance("a-live-2", "s-a", status: :live))
    Builder.write!(Builder.utterance("a-batch", "s-a", status: :active))

    # Session B: nur 1 live, KEIN Batch → orphan (geschont, kein Datenverlust).
    Builder.write!(Builder.session("s-b", "c-1", number: 2))
    Builder.write!(Builder.utterance("b-live", "s-b", status: :live))

    log = capture_log(fn -> send(self(), {:res, Maintenance.purge_live()}) end)

    # orphan-Session wird geloggt (geschont, nicht gelöscht).
    assert log =~ "übersprungen"
    assert_received {:res, res}
    assert res == %{cleared_sessions: 1, cleared_utterances: 2, orphan_sessions: 1}
  end

  test "purge_live/0 — nichts zu tun → alle Zähler 0" do
    Builder.write!(Builder.session("s-clean", "c-1", number: 1))
    Builder.write!(Builder.utterance("u-batch", "s-clean", status: :active))

    assert Maintenance.purge_live() ==
             %{cleared_sessions: 0, cleared_utterances: 0, orphan_sessions: 0}
  end
end
