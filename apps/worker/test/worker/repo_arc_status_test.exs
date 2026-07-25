defmodule Worker.RepoArcStatusTest do
  @moduledoc """
  Issue #903 (Epic #900 S2): die Arc-Status-ABLEITUNG am Reader
  (`Worker.Repo.campaign_threads/1` + attach_arcs). Gepinnt: alle
  Ableitungszweige (kein Akt / Reopened / geloest bleibt zu trotz
  Nachwirkung / versandet-Gate beide Seiten / nil-Wasserlinie), die
  Akt-Präzedenz über den Legacy-lifecycle-resolve (#900-Fund A7), Orphan-
  Arcs, Zwei-Threads-ein-Arc-Konsistenz und die Flachheit der Wire-Felder.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.{Materializer, Repo}
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-arcstat-903"

  setup do
    clear_all_tables!()
    {:atomic, :ok} = :mnesia.clear_table(S.worker_state())
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
    # 5 Sessions → Nummern 1..5 (versandet-Gate braucht spätere Fakt-Sessions).
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
        event_id: "sfe-as-#{session_n}-#{seq}"
      )
    )
  end

  defp arc_created!(arc_id, seeds, seq) do
    Materializer.apply_event(
      event(
        "ArcCreated",
        %{
          "arc_id" => arc_id,
          "campaign_id" => @cid,
          "leitfrage_draft" => "Wie löst sich das auf?",
          "seed_raw_labels" => seeds
        },
        seq,
        event_id: "ac-#{seq}"
      )
    )
  end

  defp arc_closed!(arc_id, grund, wl, seq) do
    Materializer.apply_event(
      event(
        "ArcClosed",
        %{
          "arc_id" => arc_id,
          "campaign_id" => @cid,
          "grund" => grund,
          "wasserlinie_session" => wl,
          "set_by" => "did-1"
        },
        seq,
        event_id: "acl-#{seq}"
      )
    )
  end

  defp arc_reopened!(arc_id, seq) do
    Materializer.apply_event(
      event("ArcReopened", %{"arc_id" => arc_id, "campaign_id" => @cid, "set_by" => "d"}, seq,
        event_id: "aro-#{seq}"
      )
    )
  end

  defp find(canonical),
    do: Enum.find(Repo.campaign_threads(@cid), &(&1.canonical == canonical))

  test "kein Akt → arc offen; Leitfrage = Draft; Thread-Status unberührt" do
    seed_facts!(1, [fact("f1", "der Auftrag")], 100)
    arc_created!("arc_a", ["der auftrag"], 101)

    t = find("der Auftrag")
    assert t.arc_id == "arc_a"
    assert t.arc_status == "offen"
    assert t.arc_grund == nil
    assert t.leitfrage == "Wie löst sich das auf?"
    refute t.leitfrage_kuratiert?
    # 4 nachfolgende Sessions ohne Fakt → ruhend (Basis-Logik unberührt).
    assert t.status == :ruhend
  end

  test "LeitfrageSet überstimmt den Draft; leerer Text = Undo → Draft gilt" do
    seed_facts!(1, [fact("f1", "der Auftrag")], 100)
    arc_created!("arc_a", ["der auftrag"], 101)

    Materializer.apply_event(
      event(
        "LeitfrageSet",
        %{
          "arc_id" => "arc_a",
          "campaign_id" => @cid,
          "text" => "Kriegen sie ihn?",
          "set_by" => "d"
        },
        102,
        event_id: "lf-1"
      )
    )

    t = find("der Auftrag")
    assert t.leitfrage == "Kriegen sie ihn?"
    assert t.leitfrage_kuratiert?

    Materializer.apply_event(
      event(
        "LeitfrageSet",
        %{"arc_id" => "arc_a", "campaign_id" => @cid, "text" => "", "set_by" => "d"},
        103,
        event_id: "lf-2"
      )
    )

    t2 = find("der Auftrag")
    assert t2.leitfrage == "Wie löst sich das auf?"
    refute t2.leitfrage_kuratiert?
  end

  test "geloest bleibt geschlossen trotz Nachwirkungs-Fakt aus späterer Session" do
    seed_facts!(1, [fact("f1", "der Auftrag")], 100)
    arc_created!("arc_a", ["der auftrag"], 101)
    arc_closed!("arc_a", "geloest", 1, 102)

    # Nachwirkung: neuer Fakt in Session 5 clustert auf den Strang.
    seed_facts!(5, [fact("f2", "der Auftrag")], 103)

    t = find("der Auftrag")
    assert t.arc_status == "geschlossen"
    assert t.arc_grund == "geloest"
    assert t.status == :aufgelöst
  end

  test "versandet-Gate: Fakt-Session > Wasserlinie reopent, ≤ bleibt zu" do
    seed_facts!(1, [fact("f1", "der Auftrag")], 100)
    arc_created!("arc_a", ["der auftrag"], 101)
    arc_closed!("arc_a", "versandet", 1, 102)

    # max_fakt_session == 1 == Wasserlinie → geschlossen (strikt >).
    t = find("der Auftrag")
    assert t.arc_status == "geschlossen"
    assert t.arc_grund == "versandet"

    # Neue Evidenz aus Session 5 > 1 → offen (automatischer Reopen).
    seed_facts!(5, [fact("f1", "der Auftrag"), fact("f2", "der Auftrag")], 103)
    t2 = find("der Auftrag")
    assert t2.arc_status == "offen"
    assert t2.arc_grund == nil
  end

  test "nil-Wasserlinie zählt als 0 (fail-open Richtung offen)" do
    seed_facts!(1, [fact("f1", "der Auftrag")], 100)
    arc_created!("arc_a", ["der auftrag"], 101)
    arc_closed!("arc_a", "versandet", nil, 102)

    # max_fakt_session 1 > 0 → offen.
    assert find("der Auftrag").arc_status == "offen"
  end

  test "Akt-Präzedenz: Legacy-resolve wird von ArcReopened überstimmt (A7)" do
    seed_facts!(1, [fact("f1", "der Auftrag")], 100)
    arc_created!("arc_a", ["der auftrag"], 101)

    # Prä-S2-Legacy-Override: lifecycle resolve.
    Materializer.apply_event(
      event(
        "ThreadOverrideSet",
        %{
          "campaign_id" => @cid,
          "canonical" => "der Auftrag",
          "action" => "resolve",
          "set_by" => "d"
        },
        102,
        event_id: "tos-as-1"
      )
    )

    assert find("der Auftrag").status == :aufgelöst

    # Reopen-Akt → Arc-Wahrheit exklusiv, der Legacy-resolve zählt nicht mehr.
    arc_reopened!("arc_a", 103)
    t = find("der Auftrag")
    assert t.arc_status == "offen"
    assert t.status in [:offen, :ruhend]
    refute t.status == :aufgelöst
  end

  test "Legacy-resolve OHNE Arc-Akt zählt weiter (Regression)" do
    seed_facts!(1, [fact("f1", "der Auftrag")], 100)
    arc_created!("arc_a", ["der auftrag"], 101)

    Materializer.apply_event(
      event(
        "ThreadOverrideSet",
        %{
          "campaign_id" => @cid,
          "canonical" => "der Auftrag",
          "action" => "resolve",
          "set_by" => "d"
        },
        102,
        event_id: "tos-as-2"
      )
    )

    t = find("der Auftrag")
    assert t.status == :aufgelöst
    assert t.arc_status == "offen"
  end

  test "Orphan-Arc (kein paarender Thread) wird still ignoriert" do
    seed_facts!(1, [fact("f1", "der Auftrag")], 100)
    arc_created!("arc_orphan", ["gibt es nicht mehr"], 101)

    t = find("der Auftrag")
    assert t.arc_id == nil
    assert t.arc_status == nil
  end

  test "zwei Threads, ein Arc: konsistenter Status über das Arc-Maximum" do
    # Zwei getrennte Threads (keine Cluster-Map), beide Labels in den Seeds.
    seed_facts!(1, [fact("f1", "der Auftrag")], 100)
    seed_facts!(5, [fact("f2", "der Auftrags-Coup")], 101)
    arc_created!("arc_a", ["der auftrag", "der auftrags-coup"], 102)
    arc_closed!("arc_a", "versandet", 4, 103)

    a = find("der Auftrag")
    b = find("der Auftrags-Coup")
    # max_fakt_session über BEIDE Threads = 5 > 4 → offen, an beiden gleich.
    assert a.arc_id == "arc_a" and b.arc_id == "arc_a"
    assert a.arc_status == "offen" and b.arc_status == "offen"
  end

  test "angereicherte Felder sind flach (Strings/nil/bool — Wire-Invariante A5)" do
    seed_facts!(1, [fact("f1", "der Auftrag")], 100)
    arc_created!("arc_a", ["der auftrag"], 101)
    arc_closed!("arc_a", "geloest", 1, 102)

    t = find("der Auftrag")

    for v <- [t.arc_id, t.arc_status, t.arc_grund, t.leitfrage] do
      assert is_binary(v) or is_nil(v)
    end

    assert is_boolean(t.leitfrage_kuratiert?)
    refute Map.has_key?(t, :base_status)
  end
end
