defmodule Worker.PipelineErrorLogTest do
  @moduledoc """
  Issue #605: Worker.PipelineErrorLog.prune_keep_last/1 trimmt die
  `worker_pipeline_errors`-Tabelle nach Keep-last-N.
  """
  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.PipelineErrorLog
  alias Worker.Schema.Mnesia, as: S

  setup do
    clear_all_tables!()
    {:atomic, :ok} = :mnesia.clear_table(S.pipeline_errors())
    :ok
  end

  defp write_error(idx, %DateTime{} = ts) do
    {:atomic, :ok} =
      :mnesia.transaction(fn ->
        :mnesia.write({
          S.pipeline_errors(),
          "err-#{idx}",
          ts,
          "session-#{idx}",
          "campaign-#{idx}",
          "stage2",
          "timeout",
          "msg #{idx}",
          %{}
        })
      end)
  end

  defp count, do: :mnesia.table_info(S.pipeline_errors(), :size)

  test "no-op wenn Anzahl <= keep" do
    base = ~U[2026-01-01 00:00:00Z]
    for i <- 1..5, do: write_error(i, DateTime.add(base, i, :second))

    assert {:ok, %{kept: 5, deleted: 0}} = PipelineErrorLog.prune_keep_last(10)
    assert count() == 5
  end

  test "trimmt auf Top-N, behaelt die juengsten nach occurred_at" do
    base = ~U[2026-01-01 00:00:00Z]
    # 100 Errors, occurred_at 1s..100s nach base.
    for i <- 1..100, do: write_error(i, DateTime.add(base, i, :second))

    assert {:ok, %{kept: 10, deleted: 90}} = PipelineErrorLog.prune_keep_last(10)
    assert count() == 10

    # Die juengsten 10 (idx 91..100) bleiben.
    ids =
      :mnesia.dirty_match_object({S.pipeline_errors(), :_, :_, :_, :_, :_, :_, :_, :_})
      |> Enum.map(&elem(&1, 1))
      |> MapSet.new()

    expected = Enum.map(91..100, &"err-#{&1}") |> MapSet.new()
    assert ids == expected
  end

  test "nutzt Default aus Worker.Settings wenn n=nil" do
    Worker.Settings.put(:pipeline_errors_keep_n, 3)

    base = ~U[2026-01-01 00:00:00Z]
    for i <- 1..10, do: write_error(i, DateTime.add(base, i, :second))

    assert {:ok, %{kept: 3, deleted: 7}} = PipelineErrorLog.prune_keep_last()
    assert count() == 3
  after
    Worker.Settings.put(:pipeline_errors_keep_n, 1000)
  end

  test "behandelt Altdaten ohne DateTime — alte ts werden zuerst gedroppt" do
    base = ~U[2026-01-01 00:00:00Z]
    # 2 mit DateTime, 3 mit string/nil → die "leere Sort-Key"-Rows fallen raus.
    write_error(1, DateTime.add(base, 1, :second))
    write_error(2, DateTime.add(base, 2, :second))

    {:atomic, :ok} =
      :mnesia.transaction(fn ->
        :mnesia.write({S.pipeline_errors(), "alt-1", nil, nil, nil, nil, nil, nil, %{}})
        :mnesia.write({S.pipeline_errors(), "alt-2", "2025-12-31", nil, nil, nil, nil, nil, %{}})
        :mnesia.write({S.pipeline_errors(), "alt-3", nil, nil, nil, nil, nil, nil, %{}})
      end)

    assert {:ok, %{kept: 2, deleted: 3}} = PipelineErrorLog.prune_keep_last(2)

    ids =
      :mnesia.dirty_match_object({S.pipeline_errors(), :_, :_, :_, :_, :_, :_, :_, :_})
      |> Enum.map(&elem(&1, 1))
      |> MapSet.new()

    assert ids == MapSet.new(["err-1", "err-2"])
  end
end
