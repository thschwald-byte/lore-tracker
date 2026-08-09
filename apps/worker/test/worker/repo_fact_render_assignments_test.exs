defmodule Worker.RepoFactRenderAssignmentsTest do
  @moduledoc """
  Issue #909 (Epic #900 S5) + #953 (N:M): die Render-Zuordnung Fakt → Bögen
  (`Repo.fact_render_assignments/2`) — Grundlage des Arc-strukturierten
  Recap/Epos-Prompts. Seit #953 liefert sie eine LISTE pro Fakt
  (`%{fact_id => [%{titel, kind}, …]}`): ein Fakt kann mehreren Bögen zugeordnet
  sein — durch Extraktion mit N Labels (`threads`) ODER durch ein FactArcSet-
  Override-Set.

  Gepinnt: Label-Kette (Cluster-Map, identity-merge, rename-Display), kind-
  Durchreichung (context/rauschen), N:M über zwei Labels (inkl. Sekundär-Label
  ohne eigenen Thread → synthetisiert), Dedup per Arc, FactArcSet-Override-Set
  (mehrere Bögen / `[]` / Rücknahme als drei getrennte Zustände), Merge-Redirect,
  verwaiste arc_ids (flag-not-drop → strang-los im Render), gemischter Bestand
  (Alt-Skalar + Listen-Row), strang-lose Fakten ohne Eintrag.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.{Materializer, Repo}
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-fra-909"

  setup do
    clear_all_tables!()
    {:atomic, :ok} = :mnesia.clear_table(S.worker_state())
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
    build_campaign(campaign_id: @cid, sessions: [1, 1], apply: true)
    :ok
  end

  # Alt-Skalar-Label (Migrationspfad — fact_threads/1 liest `thread` als
  # 1-Element-Liste).
  defp fact(id, thread) do
    %{
      "id" => id,
      "claim" => "Fakt #{id}",
      "thread" => thread,
      "verified?" => true,
      "fact_type" => "ereignis"
    }
  end

  # #953: Fakt mit LISTE von Labels (`threads`).
  defp fact_multi(id, threads) do
    %{
      "id" => id,
      "claim" => "Fakt #{id}",
      "threads" => threads,
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
        event_id: "sfe-fra-#{session_n}-#{seq}"
      )
    )
  end

  defp registry!(cluster_map, kinds, seq) do
    Materializer.apply_event(
      event(
        "ThreadRegistryComputed",
        %{"campaign_id" => @cid, "cluster_map" => cluster_map, "kinds" => kinds},
        seq,
        event_id: "trc-fra-#{seq}"
      )
    )
  end

  defp override!(canonical, action, seq, extra \\ %{}) do
    payload =
      Map.merge(%{"campaign_id" => @cid, "canonical" => canonical, "action" => action}, extra)

    Materializer.apply_event(event("ThreadOverrideSet", payload, seq, event_id: "ov-fra-#{seq}"))
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
        event_id: "ac-fra-#{seq}"
      )
    )
  end

  defp merge!(quelle, ziel, seq) do
    Materializer.apply_event(
      event(
        "ArcMergeSet",
        %{"arc_id" => quelle, "campaign_id" => @cid, "merge_into" => ziel, "set_by" => "d"},
        seq,
        event_id: "am-fra-#{seq}"
      )
    )
  end

  # Alt-Skalar-Payload (#905): `arc_id`.
  defp fact_arc!(fact_id, arc_id, seq) do
    Materializer.apply_event(
      event(
        "FactArcSet",
        %{"campaign_id" => @cid, "fact_id" => fact_id, "arc_id" => arc_id, "set_by" => "d"},
        seq,
        event_id: "fa-fra-#{seq}"
      )
    )
  end

  # #953: Listen-Payload `arc_ids` (Override-Set; `[]` = explizit keine Bögen).
  defp fact_arc_ids!(fact_id, arc_ids, seq) do
    Materializer.apply_event(
      event(
        "FactArcSet",
        %{"campaign_id" => @cid, "fact_id" => fact_id, "arc_ids" => arc_ids, "set_by" => "d"},
        seq,
        event_id: "fa-fra-#{seq}"
      )
    )
  end

  # #953: Rücknahme (`arc_ids: null`) → nicht overridden, Extraktions-Base gilt.
  defp fact_arc_retract!(fact_id, seq) do
    Materializer.apply_event(
      event(
        "FactArcSet",
        %{"campaign_id" => @cid, "fact_id" => fact_id, "arc_ids" => nil, "set_by" => "d"},
        seq,
        event_id: "fa-fra-#{seq}"
      )
    )
  end

  defp assignments do
    facts = Repo.list_campaign_facts(@cid)
    Repo.fact_render_assignments(@cid, facts)
  end

  defp titel_set(list), do: list |> Enum.map(& &1.titel) |> MapSet.new()

  test "Label-Kette: Titel = Kanon, kind default arc; strang-los = kein Eintrag" do
    seed_facts!(1, [fact("f1", "der Auftrag"), fact("f2", "")], 100)

    a = assignments()
    assert a["f1"] == [%{titel: "der Auftrag", kind: "arc"}]
    refute Map.has_key?(a, "f2")
  end

  test "Cluster-Map zieht Fragmente zusammen; rename-Override liefert den Anzeige-Titel" do
    seed_facts!(1, [fact("f1", "der Auftrag"), fact("f2", "der Auftrags-Coup")], 100)
    registry!(%{"der auftrags-coup" => "der Auftrag"}, %{}, 101)
    override!("der Auftrag", "rename", 102, %{"new_name" => "Die Erpressung"})

    a = assignments()
    assert a["f1"] == [%{titel: "Die Erpressung", kind: "arc"}]
    assert a["f2"] == [%{titel: "Die Erpressung", kind: "arc"}]
  end

  test "identity-merge leitet die Label-Gruppe um (Ziel-Titel)" do
    seed_facts!(1, [fact("f1", "der Auftrag"), fact("f2", "das Nebending")], 100)
    override!("das Nebending", "merge", 101, %{"merge_into" => "der Auftrag"})

    a = assignments()
    assert a["f2"] == [%{titel: "der Auftrag", kind: "arc"}]
  end

  test "kinds werden durchgereicht: context + rauschen (LLM-Klassifikation und Override)" do
    seed_facts!(
      1,
      [fact("f1", "die Welt"), fact("f2", "das Protokoll"), fact("f3", "der Auftrag")],
      100
    )

    registry!(%{}, %{"die welt" => "context", "das protokoll" => "rauschen"}, 101)
    override!("der Auftrag", "mark_rauschen", 102)

    a = assignments()
    assert [%{kind: "context"}] = a["f1"]
    assert [%{kind: "rauschen"}] = a["f2"]
    assert [%{kind: "rauschen"}] = a["f3"]
  end

  # ─── #953: N:M über Extraktions-Labels ──────────────────────────────

  test "N:M: Fakt mit zwei Labels rendert unter BEIDEN Bögen (Sekundär-Label ohne Thread synthetisiert)" do
    seed_facts!(1, [fact_multi("f1", ["der Auftrag", "die Fehde"])], 100)

    a = assignments()
    # „der Auftrag" ist Primär-Label → eigener Thread; „die Fehde" ist reines
    # Sekundär-Label ohne Thread → wird synthetisiert (Titel = Kanon, kind arc).
    assert length(a["f1"]) == 2
    assert titel_set(a["f1"]) == MapSet.new(["der Auftrag", "die Fehde"])
    assert Enum.all?(a["f1"], &(&1.kind == "arc"))
  end

  test "N:M: zwei Labels desselben Bogens (Cluster) → EIN Eintrag (Dedup)" do
    seed_facts!(1, [fact_multi("f1", ["der Auftrags-Coup", "der Auftrag"])], 100)
    registry!(%{"der auftrags-coup" => "der Auftrag"}, %{}, 101)

    a = assignments()
    assert a["f1"] == [%{titel: "der Auftrag", kind: "arc"}]
  end

  test "Sekundär-Label erbt kind aus der Registry (context bleibt context)" do
    seed_facts!(1, [fact_multi("f1", ["der Auftrag", "das Regelwerk"])], 100)
    registry!(%{}, %{"das regelwerk" => "context"}, 101)

    a = assignments()
    assert titel_set(a["f1"]) == MapSet.new(["der Auftrag", "das Regelwerk"])
    assert Enum.find(a["f1"], &(&1.titel == "das Regelwerk")).kind == "context"
    assert Enum.find(a["f1"], &(&1.titel == "der Auftrag")).kind == "arc"
  end

  # ─── #953: FactArcSet-Override-Set (drei Zustände) ──────────────────

  test "FactArcSet (Alt-Skalar) schlägt die Label-Kette: Fakt trägt Titel+kind des Ziel-Bogens" do
    seed_facts!(1, [fact("f1", "der Auftrag"), fact("f2", "die Fehde")], 100)
    arc!("arc_a", ["der auftrag"], 101)
    arc!("arc_b", ["die fehde"], 102)
    fact_arc!("f1", "arc_b", 103)

    a = assignments()
    assert a["f1"] == [%{titel: "die Fehde", kind: "arc"}]
    assert a["f2"] == [%{titel: "die Fehde", kind: "arc"}]
  end

  test "Override-Set: Fakt wird ZWEI Bögen zugeordnet (arc_ids-Liste)" do
    seed_facts!(1, [fact("f1", "der Auftrag"), fact("f2", "die Fehde")], 100)
    arc!("arc_a", ["der auftrag"], 101)
    arc!("arc_b", ["die fehde"], 102)
    fact_arc_ids!("f1", ["arc_a", "arc_b"], 103)

    a = assignments()
    assert length(a["f1"]) == 2
    assert titel_set(a["f1"]) == MapSet.new(["der Auftrag", "die Fehde"])
  end

  test "Override `[]` (explizit keine Bögen) → strang-los, Base greift NICHT" do
    seed_facts!(1, [fact("f1", "der Auftrag")], 100)
    arc!("arc_a", ["der auftrag"], 101)
    fact_arc_ids!("f1", [], 102)

    refute Map.has_key?(assignments(), "f1")
  end

  test "Rücknahme (arc_ids null) ≠ leeres Set: Extraktions-Base gilt wieder" do
    seed_facts!(1, [fact("f1", "der Auftrag")], 100)
    arc!("arc_a", ["der auftrag"], 101)
    # erst explizit leeres Set (strang-los) …
    fact_arc_ids!("f1", [], 102)
    refute Map.has_key?(assignments(), "f1")

    # … dann Rücknahme → Base kehrt zurück (drei getrennte Zustände, #766).
    fact_arc_retract!("f1", 103)
    assert assignments()["f1"] == [%{titel: "der Auftrag", kind: "arc"}]
  end

  # ─── #953: Merge-Redirect + verwaiste arc_ids (flag-not-drop) ───────

  test "Override auf gemergten Quell-Arc landet beim Redirect-Ziel" do
    seed_facts!(1, [fact("f1", "der Auftrag"), fact("f2", "die Fehde")], 100)
    arc!("arc_quelle", ["irgendwas"], 101)
    arc!("arc_ziel", ["die fehde"], 102)
    merge!("arc_quelle", "arc_ziel", 103)
    fact_arc_ids!("f1", ["arc_quelle"], 104)

    a = assignments()
    assert a["f1"] == [%{titel: "die Fehde", kind: "arc"}]
  end

  test "Override-Set mit einer verwaisten arc_id: bekannte rein, unbekannte raus" do
    seed_facts!(1, [fact("f1", "der Auftrag")], 100)
    arc!("arc_a", ["der auftrag"], 101)
    fact_arc_ids!("f1", ["arc_a", "arc_gibtsnicht"], 102)

    a = assignments()
    assert a["f1"] == [%{titel: "der Auftrag", kind: "arc"}]
  end

  test "Override NUR auf verwaisten Arc → strang-los (flag-not-drop; Base wird NICHT wiederhergestellt)" do
    seed_facts!(1, [fact("f1", "der Auftrag")], 100)
    arc!("arc_a", ["der auftrag"], 101)
    arc!("arc_orphan", ["nirgends gepaart"], 102)
    fact_arc_ids!("f1", ["arc_orphan"], 103)

    refute Map.has_key?(assignments(), "f1")
  end

  test "Override auf nie-existenten Arc → strang-los" do
    seed_facts!(1, [fact("f1", "der Auftrag")], 100)
    arc!("arc_a", ["der auftrag"], 101)
    fact_arc_ids!("f1", ["arc_gibtsnicht"], 102)

    refute Map.has_key?(assignments(), "f1")
  end

  test "Gemischter Bestand: Alt-Skalar-Row + Listen-Row in einer Kampagne lesen beide korrekt" do
    seed_facts!(1, [fact("f1", "der Auftrag"), fact("f2", "die Fehde")], 100)
    arc!("arc_a", ["der auftrag"], 101)
    arc!("arc_b", ["die fehde"], 102)
    fact_arc!("f1", "arc_b", 103)
    fact_arc_ids!("f2", ["arc_a"], 104)

    a = assignments()
    assert a["f1"] == [%{titel: "die Fehde", kind: "arc"}]
    assert a["f2"] == [%{titel: "der Auftrag", kind: "arc"}]
  end

  test "unbekannte Fakten (nicht im Kampagnen-Korpus) gruppieren über ihr Label" do
    seed_facts!(1, [fact("f1", "der Auftrag")], 100)

    a = Repo.fact_render_assignments(@cid, [fact("f_fremd", "der Auftrag"), fact("f_leer", "")])
    assert a["f_fremd"] == [%{titel: "der Auftrag", kind: "arc"}]
    refute Map.has_key?(a, "f_leer")
  end
end
