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

  # ─── campaign_store_plan/heal_campaign_stores (Issue #718) ─────────
  #
  # Andere Test-Files hinterlassen eigene worker_campaign_events_*-Tabellen
  # (Schema-Tabellen überleben clear_all_tables!) — Assertions prüfen daher
  # Mengen-MITGLIEDSCHAFT der eigenen IDs, nie Listen-Gleichheit.

  describe "campaign_store_plan/0 + heal_campaign_stores/1 (#718)" do
    alias Worker.Schema.DynamicTables
    alias Worker.SyncWatermark

    defp drop_store!(cid), do: DynamicTables.drop_campaign_store!(cid)

    test "missing: Campaign-Row ohne Store wird erkannt + geheilt (inkl. Watermark-Reset)" do
      cid = "c-718-missing"
      Builder.write!(Builder.campaign(cid))
      on_exit(fn -> drop_store!(cid) end)

      # Store fehlt (Crash zwischen Membership-Apply und Schema-Op simuliert);
      # Wasserlinie steht von einem früheren Sync noch hoch.
      :ok = SyncWatermark.advance(cid, "0190aaaa-0000-7000-8000-000000000000")
      refute DynamicTables.exists?(cid)

      assert cid in Maintenance.campaign_store_plan().missing

      log =
        capture_log(fn ->
          result = Maintenance.heal_campaign_stores()
          assert result.healed >= 1
        end)

      assert log =~ "fehlender Store für campaign=#{cid}"
      assert DynamicTables.exists?(cid)
      # Watermark zurückgesetzt → nächster Pull holt die volle Historie.
      assert SyncWatermark.get(cid) == nil
      refute cid in Maintenance.campaign_store_plan().missing
    end

    test "orphan: Store ohne Campaign-Row wird geloggt, aber NICHT gedroppt (Default)" do
      cid = "c-718-orphan"
      table = cid |> DynamicTables.table_name() |> Atom.to_string()
      DynamicTables.ensure_campaign_store!(cid)
      on_exit(fn -> drop_store!(cid) end)

      assert table in Maintenance.campaign_store_plan().orphan

      log =
        capture_log(fn ->
          result = Maintenance.heal_campaign_stores()
          assert result.dropped == 0
        end)

      assert log =~ "NICHT"
      assert DynamicTables.exists?(cid)
    end

    test "orphan: drop_orphans: true dropt den Store" do
      cid = "c-718-dropme"
      table = cid |> DynamicTables.table_name() |> Atom.to_string()
      DynamicTables.ensure_campaign_store!(cid)
      on_exit(fn -> drop_store!(cid) end)

      capture_log(fn ->
        result = Maintenance.heal_campaign_stores(drop_orphans: true)
        assert result.dropped >= 1
      end)

      refute DynamicTables.exists?(cid)
      refute table in Maintenance.campaign_store_plan().orphan
    end

    test "Probelauf-Stores zählen nicht als Orphan (Lifecycle gehört dem Probelauf)" do
      cid = "probelauf-718-test"
      table = cid |> DynamicTables.table_name() |> Atom.to_string()
      DynamicTables.ensure_campaign_store!(cid)
      on_exit(fn -> drop_store!(cid) end)

      refute table in Maintenance.campaign_store_plan().orphan
    end

    test "konsistenter Zustand: Campaign mit Store ist weder missing noch orphan" do
      cid = "c-718-ok"
      table = cid |> DynamicTables.table_name() |> Atom.to_string()
      Builder.write!(Builder.campaign(cid))
      DynamicTables.ensure_campaign_store!(cid)
      on_exit(fn -> drop_store!(cid) end)

      plan = Maintenance.campaign_store_plan()
      refute cid in plan.missing
      refute table in plan.orphan
    end
  end
end
