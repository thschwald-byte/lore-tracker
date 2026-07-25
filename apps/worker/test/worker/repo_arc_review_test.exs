defmodule Worker.RepoArcReviewTest do
  @moduledoc """
  Issue #905 (Epic #900 S3): Merge-Redirect + arc_review + Fakt-Ebene am
  Reader. Gepinnt: die Redirect-Invariante (Zyklus/Kette/Ziel-fehlt),
  Quelle+Ziel-Doppel-Pairing mit Fakt-genauem Maximum, verwaiste Arcs
  (inkl. ruhendem Close-Status + Merge-Vorschlag), Gemergte-Unterliste
  (auch wirkungslose), Fakt-Override rein/raus kippt das versandet-Gate,
  Override auf nicht-existenten Arc, Fakt-Listen-Inhalt + Wire-Flachheit.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.{Materializer, Repo}
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-arcrev-905"

  setup do
    clear_all_tables!()
    {:atomic, :ok} = :mnesia.clear_table(S.worker_state())
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
    build_campaign(campaign_id: @cid, sessions: [1, 1, 1, 1, 1], apply: true)
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
        event_id: "sfe-rev-#{session_n}-#{seq}"
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
        event_id: "ac-#{seq}"
      )
    )
  end

  defp merge!(quelle, ziel, seq) do
    Materializer.apply_event(
      event(
        "ArcMergeSet",
        %{"arc_id" => quelle, "campaign_id" => @cid, "merge_into" => ziel, "set_by" => "d"},
        seq,
        event_id: "am-#{seq}"
      )
    )
  end

  defp closed!(arc_id, grund, wl, seq) do
    Materializer.apply_event(
      event(
        "ArcClosed",
        %{
          "arc_id" => arc_id,
          "campaign_id" => @cid,
          "grund" => grund,
          "wasserlinie_session" => wl,
          "set_by" => "d"
        },
        seq,
        event_id: "acl-#{seq}"
      )
    )
  end

  defp fact_arc!(fact_id, arc_id, seq) do
    Materializer.apply_event(
      event(
        "FactArcSet",
        %{"campaign_id" => @cid, "fact_id" => fact_id, "arc_id" => arc_id, "set_by" => "d"},
        seq,
        event_id: "fa-#{seq}"
      )
    )
  end

  defp view, do: Repo.campaign_threads_with_review(@cid)
  defp find(canonical), do: Enum.find(view().threads, &(&1.canonical == canonical))

  test "wirksamer Merge: Quell-Thread zählt fürs Ziel; Quelle in Gemergte-Liste" do
    seed_facts!(1, [fact("f1", "der Auftrag")], 100)
    seed_facts!(5, [fact("f2", "der Auftrags-Coup")], 101)
    arc!("arc_ziel", ["der auftrag"], 102)
    arc!("arc_quelle", ["der auftrags-coup"], 103)
    merge!("arc_quelle", "arc_ziel", 104)
    closed!("arc_ziel", "versandet", 4, 105)

    # Der Quell-Thread (S5) redirected aufs Ziel → Fakt-Max 5 > 4 → offen.
    a = find("der Auftrag")
    b = find("der Auftrags-Coup")
    assert a.arc_id == "arc_ziel" and b.arc_id == "arc_ziel"
    assert a.arc_status == "offen" and b.arc_status == "offen"

    r = view().arc_review
    assert r.verwaiste == []
    assert [%{arc_id: "arc_quelle", merge_into: "arc_ziel", wirksam?: true}] = r.gemergte
  end

  test "Zyklus A↔B: beide wirkungslos, beide sichtbar, beide in Gemergte-Liste" do
    seed_facts!(1, [fact("f1", "strang a"), fact("f2", "strang b")], 100)
    arc!("arc_a", ["strang a"], 101)
    arc!("arc_b", ["strang b"], 102)
    merge!("arc_a", "arc_b", 103)
    merge!("arc_b", "arc_a", 104)

    ta = find("strang a")
    tb = find("strang b")
    assert ta.arc_id == "arc_a"
    assert tb.arc_id == "arc_b"

    r = view().arc_review
    assert Enum.map(r.gemergte, & &1.arc_id) == ["arc_a", "arc_b"]
    assert Enum.all?(r.gemergte, &(&1.wirksam? == false))
  end

  test "Kette A→B→C: nur B wirksam; A bleibt sichtbar auf sich selbst" do
    seed_facts!(1, [fact("f1", "strang a"), fact("f2", "strang b"), fact("f3", "strang c")], 100)
    arc!("arc_a", ["strang a"], 101)
    arc!("arc_b", ["strang b"], 102)
    arc!("arc_c", ["strang c"], 103)
    merge!("arc_a", "arc_b", 104)
    merge!("arc_b", "arc_c", 105)

    assert find("strang a").arc_id == "arc_a"
    assert find("strang b").arc_id == "arc_c"
    assert find("strang c").arc_id == "arc_c"

    r = view().arc_review

    assert Enum.map(r.gemergte, &{&1.arc_id, &1.wirksam?}) == [
             {"arc_a", false},
             {"arc_b", true}
           ]
  end

  test "Ziel fehlt (Reorder): Merge transient wirkungslos, aktiviert sich bei ArcCreated" do
    seed_facts!(1, [fact("f1", "strang a"), fact("f2", "strang z")], 100)
    arc!("arc_a", ["strang a"], 101)
    merge!("arc_a", "arc_spaeter", 102)

    assert find("strang a").arc_id == "arc_a"
    assert [%{arc_id: "arc_a", wirksam?: false}] = view().arc_review.gemergte

    arc!("arc_spaeter", ["strang z"], 103)
    assert find("strang a").arc_id == "arc_spaeter"
    assert [%{arc_id: "arc_a", wirksam?: true}] = view().arc_review.gemergte
  end

  test "verwaister Arc: Eintrag trägt ruhenden Close-Status + Merge-Vorschlag" do
    seed_facts!(1, [fact("f1", "der Auftrag")], 100)
    arc!("arc_sichtbar", ["der auftrag"], 101)
    # Verwaist: Seeds paaren keinen Thread, überlappen aber arc_sichtbar.
    arc!("arc_orphan", ["der auftrag", "vergessenes label"], 102)

    # Tie-Break: arc_orphan hat größere Schnittmenge? Nein — beide schneiden
    # {der auftrag} mit Größe 1 → kleinste arc_id gewinnt: arc_orphan < arc_sichtbar!
    # Deshalb hier bewusst prüfen, WER paart, statt es anzunehmen.
    t = find("der Auftrag")
    assert t.arc_id == "arc_orphan"

    # arc_sichtbar ist damit der Verwaiste — mit Vorschlag auf den Paarenden.
    closed!("arc_sichtbar", "geloest", 1, 103)
    r = view().arc_review
    assert [orphan] = r.verwaiste
    assert orphan.arc_id == "arc_sichtbar"
    assert orphan.arc_status == "geschlossen"
    assert orphan.arc_grund == "geloest"
    assert orphan.vorschlag_arc_id == "arc_orphan"
    assert orphan.seeds == ["der auftrag"]
  end

  test "Fakt-Override rein/raus kippt das versandet-Gate (Fakt-genaues Maximum)" do
    seed_facts!(1, [fact("f1", "der Auftrag")], 100)
    seed_facts!(5, [fact("f9", "anderer Strang")], 101)
    arc!("arc_a", ["der auftrag"], 102)
    closed!("arc_a", "versandet", 4, 103)

    # Ohne Override: max_fakt_session(arc_a) = 1 ≤ 4 → geschlossen.
    assert find("der Auftrag").arc_status == "geschlossen"

    # f9 (Session 5) per Override in arc_a → 5 > 4 → offen.
    fact_arc!("f9", "arc_a", 104)
    assert find("der Auftrag").arc_status == "offen"

    # Undo ("") → wieder geschlossen.
    fact_arc!("f9", "", 105)
    assert find("der Auftrag").arc_status == "geschlossen"
  end

  test "Fakt-Override RAUS: überstimmter Fakt hält den eigenen Arc nicht mehr offen" do
    seed_facts!(1, [fact("f1", "der Auftrag")], 100)
    seed_facts!(5, [fact("f5", "der Auftrag")], 101)
    arc!("arc_a", ["der auftrag"], 102)
    arc!("arc_b", ["woanders"], 103)
    closed!("arc_a", "versandet", 4, 104)

    # f5 (S5) hält arc_a offen (5 > 4) …
    assert find("der Auftrag").arc_status == "offen"

    # … bis er nach arc_b überstimmt wird → arc_a-Max fällt auf 1 → geschlossen.
    fact_arc!("f5", "arc_b", 105)
    assert find("der Auftrag").arc_status == "geschlossen"
  end

  test "Override auf nicht-existenten Arc ist wirkungslos (Label-Kette gilt)" do
    seed_facts!(1, [fact("f1", "der Auftrag")], 100)
    arc!("arc_a", ["der auftrag"], 101)
    fact_arc!("f1", "arc_gibtsnicht", 102)

    t = find("der Auftrag")
    assert t.arc_id == "arc_a"
    assert [%{id: "f1", effective_arc_id: "arc_a", overridden?: true}] = t.fact_list
  end

  test "Fakt-Liste: id+claim+session, rauschen-Stränge sparen die Bytes" do
    seed_facts!(2, [fact("f1", "der Auftrag"), fact("f2", "das Protokoll")], 100)

    Materializer.apply_event(
      event(
        "ThreadRegistryComputed",
        %{
          "campaign_id" => @cid,
          "cluster_map" => %{},
          "kinds" => %{"das protokoll" => "rauschen"}
        },
        101,
        event_id: "trc-rev"
      )
    )

    arc!("arc_a", ["der auftrag"], 102)

    t = find("der Auftrag")

    assert [%{id: "f1", claim: "Fakt f1", session_number: 2, effective_arc_id: "arc_a"}] =
             t.fact_list

    rauschen = find("das Protokoll")
    assert rauschen.fact_list == []
  end

  test "Wire-Flachheit: Review-Einträge + Fakt-Listen sind Jason-encodebar" do
    seed_facts!(1, [fact("f1", "der Auftrag")], 100)
    arc!("arc_a", ["der auftrag"], 101)
    arc!("arc_orphan", ["weg"], 102)
    merge!("arc_orphan", "arc_a", 103)

    %{threads: threads, arc_review: review} = view()

    assert {:ok, _} = Jason.encode(review)
    assert {:ok, _} = threads |> Enum.map(&Map.delete(&1, :facts)) |> Jason.encode()
  end
end
