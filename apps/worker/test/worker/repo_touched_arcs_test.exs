defmodule Worker.RepoTouchedArcsTest do
  @moduledoc """
  Issue #838: `Threads.touched_arcs_for_session/2` — welche Bögen wurden in
  einer bestimmten Session durch neue verifizierte Fakten berührt (der
  Pipeline-Trigger für die Prosa-Progression). Gepinnt: Multi-Arc-Session,
  Session-Filter (andere Sessions zählen nicht), FactArcSet-Override-Redirect
  wird erfasst, die geerbte rauschen-Lücke ist dokumentiert (kein Bug-Test).
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.{Materializer, Repo}
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-touched-838"

  setup do
    clear_all_tables!()
    {:atomic, :ok} = :mnesia.clear_table(S.worker_state())
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
    build_campaign(campaign_id: @cid, sessions: [1, 1, 1], apply: true)
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
        event_id: "sfe-ta-#{session_n}-#{seq}"
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
        event_id: "ac-ta-#{seq}"
      )
    )
  end

  defp fact_arc!(fact_id, arc_id, seq) do
    Materializer.apply_event(
      event(
        "FactArcSet",
        %{"campaign_id" => @cid, "fact_id" => fact_id, "arc_id" => arc_id, "set_by" => "d"},
        seq,
        event_id: "fa-ta-#{seq}"
      )
    )
  end

  test "eine Session, ein berührter Bogen" do
    seed_facts!(1, [fact("f1", "der Auftrag")], 100)
    arc!("arc-1", ["der auftrag"], 101)

    touched = Repo.touched_arcs_for_session(@cid, 1)
    assert Map.keys(touched) == ["arc-1"]
    assert [%{id: "f1"}] = touched["arc-1"]
  end

  test "mehrere Bögen in derselben Session werden alle erfasst" do
    seed_facts!(1, [fact("f1", "der Auftrag"), fact("f2", "die Feindschaft")], 100)
    arc!("arc-auftrag", ["der auftrag"], 101)
    arc!("arc-feindschaft", ["die feindschaft"], 102)

    touched = Repo.touched_arcs_for_session(@cid, 1)
    assert Enum.sort(Map.keys(touched)) == ["arc-auftrag", "arc-feindschaft"]
  end

  test "nur Fakten der angefragten Session zählen, andere Sessions nicht" do
    seed_facts!(1, [fact("f1", "der Auftrag")], 100)
    seed_facts!(2, [fact("f2", "der Auftrag")], 101)
    arc!("arc-1", ["der auftrag"], 102)

    touched1 = Repo.touched_arcs_for_session(@cid, 1)
    touched2 = Repo.touched_arcs_for_session(@cid, 2)

    assert Enum.map(touched1["arc-1"], & &1.id) == ["f1"]
    assert Enum.map(touched2["arc-1"], & &1.id) == ["f2"]
  end

  test "FactArcSet-Override leitet einen Fakt aus einem anderen Strang auf einen Arc um" do
    seed_facts!(1, [fact("f1", "die Welt")], 100)
    arc!("arc-1", ["der auftrag"], 101)
    fact_arc!("f1", "arc-1", 102)

    touched = Repo.touched_arcs_for_session(@cid, 1)
    assert Map.keys(touched) == ["arc-1"]
  end

  test "kein Bogen berührt (nur strang-lose Fakten) -> leere Map" do
    seed_facts!(1, [fact("f1", "")], 100)

    assert Repo.touched_arcs_for_session(@cid, 1) == %{}
  end

  test "geerbte Lücke: FactArcSet-Override auf einen rauschen-Fakt bleibt unsichtbar (dokumentiert, kein Bug)" do
    seed_facts!(1, [fact("f1", "das Protokoll")], 100)

    Materializer.apply_event(
      event(
        "ThreadRegistryComputed",
        %{
          "campaign_id" => @cid,
          "cluster_map" => %{"das protokoll" => "das Protokoll"},
          "kinds" => %{"das protokoll" => "rauschen"}
        },
        101,
        event_id: "trc-ta-101"
      )
    )

    arc!("arc-1", ["der auftrag"], 102)
    fact_arc!("f1", "arc-1", 103)

    # Die bekannte, geerbte Lücke: rauschen-Threads liefern KEINE fact_list
    # (fact_list/3), daher taucht der Override-Fakt hier nicht auf.
    assert Repo.touched_arcs_for_session(@cid, 1) == %{}
  end
end
