defmodule Worker.MaterializerSmoothedBlocksConvergenceTest do
  @moduledoc """
  Issue #863 (Epic #861 Slice B): Konvergenz + Cascade + Reader für das
  TranscriptSmoothed-Whole-Snapshot-Artefakt (`worker_smoothed_blocks`).

  Kern-Invariante (wie SessionFactsExtracted/#832): **Whole-Snapshot ⇒
  Voll-Ersatz, kein Merge** — zwei DIVERGENTE Snapshots → der höhere event_id
  gewinnt KOMPLETT, in jeder Zustell-Reihenfolge, auch bei Doppel-Zustellung.
  Plus: Session/Campaign-Cascade räumt die Row (inkl. des Drive-by-Fixes an
  session_facts, das denselben Lücken-Befund hatte).
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Materializer
  alias Worker.Repo
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-smooth-conv-863"
  @sid "sess-smooth-conv-863"

  setup do
    reset_for_permutation!()
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
    :ok
  end

  defp block(id, text, quell_ids) do
    %{
      "id" => id,
      "speaker_discord_id" => "SL",
      "text" => text,
      "quell_utterance_ids" => quell_ids,
      "asr_unsicher" => false,
      "hat_luecke" => false,
      "konfidenz" => "hoch"
    }
  end

  defp ts_event(blocks, seq, opts \\ []) do
    payload =
      %{
        "session_id" => @sid,
        "campaign_id" => @cid,
        "smoothed_at" => "2026-07-15T21:00:00Z",
        "blocks" => blocks,
        "ooc_verworfen" => Keyword.get(opts, :ooc, []),
        "rules_version" => Keyword.get(opts, :rules_version, 42),
        "merge_gap_seconds" => 8
      }

    case Keyword.get(opts, :event_id) do
      nil -> event("TranscriptSmoothed", payload, seq)
      eid -> event("TranscriptSmoothed", payload, seq, event_id: eid)
    end
  end

  defp read_row(key),
    do: elem(:mnesia.transaction(fn -> :mnesia.read(S.smoothed_blocks(), key) end), 1)

  test "TranscriptSmoothed materialisiert → get_smoothed_blocks liefert den Snapshot" do
    b = block("b_aaaa", "Der König betritt den Raum", ["u1", "u2"])
    Materializer.apply_event(ts_event([b], 1, event_id: "sm-ev-1", ooc: ["u9"]))

    snap = Repo.get_smoothed_blocks(@sid)
    assert snap.session_id == @sid
    assert snap.campaign_id == @cid
    assert snap.blocks == [b]
    assert snap.ooc_verworfen == ["u9"]
    assert snap.rules_version == 42
    assert snap.merge_gap_seconds == 8
    assert snap.smoothing_event_id == "sm-ev-1"
  end

  test "kein Smoothing gelaufen → nil" do
    assert Repo.get_smoothed_blocks("sess-nie-geglaettet") == nil
  end

  test "LWW: zwei DIVERGENTE Voll-Snapshots, höherer event_id gewinnt KOMPLETT (kein Merge)" do
    old = [block("b_old1", "Alt eins", ["u1"]), block("b_old2", "Alt zwei", ["u2"])]
    new = [block("b_new1", "Neu eins", ["u1", "u2"])]

    events = [
      ts_event(old, 1, event_id: "sm-ev-1", rules_version: 41),
      ts_event(new, 2, event_id: "sm-ev-2", rules_version: 42)
    ]

    results = materialize_permutations(events, fn -> Repo.get_smoothed_blocks(@sid) end)

    # In JEDER Reihenfolge exakt der neue Snapshot — nie eine Block-Union.
    Enum.each(results, fn snap ->
      assert snap.blocks == new
      assert snap.rules_version == 42
      assert snap.smoothing_event_id == "sm-ev-2"
    end)
  end

  test "Doppel-Zustellung desselben Events ist idempotent (explizit, nicht nur impliziert)" do
    b = block("b_x", "Text", ["u1"])
    ev = ts_event([b], 1, event_id: "sm-ev-7")

    Materializer.apply_event(ev)
    snap1 = Repo.get_smoothed_blocks(@sid)
    Materializer.apply_event(ev)
    snap2 = Repo.get_smoothed_blocks(@sid)

    assert snap1 == snap2
    assert snap2.blocks == [b]
  end

  test "nil-event_id (schlüsselloses Alt-Event) clobbert eine geschlüsselte Row NICHT" do
    Materializer.apply_event(
      ts_event([block("b_keyed", "Keyed", ["u1"])], 1, event_id: "sm-ev-9")
    )

    Materializer.apply_event(ts_event([block("b_legacy", "Legacy", ["u1"])], 2))

    assert Repo.get_smoothed_blocks(@sid).blocks |> hd() |> Map.get("id") == "b_keyed"
  end

  describe "Cascade" do
    test "SessionDeleted räumt smoothed_blocks + (Drive-by #863) session_facts" do
      Materializer.apply_event(
        event(
          "SessionScheduled",
          %{"id" => @sid, "campaign_id" => @cid, "number" => 1, "name" => "S1"},
          1
        )
      )

      Materializer.apply_event(ts_event([block("b_1", "T", ["u1"])], 2, event_id: "sm-ev-1"))

      Materializer.apply_event(
        event(
          "SessionFactsExtracted",
          %{
            "session_id" => @sid,
            "campaign_id" => @cid,
            "facts" => [%{"id" => "f1", "claim" => "c"}]
          },
          3,
          event_id: "fx-ev-1"
        )
      )

      assert read_row(@sid) != []
      assert Repo.get_session_facts(@sid) != nil

      Materializer.apply_event(
        event("SessionDeleted", %{"session_id" => @sid, "campaign_id" => @cid}, 4)
      )

      assert read_row(@sid) == []
      # Der Drive-by-Fix: session_facts war vor #863 in KEINER Cascade.
      assert Repo.get_session_facts(@sid) == nil
    end

    test "CampaignDeleted räumt smoothed_blocks + session_facts campaign-weit" do
      Materializer.apply_event(
        event("CampaignCreated", %{"id" => @cid, "name" => "Conv-Camp"}, 1)
      )

      Materializer.apply_event(
        event(
          "SessionScheduled",
          %{"id" => @sid, "campaign_id" => @cid, "number" => 1, "name" => "S1"},
          2
        )
      )

      Materializer.apply_event(ts_event([block("b_1", "T", ["u1"])], 3, event_id: "sm-ev-1"))

      Materializer.apply_event(
        event(
          "SessionFactsExtracted",
          %{
            "session_id" => @sid,
            "campaign_id" => @cid,
            "facts" => [%{"id" => "f1", "claim" => "c"}]
          },
          4,
          event_id: "fx-ev-1"
        )
      )

      Materializer.apply_event(
        event("CampaignDeleted", %{"campaign_id" => @cid, "id" => @cid}, 5)
      )

      assert read_row(@sid) == []
      assert Repo.get_session_facts(@sid) == nil
    end
  end
end
