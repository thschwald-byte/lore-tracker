defmodule Worker.ThreadOverridesTest do
  @moduledoc """
  Issue #836 (Epic #829 Slice D2): das Member-Kurations-Overlay auf die
  Handlungsstränge — Apply (`ThreadOverrideSet` → `worker_thread_overrides`,
  zwei Dimensionen, LWW) + der Read-Merge in `Repo.campaign_threads/1`
  (rename/merge/resolve/dismiss + Undo). Rein deterministisch, kein LLM.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.{Materializer, Repo}
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-thr-ov-836"

  setup do
    clear_all_tables!()
    {:atomic, :ok} = :mnesia.clear_table(S.worker_state())
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
    # 3 Sessions (Nummern 1..3).
    build_campaign(campaign_id: @cid, sessions: [1, 1, 1], apply: true)
    # Basis-Fakten: „der Skandal" (S1+S3), „die Heirat" (S1), „der Skandal-Coup"
    # (S2, ein Fragment desselben Strangs).
    seed(1, [f("f1", "der Skandal", "König"), f("f2", "die Heirat", "Norton")])
    seed(2, [f("f1", "der Skandal-Coup", "Holmes")])
    seed(3, [f("f1", "der Skandal", "Watson")])
    :ok
  end

  defp f(id, thread, alias_name) do
    %{
      "id" => id,
      "claim" => "Fakt #{id}",
      "thread" => thread,
      "character_alias" => alias_name,
      "verified?" => true,
      "fact_type" => "ereignis"
    }
  end

  defp seed(n, facts) do
    Materializer.apply_event(
      event(
        "SessionFactsExtracted",
        %{"session_id" => "#{@cid}-s#{n}", "campaign_id" => @cid, "facts" => facts},
        n,
        event_id: "sfe-#{@cid}-#{n}"
      )
    )
  end

  defp override(canonical, action, seq, extra \\ %{}) do
    payload =
      Map.merge(%{"campaign_id" => @cid, "canonical" => canonical, "action" => action}, extra)

    Materializer.apply_event(event("ThreadOverrideSet", payload, seq, event_id: "ov-#{seq}"))
  end

  defp find(canonical),
    do: Enum.find(Repo.campaign_threads(@cid), &(&1.key_canonical == canonical))

  test "ohne Override: drei getrennte Stränge (Baseline)" do
    canons = Repo.campaign_threads(@cid) |> Enum.map(& &1.key_canonical) |> Enum.sort()
    assert canons == ["der Skandal", "der Skandal-Coup", "die Heirat"]
  end

  test "rename: ändert das Anzeige-Label, key_canonical bleibt das Original" do
    override("der Skandal", "rename", 10, %{"new_name" => "Die Erpressung"})
    t = find("der Skandal")
    assert t.canonical == "Die Erpressung"
    assert t.key_canonical == "der Skandal"
    assert t.identity_action == "rename"
    assert t.curated?
  end

  test "merge: faltet einen Strang in einen anderen (heilt Fragmentierung)" do
    override("der Skandal-Coup", "merge", 10, %{"merge_into" => "der Skandal"})
    threads = Repo.campaign_threads(@cid)

    # „der Skandal-Coup" verschwindet, seine Fakten landen bei „der Skandal".
    refute Enum.any?(threads, &(&1.key_canonical == "der Skandal-Coup"))
    skandal = Enum.find(threads, &(&1.key_canonical == "der Skandal"))
    # f1(S1) + f1(S3) + Coup(S2) = 3 Fakten, über Sitzung 1–3.
    assert skandal.fact_count == 3
    assert skandal.sessions_touched == [1, 2, 3]
    assert "Holmes" in skandal.entities
  end

  test "resolve: Status → :aufgelöst (nur via Override, kein Auto-Übergang)" do
    override("die Heirat", "resolve", 10)
    assert find("die Heirat").status == :aufgelöst
  end

  test "dismiss: dismissed?-Flag gesetzt, Strang bleibt (für Undo) im Output" do
    override("die Heirat", "dismiss", 10)
    t = find("die Heirat")
    assert t.dismissed?
    assert t.lifecycle_action == "dismiss"
  end

  test "LWW: resolve dann dismiss (gleiche Dimension) — dismiss gewinnt" do
    override("die Heirat", "resolve", 10)
    override("die Heirat", "dismiss", 11)
    t = find("die Heirat")
    assert t.dismissed?
    refute t.status == :aufgelöst
  end

  test "zwei Dimensionen koexistieren: rename UND resolve" do
    override("die Heirat", "rename", 10, %{"new_name" => "Die Trauung"})
    override("die Heirat", "resolve", 11)
    t = find("die Heirat")
    assert t.canonical == "Die Trauung"
    assert t.status == :aufgelöst
  end

  test "Undo: reactivate hebt resolve auf (neutrale Row, kein Delete)" do
    override("die Heirat", "resolve", 10)
    assert find("die Heirat").status == :aufgelöst
    override("die Heirat", "reactivate", 11)
    t = find("die Heirat")
    refute t.status == :aufgelöst
    refute t.curated?
    # Persistiert als reguläre Row (nie :mnesia.delete) — Undo ist konvergent.
    assert :mnesia.dirty_read(
             S.thread_overrides(),
             Worker.ThreadOverride.key(@cid, "die Heirat", "lifecycle")
           ) != []
  end

  # ── #885: Kind-Dimension (Arc/Context) ────────────────────────────────────

  test "mark_context: Strang wird Thema; mark_arc stuft zurück (dritte Dimension)" do
    override("die Heirat", "mark_context", 10)
    t = find("die Heirat")
    assert t.kind == "context"
    assert t.kind_action == "mark_context"
    assert t.curated?

    # Koexistiert mit den anderen Dimensionen (eigene Row, eigener Key).
    override("die Heirat", "rename", 11, %{"new_name" => "Hochzeits-Lore"})
    t2 = find("die Heirat")
    assert t2.kind == "context"
    assert t2.canonical == "Hochzeits-Lore"

    override("die Heirat", "mark_arc", 12)
    assert find("die Heirat").kind == "arc"
  end

  test "clear_kind: Undo → LLM-Klassifikation gilt wieder (Default arc)" do
    override("die Heirat", "mark_context", 10)
    assert find("die Heirat").kind == "context"
    override("die Heirat", "clear_kind", 11)
    t = find("die Heirat")
    assert t.kind == "arc"
    refute t.curated?

    # Reguläre Row (nie delete) — Undo ist konvergent.
    assert :mnesia.dirty_read(
             S.thread_overrides(),
             Worker.ThreadOverride.key(@cid, "die Heirat", "kind")
           ) != []
  end

  test "Context-Stränge sortieren hinter Arcs" do
    override("der Skandal", "mark_context", 10)
    kinds = Repo.campaign_threads(@cid) |> Enum.map(& &1.kind)
    assert kinds == ["arc", "arc", "context"]
  end

  test "unbekannte action wird verworfen (kein Row)" do
    override("die Heirat", "quatsch", 10)
    assert find("die Heirat").status in [:offen, :ruhend]
    refute find("die Heirat").curated?
  end

  test "CampaignDeleted-Cascade räumt thread_overrides + fold_meta" do
    override("der Skandal", "rename", 10, %{"new_name" => "X"})
    override("die Heirat", "resolve", 11)
    key = Worker.ThreadOverride.key(@cid, "der Skandal", "identity")
    assert :mnesia.dirty_read(S.thread_overrides(), key) != []

    Materializer.apply_event(event("CampaignDeleted", %{"campaign_id" => @cid, "id" => @cid}, 99))

    assert :mnesia.dirty_read(S.thread_overrides(), key) == []
    assert :mnesia.dirty_index_read(S.thread_overrides(), @cid, :campaign_id) == []

    assert :mnesia.dirty_read(S.fold_meta(), {S.thread_overrides(), key, :thread_override_set}) ==
             []
  end
end
