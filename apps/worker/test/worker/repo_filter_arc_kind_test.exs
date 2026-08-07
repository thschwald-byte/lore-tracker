defmodule Worker.RepoFilterArcKindTest do
  @moduledoc """
  Issue #911/#958: `Repo.filter_arc_kind/2` — der Chronik-Vorfilter (Design B),
  reuse `fact_render_assignments/2` (#909). Gepinnt: arc-Fakt bleibt,
  context-/rauschen-Fakt fliegt raus, strang-loser Fakt fliegt raus,
  FactArcSet-Override wird respektiert (dieselbe Präzedenz wie das
  Fäden-Panel/Resümee-Prompt).
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.{Materializer, Repo}
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-fak-958"

  setup do
    clear_all_tables!()
    {:atomic, :ok} = :mnesia.clear_table(S.worker_state())
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
    build_campaign(campaign_id: @cid, sessions: [1, 1], apply: true)
    :ok
  end

  defp fact(id, thread) do
    %{
      "id" => id,
      "claim" => "Fakt #{id}",
      "thread" => thread,
      "verified?" => true,
      "fact_type" => "ereignis"
    }
  end

  defp seed_facts!(session_n, facts, seq) do
    Materializer.apply_event(
      event(
        "SessionFactsExtracted",
        %{"session_id" => "#{@cid}-s#{session_n}", "campaign_id" => @cid, "facts" => facts},
        seq,
        event_id: "sfe-fak-#{session_n}-#{seq}"
      )
    )
  end

  defp registry!(cluster_map, kinds, seq) do
    Materializer.apply_event(
      event(
        "ThreadRegistryComputed",
        %{"campaign_id" => @cid, "cluster_map" => cluster_map, "kinds" => kinds},
        seq,
        event_id: "trc-fak-#{seq}"
      )
    )
  end

  defp arc!(arc_id, seeds, seq) do
    Materializer.apply_event(
      event(
        "ArcCreated",
        %{
          "arc_id" => arc_id,
          "campaign_id" => @cid,
          "leitfrage_draft" => "F #{arc_id}?",
          "seed_raw_labels" => seeds
        },
        seq,
        event_id: "ac-fak-#{seq}"
      )
    )
  end

  defp fact_arc!(fact_id, arc_id, seq) do
    Materializer.apply_event(
      event(
        "FactArcSet",
        %{"campaign_id" => @cid, "fact_id" => fact_id, "arc_id" => arc_id, "set_by" => "d"},
        seq,
        event_id: "fa-fak-#{seq}"
      )
    )
  end

  defp filtered do
    facts = Repo.list_campaign_facts(@cid)
    Repo.filter_arc_kind(@cid, facts) |> Enum.map(& &1["id"])
  end

  test "arc-Fakt bleibt, strang-loser Fakt fliegt raus (Default-kind eines neuen Labels ist arc)" do
    seed_facts!(1, [fact("f1", "der Auftrag"), fact("f2", "")], 100)

    assert filtered() == ["f1"]
  end

  test "context- und rauschen-Fakten fliegen raus" do
    seed_facts!(
      1,
      [fact("f1", "die Welt"), fact("f2", "das Protokoll"), fact("f3", "der Auftrag")],
      100
    )

    registry!(%{}, %{"die welt" => "context", "das protokoll" => "rauschen"}, 101)

    assert filtered() == ["f3"]
  end

  test "FactArcSet-Override respektiert: leitet einen Fakt aus einem context-Strang auf einen Arc um" do
    seed_facts!(1, [fact("f1", "die Welt"), fact("f2", "der Auftrag")], 100)
    registry!(%{}, %{"die welt" => "context"}, 101)
    # arc_a pairt über f2s Thread ("der Auftrag") — ohne diese Paarung wäre
    # arc_a ein Orphan-Arc und der Override würde auf die Label-Gruppe
    # zurückfallen (kein Effekt), s. #909-Präzedenztest "Orphan-Override".
    arc!("arc_a", ["der auftrag"], 102)
    fact_arc!("f1", "arc_a", 103)

    assert Enum.sort(filtered()) == ["f1", "f2"]
  end

  test "leere Fakten-Liste -> leere Liste" do
    assert Repo.filter_arc_kind(@cid, []) == []
  end
end
