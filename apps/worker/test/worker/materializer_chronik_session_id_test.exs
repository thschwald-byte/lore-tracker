defmodule Worker.MaterializerChronikSessionIdTest do
  @moduledoc """
  Issue #227 / #698: ChronikEntryChanged speichert session_id (+ event_id) in
  der Row. ChronikClearedForSession räumt einen Re-Run NICHT mehr physisch weg
  (das war die #698-Resurrection-Quelle), sondern hebt einen Clear-Watermark
  pro Session — `list_chronik_entries` filtert Rows mit event_id <= clear_key
  raus. Session- und Campaign-Scoping bleiben erhalten.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Materializer
  alias Worker.Repo
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-chron-227"
  @sid_a "sess-a"
  @sid_b "sess-b"

  setup do
    clear_all_tables!()

    for t <- [
          S.chronik_entries(),
          S.chronik_clear_marks(),
          S.applied_event_ids(),
          S.worker_state()
        ] do
      :mnesia.clear_table(t)
    end

    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
    :ok
  end

  defp entry(id, sid, event_id, cid \\ @cid) do
    payload = %{
      "id" => id,
      "campaign_id" => cid,
      "in_game_date" => "Tag 1",
      "label" => "L-#{id}",
      "summary" => "S-#{id}",
      "session_id" => sid
    }

    event("ChronikEntryChanged", payload, next_seq(), event_id: event_id)
  end

  defp clear(sid, event_id, cid \\ @cid) do
    event(
      "ChronikClearedForSession",
      %{"campaign_id" => cid, "session_id" => sid, "cleared_by" => "llm"},
      next_seq(),
      event_id: event_id
    )
  end

  defp next_seq, do: System.unique_integer([:positive, :monotonic])

  defp chronik_ids(cid \\ @cid) do
    Repo.list_chronik_entries(cid) |> Enum.map(& &1.id) |> Enum.sort()
  end

  defp dirty_row(id), do: :mnesia.dirty_read(S.chronik_entries(), id) |> List.first()

  test "ChronikEntryChanged schreibt session_id + event_id in die Mnesia-Row" do
    Materializer.apply_event(entry("chr-1", @sid_a, "e01"))

    row = dirty_row("chr-1")
    # Schema: {tbl, id, campaign_id, in_game_date, label, summary, session_id,
    #          source_refs, markdown_body, in_game_day, precision, event_id}
    assert elem(row, 6) == @sid_a
    assert elem(row, 11) == "e01"
  end

  test "Clear-Watermark unterdrückt (am Read) nur die angegebene session_id" do
    [
      entry("chr-a1", @sid_a, "e01"),
      entry("chr-a2", @sid_a, "e02"),
      entry("chr-b1", @sid_b, "e03")
    ]
    |> Enum.each(&Materializer.apply_event/1)

    assert chronik_ids() == ["chr-a1", "chr-a2", "chr-b1"]

    Materializer.apply_event(clear(@sid_a, "e04"))

    # Session A durch den Watermark (e04 > e01/e02) unterdrückt; Session B
    # (kein Mark) unberührt.
    assert chronik_ids() == ["chr-b1"]
  end

  test "Clear ist idempotent + monoton (Re-Apply senkt den Watermark nicht)" do
    Materializer.apply_event(entry("chr-x", @sid_a, "e01"))
    Materializer.apply_event(clear(@sid_a, "e05"))
    assert chronik_ids() == []

    # Zweiter Clear mit NIEDRIGEREM event_id darf den Watermark nicht senken
    # (max-Semantik) und nicht crashen.
    Materializer.apply_event(clear(@sid_a, "e03"))
    assert chronik_ids() == []

    # Ein neuer Entry ÜBER dem Watermark (e06 > e05) ist wieder live.
    Materializer.apply_event(entry("chr-new", @sid_a, "e06"))
    assert chronik_ids() == ["chr-new"]
  end

  test "Clear betrifft nur die eigene Campaign" do
    other_cid = "other-camp"

    # Andere Campaign, andere (global eindeutige) session_id.
    Materializer.apply_event(entry("chr-own", "sess-own", "e01", other_cid))
    Materializer.apply_event(entry("chr-target", @sid_a, "e02"))
    Materializer.apply_event(clear(@sid_a, "e03"))

    assert chronik_ids() == [], "eigene Campaign: Target durch Watermark unterdrückt"
    assert chronik_ids(other_cid) == ["chr-own"], "andere Campaign darf unberührt bleiben"
  end
end
