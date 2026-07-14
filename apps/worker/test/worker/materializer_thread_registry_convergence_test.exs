defmodule Worker.MaterializerThreadRegistryConvergenceTest do
  @moduledoc """
  Issue #832 (Epic #829 Slice C): Konvergenz + Cascade für das
  ThreadRegistryComputed-Whole-Snapshot-Artefakt (`worker_thread_registry`).

  Kern-Invariante: **Whole-Snapshot ⇒ Voll-Ersatz, kein Feld-Merge**. Zwei
  DIVERGENTE Voll-Maps → der höhere event_id gewinnt KOMPLETT (nicht die Union).
  Plus die CampaignDeleted-Cascade (Row + fold_meta) inkl. der zwei Drive-by-
  Fixes an campaign_calendars (Row-Waise + fold_meta-Key-Mismatch).
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Materializer
  alias Worker.Repo
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-thr-conv-832"

  setup do
    reset_for_permutation!()
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
    :ok
  end

  defp trc(cluster_map, seq, event_id) do
    event(
      "ThreadRegistryComputed",
      %{"campaign_id" => @cid, "cluster_map" => cluster_map},
      seq,
      event_id: event_id
    )
  end

  defp read_row(tbl, key) do
    {:atomic, rows} = :mnesia.transaction(fn -> :mnesia.read(tbl, key) end)
    rows
  end

  defp fold_meta_row(tbl, key, fold) do
    {:atomic, rows} = :mnesia.transaction(fn -> :mnesia.read(S.fold_meta(), {tbl, key, fold}) end)
    rows
  end

  test "ThreadRegistryComputed materialisiert → get_thread_registry liefert die Map" do
    reset_for_permutation!()
    map = %{"foto" => "die Fotografie", "der brief" => "der Brief"}
    Materializer.apply_event(trc(map, 1, "thr-ev-1"))
    assert Repo.get_thread_registry(@cid) == map
  end

  test "LWW: zwei DIVERGENTE Voll-Maps, höherer event_id gewinnt KOMPLETT (kein Merge)" do
    map_low = %{"a" => "Alpha", "x" => "X-alt"}
    map_high = %{"b" => "Beta", "x" => "X-neu"}
    events = [trc(map_low, 1, "thr-ev-1"), trc(map_high, 2, "thr-ev-2")]

    results = materialize_permutations(events, fn -> Repo.get_thread_registry(@cid) end)

    # In JEDER Reihenfolge exakt map_high — NICHT die Union {"a","b","x"}.
    Enum.each(results, fn r -> assert r == map_high end)
    assert Enum.uniq(results) == [map_high]
  end

  test "nil-event_id (schlüsselloses Alt-Event) clobbert eine geschlüsselte Row NICHT" do
    reset_for_permutation!()
    Materializer.apply_event(trc(%{"x" => "Keyed"}, 1, "thr-ev-9"))

    Materializer.apply_event(
      event(
        "ThreadRegistryComputed",
        %{"campaign_id" => @cid, "cluster_map" => %{"x" => "Legacy"}},
        2
      )
    )

    assert Repo.get_thread_registry(@cid) == %{"x" => "Keyed"}
  end

  test "CampaignDeleted-Cascade räumt thread_registry + fold_meta (+ Drive-by campaign_calendars)" do
    reset_for_permutation!()
    build_campaign(campaign_id: @cid, apply: true)

    Materializer.apply_event(trc(%{"x" => "Strang"}, 10, "thr-ev-c"))

    Materializer.apply_event(
      event("CampaignCalendarSet", %{"campaign_id" => @cid, "calendar" => %{}}, 11,
        event_id: "cal-ev-c"
      )
    )

    # Vorbedingung: beide Artefakt-Rows + fold_meta existieren.
    assert Repo.get_thread_registry(@cid) != %{}
    assert read_row(S.thread_registry(), @cid) != []
    assert read_row(S.campaign_calendars(), @cid) != []
    assert fold_meta_row(S.thread_registry(), @cid, :thread_registry_computed) != []
    assert fold_meta_row(S.campaign_calendars(), @cid, :campaign_calendar_set) != []

    Materializer.apply_event(event("CampaignDeleted", %{"campaign_id" => @cid, "id" => @cid}, 12))

    # Alles geräumt — Rows UND fold_meta-Sidecars.
    assert Repo.get_thread_registry(@cid) == %{}
    assert read_row(S.thread_registry(), @cid) == []
    assert read_row(S.campaign_calendars(), @cid) == []
    assert fold_meta_row(S.thread_registry(), @cid, :thread_registry_computed) == []
    assert fold_meta_row(S.campaign_calendars(), @cid, :campaign_calendar_set) == []
  end
end
