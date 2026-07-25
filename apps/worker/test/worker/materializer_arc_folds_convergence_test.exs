defmodule Worker.MaterializerArcFoldsConvergenceTest do
  @moduledoc """
  Issue #903 (Epic #900 S2): Konvergenz der Arc-Folds unter Event-Reorder.

  Drei Fold-Gruppen auf EINER `worker_arcs`-Row (:arc_created / :arc_act
  geteilt für Closed+Reopened / :arc_leitfrage). Gepinnt werden die vier
  Plan-Invarianten: (1) Akt-LWW konvergiert in allen Orderings inkl.
  Mid-Insert, (2) Reopened nil-t seine Gruppe (Whole-Snapshot, kein
  Partial-Payload), (3) Stub-Upsert — Akt/Leitfrage VOR Created droppen
  nie, (4) Created clobbert fremde Gruppen nie. Dazu die Querschnitt-
  Klassen aus #894/#896: Doppel-Zustellung, nil-event_id, Cascade.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Materializer
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-arc-903"
  @arc "arc_test903"

  setup do
    clear_all_tables!()
    {:atomic, :ok} = :mnesia.clear_table(S.worker_state())
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
    :ok
  end

  # ─── Event-Builder (Daten, nicht sofort applied) ────────────────────

  defp ev_created(eid, seq, opts \\ []) do
    event(
      "ArcCreated",
      %{
        "arc_id" => @arc,
        "campaign_id" => @cid,
        "leitfrage_draft" => Keyword.get(opts, :draft, "Wie löst sich ‚der Auftrag' auf?"),
        "seed_raw_labels" => Keyword.get(opts, :seeds, ["der auftrag"])
      },
      seq,
      event_id: eid
    )
  end

  defp ev_closed(eid, seq, grund \\ "versandet", wl \\ 4) do
    event(
      "ArcClosed",
      %{
        "arc_id" => @arc,
        "campaign_id" => @cid,
        "grund" => grund,
        "wasserlinie_session" => wl,
        "set_by" => "did-1"
      },
      seq,
      event_id: eid
    )
  end

  defp ev_reopened(eid, seq) do
    event("ArcReopened", %{"arc_id" => @arc, "campaign_id" => @cid, "set_by" => "did-1"}, seq,
      event_id: eid
    )
  end

  defp ev_leitfrage(eid, seq, text) do
    event(
      "LeitfrageSet",
      %{"arc_id" => @arc, "campaign_id" => @cid, "text" => text, "set_by" => "did-1"},
      seq,
      event_id: eid
    )
  end

  defp ev_merge(eid, seq, target) do
    event(
      "ArcMergeSet",
      %{"arc_id" => @arc, "campaign_id" => @cid, "merge_into" => target, "set_by" => "did-1"},
      seq,
      event_id: eid
    )
  end

  defp row do
    case :mnesia.dirty_read(S.arcs(), @arc) do
      [{_t, _id, cid, seeds, draft, ak, ag, aw, lk, mi}] ->
        %{
          cid: cid,
          seeds: seeds,
          draft: draft,
          act: ak,
          grund: ag,
          wl: aw,
          kuratiert: lk,
          merged: mi
        }

      [] ->
        nil
    end
  end

  # Jede Ordnung auf frischem Zustand applien + Row lesen.
  defp converge(orderings) do
    for order <- orderings do
      reset_for_permutation!()
      Enum.each(order, &Materializer.apply_event/1)
      row()
    end
  end

  defp permutations([]), do: [[]]

  defp permutations(list),
    do: for(x <- list, rest <- permutations(list -- [x]), do: [x | rest])

  # ─── Grundfall + Akt-LWW ────────────────────────────────────────────

  test "ArcCreated materialisiert die Row (Seeds + Draft, Akt-Gruppe leer)" do
    assert {:applied, _} = Materializer.apply_event(ev_created("e05", 1))

    assert %{cid: @cid, seeds: ["der auftrag"], act: nil, grund: nil, wl: nil, kuratiert: nil} =
             row()
  end

  test "Akt-LWW: Close/Reopen konvergiert in beiden Ordnungen (Reopen neuer)" do
    results =
      converge(permutations([ev_created("e01", 1), ev_closed("e05", 2), ev_reopened("e09", 3)]))

    assert [first | rest] = results
    assert Enum.all?(rest, &(&1 == first))
    assert %{act: "reopened", grund: nil, wl: nil} = first
  end

  test "Akt-LWW: Close neuer als Reopen → geschlossen, in allen Ordnungen" do
    results = converge(permutations([ev_reopened("e05", 1), ev_closed("e09", 2, "geloest", 6)]))

    assert [first | rest] = results
    assert Enum.all?(rest, &(&1 == first))
    assert %{act: "closed", grund: "geloest", wl: 6} = first
  end

  test "Mid-Insert [close e5, reopen e9, close e7] → reopened, alle 6 Permutationen" do
    events = [ev_closed("e05", 1), ev_reopened("e09", 2), ev_closed("e07", 3, "geloest", 5)]
    results = converge(permutations(events))

    assert [first | rest] = results
    assert Enum.all?(rest, &(&1 == first))
    # e09 ist der höchste Akt → reopened; grund/wl der Verlierer clobbern nicht.
    assert %{act: "reopened", grund: nil, wl: nil} = first
  end

  test "Reopened nil-t die Akt-Gruppe explizit (Whole-Snapshot, kein Partial)" do
    assert {:applied, _} = Materializer.apply_event(ev_closed("e05", 1, "geloest", 4))
    assert %{act: "closed", grund: "geloest", wl: 4} = row()

    assert {:applied, _} = Materializer.apply_event(ev_reopened("e09", 2))
    assert %{act: "reopened", grund: nil, wl: nil} = row()
  end

  # ─── Stub-Upsert + Gruppen-Isolation ────────────────────────────────

  test "Stub: Akt VOR Created droppt nicht — beide Ordnungen enden identisch" do
    results = converge(permutations([ev_created("e03", 1), ev_closed("e05", 2)]))

    assert [first | rest] = results
    assert Enum.all?(rest, &(&1 == first))
    # Created-Gruppe UND Akt-Gruppe beide da, egal wer zuerst ankam.
    assert %{seeds: ["der auftrag"], act: "closed", grund: "versandet", wl: 4} = first
  end

  test "Stub: LeitfrageSet VOR Created; leerer Text ist Undo-Row (nie delete)" do
    assert {:applied, _} = Materializer.apply_event(ev_leitfrage("e05", 1, "Echte Frage?"))
    assert %{kuratiert: "Echte Frage?", seeds: []} = row()

    assert {:applied, _} = Materializer.apply_event(ev_created("e03", 2))
    assert %{kuratiert: "Echte Frage?", seeds: ["der auftrag"]} = row()

    assert {:applied, _} = Materializer.apply_event(ev_leitfrage("e07", 3, ""))
    assert %{kuratiert: ""} = row()
  end

  test "ArcCreated clobbert Akt + kuratierte Leitfrage NIE (auch als Neuestes)" do
    assert {:applied, _} = Materializer.apply_event(ev_closed("e05", 1, "geloest", 3))
    assert {:applied, _} = Materializer.apply_event(ev_leitfrage("e07", 2, "Kuratiert!"))
    assert {:applied, _} = Materializer.apply_event(ev_created("e09", 3, draft: "Draft-Frage?"))

    assert %{
             act: "closed",
             grund: "geloest",
             wl: 3,
             kuratiert: "Kuratiert!",
             draft: "Draft-Frage?"
           } =
             row()
  end

  # ─── Querschnitt (Doppel-Zustellung, nil-event_id, Defekt-Payloads) ─

  test "Doppel-Zustellung ist idempotent (gleiche event_id supersedet nicht)" do
    ev = ev_closed("e05", 1)
    assert {:applied, _} = Materializer.apply_event(ev)
    before = row()

    _ = Materializer.apply_event(ev)
    assert row() == before
  end

  test "nil-event_id (Legacy) clobbert einen geschlüsselten Akt nicht" do
    assert {:applied, _} = Materializer.apply_event(ev_closed("e09", 1, "geloest", 7))

    legacy = event("ArcReopened", %{"arc_id" => @arc, "campaign_id" => @cid}, 50)
    _ = Materializer.apply_event(legacy)

    assert %{act: "closed", grund: "geloest", wl: 7} = row()
  end

  test "unbekannter grund wird gedroppt (kein Stub, kein Fold-Winner)" do
    _ = Materializer.apply_event(ev_closed("e05", 1, "quatsch"))
    assert row() == nil
    assert :mnesia.dirty_read(S.fold_meta(), {S.arcs(), @arc, :arc_act}) == []
  end

  test "nicht-integer Wasserlinie wird defensiv nil (Reader behandelt als 0)" do
    assert {:applied, _} = Materializer.apply_event(ev_closed("e05", 1, "versandet", "kaputt"))
    assert %{act: "closed", grund: "versandet", wl: nil} = row()
  end

  # ─── #905: Merge-Fold + Fakt→Arc-Override ───────────────────────────

  test "Vier-Gruppen-Permutationen [created, merge, act, leitfrage] konvergieren (24×)" do
    events = [
      ev_created("e01", 1),
      ev_merge("e03", 2, "arc_ziel"),
      ev_closed("e05", 3, "geloest", 2),
      ev_leitfrage("e07", 4, "F?")
    ]

    results = converge(permutations(events))

    assert [first | rest] = results
    assert Enum.all?(rest, &(&1 == first))

    assert %{
             seeds: ["der auftrag"],
             merged: "arc_ziel",
             act: "closed",
             grund: "geloest",
             kuratiert: "F?"
           } = first
  end

  test "Merge VOR Created (Stub) — beide Ordnungen identisch" do
    results = converge(permutations([ev_created("e03", 1), ev_merge("e05", 2, "arc_ziel")]))

    assert [first | rest] = results
    assert Enum.all?(rest, &(&1 == first))
    assert %{seeds: ["der auftrag"], merged: "arc_ziel"} = first
  end

  test "Merge-Undo ('') via LWW — beide Ordnungen konvergieren" do
    results = converge(permutations([ev_merge("e05", 1, "arc_ziel"), ev_merge("e09", 2, "")]))

    assert [first | rest] = results
    assert Enum.all?(rest, &(&1 == first))
    # e09 (Undo) ist neuer → reguläre ""-Row, nie delete.
    assert %{merged: ""} = first
  end

  test "Self-Merge wird gedroppt (kein Stub, kein Fold-Winner)" do
    _ = Materializer.apply_event(ev_merge("e05", 1, @arc))
    assert row() == nil
    assert :mnesia.dirty_read(S.fold_meta(), {S.arcs(), @arc, :arc_merge}) == []
  end

  test "Merge: Doppel-Zustellung idempotent + nil-event_id clobbert nicht" do
    ev = ev_merge("e09", 1, "arc_ziel")
    assert {:applied, _} = Materializer.apply_event(ev)
    before = row()
    _ = Materializer.apply_event(ev)
    assert row() == before

    legacy =
      event("ArcMergeSet", %{"arc_id" => @arc, "campaign_id" => @cid, "merge_into" => ""}, 50)

    _ = Materializer.apply_event(legacy)
    assert %{merged: "arc_ziel"} = row()
  end

  defp fact_override(fact_id) do
    case :mnesia.dirty_read(S.fact_arc_overrides(), "#{@cid}:#{fact_id}") do
      [{_t, _k, _cid, _fid, arc_id, _eid}] -> arc_id
      [] -> nil
    end
  end

  test "FactArcSet: LWW + Undo-Row + Doppel-Zustellung" do
    ev1 =
      event(
        "FactArcSet",
        %{"campaign_id" => @cid, "fact_id" => "f_x", "arc_id" => "arc_a", "set_by" => "d"},
        1,
        event_id: "fa-e05"
      )

    assert {:applied, _} = Materializer.apply_event(ev1)
    assert fact_override("f_x") == "arc_a"

    # Undo ("") neuer → reguläre Row.
    assert {:applied, _} =
             Materializer.apply_event(
               event(
                 "FactArcSet",
                 %{"campaign_id" => @cid, "fact_id" => "f_x", "arc_id" => "", "set_by" => "d"},
                 2,
                 event_id: "fa-e09"
               )
             )

    assert fact_override("f_x") == ""

    # Stale-Replay des älteren Events clobbert nicht.
    _ = Materializer.apply_event(ev1)
    assert fact_override("f_x") == ""
  end

  # ─── Cascade ────────────────────────────────────────────────────────

  test "CampaignDeleted räumt Arc-Row + alle VIER Fold-Gruppen + Fakt-Overrides" do
    assert {:applied, _} = Materializer.apply_event(ev_created("e03", 1))
    assert {:applied, _} = Materializer.apply_event(ev_closed("e05", 2))
    assert {:applied, _} = Materializer.apply_event(ev_leitfrage("e07", 3, "F?"))
    assert {:applied, _} = Materializer.apply_event(ev_merge("e08", 4, "arc_ziel"))

    assert {:applied, _} =
             Materializer.apply_event(
               event(
                 "FactArcSet",
                 %{"campaign_id" => @cid, "fact_id" => "f_c", "arc_id" => @arc, "set_by" => "d"},
                 5,
                 event_id: "fa-e10"
               )
             )

    assert {:applied, _} =
             Materializer.apply_event(
               event("CampaignDeleted", %{"campaign_id" => @cid, "deleted_by" => "x"}, 6,
                 event_id: "e90"
               )
             )

    assert row() == nil
    assert fact_override("f_c") == nil

    # #905: :arc_merge MUSS mit-geräumt sein — arc_content_id ist
    # deterministisch, ein stale Winner würde die Neu-Inkarnation gaten.
    for fold <- [:arc_created, :arc_act, :arc_leitfrage, :arc_merge] do
      assert :mnesia.dirty_read(S.fold_meta(), {S.arcs(), @arc, fold}) == []
    end

    assert :mnesia.dirty_read(
             S.fold_meta(),
             {S.fact_arc_overrides(), "#{@cid}:f_c", :fact_arc_set}
           ) ==
             []
  end

  test "SessionDeleted lässt die Arc-Row unberührt (Arcs sind campaign-scoped)" do
    assert {:applied, _} = Materializer.apply_event(ev_created("e03", 1))

    assert {:applied, _} =
             Materializer.apply_event(
               event("SessionDeleted", %{"session_id" => "s-1", "campaign_id" => @cid}, 2,
                 event_id: "e50"
               )
             )

    assert %{seeds: ["der auftrag"]} = row()
  end
end
