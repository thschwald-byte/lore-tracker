defmodule Worker.SyncWatermarkTest do
  @moduledoc """
  Issue #693: Drift-Guard für die Sync-Wasserlinie. Die Invarianten hier sind
  das Fundament des Cold-Start-Backfills: fehlender Scope → `nil` (volle
  Historie pullen), `advance/2` ist strikt monoton (parallele/duplizierte
  Pull-Loops harmlos), `sync_step/1` entscheidet Loop-weiter vs. aufgeholt.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Schema.Mnesia, as: S
  alias Worker.SyncWatermark

  setup do
    clear_all_tables!()
    {:atomic, :ok} = :mnesia.clear_table(S.worker_state())
    :ok
  end

  describe "get/1 + advance/2 — persistierte Wasserlinien-Map" do
    test "fehlender Scope → nil (= Backfill ab Anfang)" do
      assert SyncWatermark.get("global") == nil
      assert SyncWatermark.get("irgendeine-campaign") == nil
    end

    test "advance setzt und get liest zurück, Scopes unabhängig" do
      :ok = SyncWatermark.advance("global", "019e0000-0000-7000-8000-000000000001")
      :ok = SyncWatermark.advance("camp-a", "019e0000-0000-7000-8000-00000000000f")

      assert SyncWatermark.get("global") == "019e0000-0000-7000-8000-000000000001"
      assert SyncWatermark.get("camp-a") == "019e0000-0000-7000-8000-00000000000f"
      assert SyncWatermark.get("camp-b") == nil
    end

    test "advance ist monoton — ältere event_id schiebt nicht zurück" do
      newer = "019e0000-0000-7000-8000-000000000009"
      older = "019e0000-0000-7000-8000-000000000002"

      :ok = SyncWatermark.advance("global", newer)
      :ok = SyncWatermark.advance("global", older)

      assert SyncWatermark.get("global") == newer
    end

    test "Wasserlinie überlebt als worker_state (persistiert, nicht RAM)" do
      :ok = SyncWatermark.advance("global", "019e0000-0000-7000-8000-000000000003")

      # Direkt aus der Mnesia lesen — der Wert liegt im worker_state.
      assert %{"global" => "019e0000-0000-7000-8000-000000000003"} =
               Worker.Repo.get_state(:sync_watermarks)
    end
  end

  describe "sync_step/1 — Pull-Loop-Entscheidung" do
    test "leerer Batch → :caught_up (Loop endet)" do
      assert SyncWatermark.sync_step([]) == :caught_up
    end

    test "nicht-leerer Batch → advance auf letzte event_id (Batches aufsteigend)" do
      events = [
        %{"event_id" => "019e0000-0000-7000-8000-000000000001", "payload" => %{}},
        %{"event_id" => "019e0000-0000-7000-8000-000000000002", "payload" => %{}},
        %{"event_id" => "019e0000-0000-7000-8000-000000000003", "payload" => %{}}
      ]

      assert SyncWatermark.sync_step(events) ==
               {:advance, "019e0000-0000-7000-8000-000000000003"}
    end

    test "Batch mit kaputtem letzten Element (kein event_id) → :caught_up statt Crash" do
      events = [%{"event_id" => "019e0000-0000-7000-8000-000000000001"}, %{"kaputt" => true}]
      assert SyncWatermark.sync_step(events) == :caught_up
    end
  end
end
