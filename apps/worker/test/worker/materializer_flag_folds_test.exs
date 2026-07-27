defmodule Worker.MaterializerFlagFoldsTest do
  @moduledoc """
  Issue #915 (Epic #911, Cut 1): Konvergenz der Falsifikations-Flag-Folds.

  EINE `worker_flags`-Row pro Objekt, EIN geteilter Fold `:flag_status` für
  FlagRaised/FlagResolved/FlagDismissed (LWW-by-event_id). Gepinnt: (1) Raise
  setzt raised_by/note; (2) Resolve nach Raise preserved raised_by/note;
  (3) LWW konvergiert in beiden Orderings (höchste event_id gewinnt); (4)
  Reorder — Resolve VOR Raise (Stub-Upsert), Raise mit kleinerer event_id
  gedroppt; (5) Re-Raise nach Resolve lebt wieder auf; (6) Doppel-Zustellung
  idempotent; (7) verschiedene target_kinds = verschiedene Rows; (8) bad
  payload gedroppt.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Materializer
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-flag-915"
  @tid "sess-abc"

  setup do
    clear_all_tables!()
    {:atomic, :ok} = :mnesia.clear_table(S.worker_state())
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
    :ok
  end

  # ─── Event-Builder ──────────────────────────────────────────────────

  defp ev_raised(eid, seq, opts \\ []) do
    event(
      "FlagRaised",
      %{
        "campaign_id" => @cid,
        "target_kind" => Keyword.get(opts, :kind, "session"),
        "target_id" => Keyword.get(opts, :tid, @tid),
        "note" => Keyword.get(opts, :note, "das stimmt nicht"),
        "set_by" => Keyword.get(opts, :by, "did-melder")
      },
      seq,
      event_id: eid
    )
  end

  defp ev_resolved(eid, seq, opts \\ []) do
    event(
      "FlagResolved",
      %{
        "campaign_id" => @cid,
        "target_kind" => Keyword.get(opts, :kind, "session"),
        "target_id" => Keyword.get(opts, :tid, @tid),
        "set_by" => "did-kurator"
      },
      seq,
      event_id: eid
    )
  end

  defp ev_dismissed(eid, seq, opts \\ []) do
    event(
      "FlagDismissed",
      %{
        "campaign_id" => @cid,
        "target_kind" => Keyword.get(opts, :kind, "session"),
        "target_id" => Keyword.get(opts, :tid, @tid),
        "set_by" => "did-kurator"
      },
      seq,
      event_id: eid
    )
  end

  defp row(kind \\ "session", tid \\ @tid) do
    key = @cid <> ":" <> kind <> ":" <> tid

    case :mnesia.dirty_read(S.flags(), key) do
      [{_t, _k, cid, tk, ti, rb, n, st, ev}] ->
        %{cid: cid, kind: tk, tid: ti, raised_by: rb, note: n, status: st, event_id: ev}

      [] ->
        nil
    end
  end

  defp apply_all(evs), do: Enum.each(evs, &Materializer.apply_event/1)

  defp converge(orderings, kind \\ "session") do
    for order <- orderings do
      reset_for_permutation!()
      apply_all(order)
      row(kind)
    end
  end

  defp permutations([]), do: [[]]
  defp permutations(list), do: for(x <- list, rest <- permutations(list -- [x]), do: [x | rest])

  # ─── Tests ──────────────────────────────────────────────────────────

  test "Raise setzt Status raised + raised_by + note" do
    apply_all([ev_raised("e1", 1, note: "falsch", by: "did-x")])
    r = row()
    assert r.status == "raised"
    assert r.raised_by == "did-x"
    assert r.note == "falsch"
  end

  test "Resolve nach Raise → resolved, raised_by/note preserved (Audit)" do
    apply_all([ev_raised("e1", 1, note: "falsch", by: "did-x"), ev_resolved("e2", 2)])
    r = row()
    assert r.status == "resolved"
    assert r.raised_by == "did-x", "raised_by überlebt den Resolve"
    assert r.note == "falsch", "note überlebt den Resolve"
  end

  test "LWW konvergiert: Raise/Resolve in beiden Orderings → resolved (e2 gewinnt)" do
    evs = [ev_raised("e1", 1), ev_resolved("e2", 2)]
    results = converge(permutations(evs))
    assert Enum.all?(results, &(&1.status == "resolved")), inspect(results)
  end

  test "Reorder: Resolve(e9) VOR Raise(e5) → resolved bleibt (Stub-Upsert, Raise gedroppt)" do
    # In JEDER Anwendungsreihenfolge gewinnt die höhere event_id e9 (resolved).
    evs = [ev_raised("e5", 1), ev_resolved("e9", 2)]
    results = converge(permutations(evs))
    assert Enum.all?(results, &(&1.status == "resolved")), inspect(results)
  end

  test "Re-Raise nach Resolve lebt wieder auf (höhere event_id)" do
    apply_all([ev_raised("e1", 1), ev_resolved("e2", 2), ev_raised("e3", 3, note: "immer noch")])
    r = row()
    assert r.status == "raised"
    assert r.note == "immer noch"
  end

  test "Dismiss gewinnt über älteren Raise" do
    results = converge(permutations([ev_raised("e1", 1), ev_dismissed("e4", 2)]))
    assert Enum.all?(results, &(&1.status == "dismissed"))
  end

  test "Doppel-Zustellung idempotent (gleiche event_id)" do
    apply_all([ev_raised("e1", 1), ev_raised("e1", 1)])
    assert row().status == "raised"
  end

  test "verschiedene target_kinds = verschiedene Rows" do
    apply_all([
      ev_raised("e1", 1, kind: "session", tid: "s1"),
      ev_raised("e2", 2, kind: "fact", tid: "f_abc"),
      ev_raised("e3", 3, kind: "arc", tid: "arc_1")
    ])

    assert row("session", "s1").status == "raised"
    assert row("fact", "f_abc").status == "raised"
    assert row("arc", "arc_1").status == "raised"
  end

  test "bad payload (unbekannter target_kind) wird gedroppt" do
    bad =
      event(
        "FlagRaised",
        %{"campaign_id" => @cid, "target_kind" => "bogus", "target_id" => "x", "set_by" => "d"},
        1,
        event_id: "e1"
      )

    apply_all([bad])
    assert row("bogus", "x") == nil
  end
end
