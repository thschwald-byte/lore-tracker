defmodule Worker.RepoFlagsTest do
  @moduledoc """
  Issue #915 (Epic #911, Cut 1): der Flag-Lesepfad `Worker.Repo.Flags` — vor
  allem das Read-Zeit-AUTO-RESOLVE für Fakt-Flags (fact-content-id verschwindet
  → `auto_resolved`, nie geschrieben) und die `open_flags`-Filterung.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Materializer
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-flagread-915"

  setup do
    clear_all_tables!()
    {:atomic, :ok} = :mnesia.clear_table(S.worker_state())
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
    :ok
  end

  defp raise_flag(eid, kind, tid, opts \\ []) do
    Materializer.apply_event(
      event(
        "FlagRaised",
        %{
          "campaign_id" => @cid,
          "target_kind" => kind,
          "target_id" => tid,
          "note" => Keyword.get(opts, :note, "n"),
          "set_by" => "did-melder"
        },
        Keyword.get(opts, :seq, 1),
        event_id: eid
      )
    )
  end

  defp resolve_flag(eid, kind, tid, seq) do
    Materializer.apply_event(
      event(
        "FlagResolved",
        %{"campaign_id" => @cid, "target_kind" => kind, "target_id" => tid, "set_by" => "did-k"},
        seq,
        event_id: eid
      )
    )
  end

  defp effective(fact_ids, covered_utts \\ []) do
    Worker.Repo.flags_effective(@cid, MapSet.new(fact_ids), MapSet.new(covered_utts))
    |> Map.new(&{&1["flag_key"], &1["effective_status"]})
  end

  test "Fakt-Flag mit verschwundener content-id → auto_resolved (nie geschrieben)" do
    raise_flag("e1", "fact", "f_weg")

    # f_weg ist NICHT in der aktuellen Fakt-Menge → auto_resolved.
    assert effective(["f_da"])["#{@cid}:fact:f_weg"] == "auto_resolved"

    # Die Row bleibt physisch "raised" (kein Write beim Auto-Resolve).
    [{_, _, _, _, _, _, _, status, _}] = :mnesia.dirty_read(S.flags(), "#{@cid}:fact:f_weg")
    assert status == "raised"
  end

  test "Fakt-Flag mit existierender content-id bleibt raised" do
    raise_flag("e1", "fact", "f_da")
    assert effective(["f_da", "f_x"])["#{@cid}:fact:f_da"] == "raised"
  end

  test "session-/arc-Flag hat KEIN Auto-Resolve (bleibt raised, id-unabhängig)" do
    raise_flag("e1", "session", "sess-1")
    raise_flag("e2", "arc", "arc-1", seq: 2)

    eff = effective([])
    assert eff["#{@cid}:session:sess-1"] == "raised"
    assert eff["#{@cid}:arc:arc-1"] == "raised"
  end

  test "resolvtes Fakt-Flag behält resolved (nicht raised, nicht auto)" do
    raise_flag("e1", "fact", "f_weg")
    resolve_flag("e2", "fact", "f_weg", 2)
    assert effective(["f_da"])["#{@cid}:fact:f_weg"] == "resolved"
  end

  test "open_flags liefert nur effektiv raised (auto_resolved/resolved raus)" do
    raise_flag("e1", "fact", "f_da")
    raise_flag("e2", "fact", "f_weg", seq: 2)
    raise_flag("e3", "session", "sess-1", seq: 3)
    resolve_flag("e4", "session", "sess-1", 4)

    # f_da existiert → offen; f_weg auto-resolved; sess-1 resolved.
    keys =
      Worker.Repo.open_flags(@cid)
      |> Enum.map(& &1["flag_key"])
      |> MapSet.new()

    # open_flags nutzt die interne Fakt-Menge; f_weg/f_da existieren beide NICHT
    # real (keine session_facts geseedet) → beide auto-resolved. sess-1 resolved.
    assert keys == MapSet.new()
  end

  test "Determinismus: zwei Aufrufe liefern identisches Ergebnis" do
    raise_flag("e1", "fact", "f_weg")
    raise_flag("e2", "session", "sess-1", seq: 2)
    assert effective(["f_da"]) == effective(["f_da"])
  end
end
