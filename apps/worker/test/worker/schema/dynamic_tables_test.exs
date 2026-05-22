defmodule Worker.Schema.DynamicTablesTest do
  @moduledoc """
  Smoke tests für Etappe 3a (Issue #127) — per-Campaign Event-Stores.
  """

  use ExUnit.Case, async: false

  alias Worker.Schema.DynamicTables

  @cid "test-camp-dyntables"

  setup do
    DynamicTables.drop_campaign_store!(@cid)
    :ok
  end

  test "ensure_campaign_store! ist idempotent + exists?/1 sieht es" do
    refute DynamicTables.exists?(@cid)
    table = DynamicTables.ensure_campaign_store!(@cid)
    assert is_atom(table)
    assert DynamicTables.exists?(@cid)

    # idempotent — zweiter Aufruf ist no-op
    assert ^table = DynamicTables.ensure_campaign_store!(@cid)
    assert DynamicTables.exists?(@cid)
  end

  test "drop_campaign_store! ist idempotent" do
    DynamicTables.ensure_campaign_store!(@cid)
    assert DynamicTables.exists?(@cid)
    :ok = DynamicTables.drop_campaign_store!(@cid)
    refute DynamicTables.exists?(@cid)

    # idempotent
    :ok = DynamicTables.drop_campaign_store!(@cid)
    refute DynamicTables.exists?(@cid)
  end

  test "last_event_id/1 + events_since/2 lesen UUIDv7-sortiert" do
    DynamicTables.ensure_campaign_store!(@cid)
    assert DynamicTables.last_event_id(@cid) == nil
    assert DynamicTables.events_since(@cid, nil) == []

    ts = ~U[2026-05-22 12:00:00.000000Z]
    eid1 = "019e0000-0000-7000-8000-000000000001"
    eid2 = "019e0000-0000-7000-8000-000000000002"
    eid3 = "019e0000-0000-7000-8000-000000000003"

    {:atomic, :ok} =
      :mnesia.transaction(fn ->
        DynamicTables.write_in_tx(@cid, eid1, 1, %{"k" => "a"}, ts)
        DynamicTables.write_in_tx(@cid, eid3, 3, %{"k" => "c"}, ts)
        DynamicTables.write_in_tx(@cid, eid2, 2, %{"k" => "b"}, ts)
      end)

    # last_event_id = höchste UUIDv7
    assert DynamicTables.last_event_id(@cid) == eid3

    # events_since(nil) returnt alle, sortiert
    all = DynamicTables.events_since(@cid, nil)
    assert Enum.map(all, fn {id, _, _, _} -> id end) == [eid1, eid2, eid3]

    # events_since(eid1) returnt nur die zwei jüngeren
    rest = DynamicTables.events_since(@cid, eid1)
    assert Enum.map(rest, fn {id, _, _, _} -> id end) == [eid2, eid3]

    # events_since(eid3) returnt leer
    assert DynamicTables.events_since(@cid, eid3) == []
  end

  test "events_since auf nicht-existenter Campaign returnt []" do
    assert DynamicTables.events_since("ghost-campaign", nil) == []
    assert DynamicTables.last_event_id("ghost-campaign") == nil
  end
end
