defmodule Worker.EventLogTest do
  @moduledoc """
  Issue #97 Cut 1: Worker.EventLog.prune_before/2 löscht Event-Rows mit
  ts < cutoff aus globalem + per-Campaign-Store; --dry-run zählt nur.
  """
  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.EventLog
  alias Worker.Schema.DynamicTables
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-prune-0001"
  @old ~U[2025-01-01 00:00:00Z]
  @new ~U[2026-06-01 00:00:00Z]
  @cutoff ~U[2026-01-01 00:00:00Z]

  setup do
    clear_all_tables!()
    DynamicTables.ensure_campaign_store!(@cid)
    {:atomic, :ok} = :mnesia.clear_table(DynamicTables.table_name(@cid))
    {:atomic, :ok} = :mnesia.clear_table(S.events_global())

    # 2 alte + 1 neue Row in den Campaign-Store
    write_campaign("c-old-1", @old)
    write_campaign("c-old-2", @old)
    write_campaign("c-new-1", @new)
    # 1 alte + 1 neue Row global
    write_global("g-old-1", @old)
    write_global("g-new-1", @new)
    :ok
  end

  defp write_campaign(id, ts) do
    {:atomic, :ok} =
      :mnesia.transaction(fn ->
        DynamicTables.write_in_tx(@cid, id, nil, %{"kind" => "X"}, ts)
      end)
  end

  defp write_global(id, ts) do
    {:atomic, :ok} =
      :mnesia.transaction(fn ->
        :mnesia.write({S.events_global(), id, nil, %{"kind" => "X"}, ts})
      end)
  end

  defp campaign_count, do: :mnesia.table_info(DynamicTables.table_name(@cid), :size)
  defp global_count, do: :mnesia.table_info(S.events_global(), :size)

  test "dry_run zählt nur, löscht nichts" do
    r = EventLog.prune_before(@cutoff, dry_run: true)
    assert r.dry_run == true
    assert r.global == 1
    assert r.total == 3
    # nichts gelöscht
    assert campaign_count() == 3
    assert global_count() == 2
  end

  test "löscht Rows mit ts < cutoff aus global + allen Campaign-Stores" do
    r = EventLog.prune_before(@cutoff)
    assert r.dry_run == false
    assert r.global == 1
    assert r.total == 3
    # nur die neuen bleiben
    assert campaign_count() == 1
    assert global_count() == 1
  end

  test "campaign_id-Option prunt nur diesen Store, global unangetastet" do
    r = EventLog.prune_before(@cutoff, campaign_id: @cid)
    assert r.global == 0
    assert r.total == 2
    assert campaign_count() == 1
    # global NICHT angefasst
    assert global_count() == 2
  end
end
