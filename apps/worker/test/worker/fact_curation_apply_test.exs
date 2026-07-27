defmodule Worker.FactCurationApplyTest do
  @moduledoc """
  Issue #916 (Epic #911, Cut 2): der FactCurationSet-Schreibpfad. Gepinnt:
  (1) je EIN Feld = eine eigene Row (unabhängige LWW-Slots — ein character-Edit
  clobbert einen claim-Edit NICHT); (2) LWW-by-event_id konvergiert reihenfolge-
  unabhängig; (3) Undo = leere-value-Row (nie Delete); (4) bad field gedroppt;
  (5) `quell` kanonisch-sortiert gespeichert.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Materializer
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-factcur-916"
  @sid "sess-1"
  @anchor "abc123"

  setup do
    clear_all_tables!()
    {:atomic, :ok} = :mnesia.clear_table(S.worker_state())
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
    :ok
  end

  defp ev(eid, seq, field, value, opts \\ []) do
    event(
      "FactCurationSet",
      %{
        "session_id" => @sid,
        "campaign_id" => @cid,
        "anchor_hash" => Keyword.get(opts, :anchor, @anchor),
        "quell_utterance_ids" => Keyword.get(opts, :quell, ["u3", "u1", "u2"]),
        "field" => field,
        "value" => value,
        "set_by" => "did-k"
      },
      seq,
      event_id: eid
    )
  end

  defp row(field, anchor \\ @anchor) do
    case :mnesia.dirty_read(S.fact_overrides(), "#{@sid}:#{anchor}:#{field}") do
      [{_t, _k, sid, cid, ah, quell, f, v, sb, e}] ->
        %{
          sid: sid,
          cid: cid,
          anchor: ah,
          quell: quell,
          field: f,
          value: v,
          set_by: sb,
          event_id: e
        }

      [] ->
        nil
    end
  end

  defp apply_all(evs), do: Enum.each(evs, &Materializer.apply_event/1)

  defp permutations([]), do: [[]]
  defp permutations(list), do: for(x <- list, rest <- permutations(list -- [x]), do: [x | rest])

  test "je Feld eine eigene Row; character-Edit clobbert claim-Edit nicht" do
    apply_all([ev("e1", 1, "claim", "Neuer Claim"), ev("e2", 2, "character", "Holmes")])

    assert row("claim").value == "Neuer Claim"
    assert row("character").value == "Holmes"
    # zwei distinkte Rows.
    assert row("claim").field == "claim"
    assert row("character").field == "character"
  end

  test "quell wird kanonisch-sortiert gespeichert" do
    apply_all([ev("e1", 1, "thread", "der brief", quell: ["u9", "u2", "u5"])])
    assert row("thread").quell == ["u2", "u5", "u9"]
  end

  test "LWW konvergiert reihenfolge-unabhängig (höhere event_id gewinnt)" do
    evs = [ev("e1", 1, "claim", "alt"), ev("e2", 2, "claim", "neu")]

    for order <- permutations(evs) do
      clear_all_tables!()
      apply_all(order)
      assert row("claim").value == "neu", inspect(order)
    end
  end

  test "Undo = leere-value-Row, nie Delete" do
    apply_all([ev("e1", 1, "claim", "etwas"), ev("e2", 2, "claim", "")])
    r = row("claim")
    assert r != nil, "Undo schreibt eine Row, kein Delete"
    assert r.value == ""
  end

  test "Doppel-Zustellung idempotent" do
    apply_all([ev("e1", 1, "verified", "false"), ev("e1", 1, "verified", "false")])
    assert row("verified").value == "false"
  end

  test "unbekanntes Feld wird gedroppt" do
    apply_all([ev("e1", 1, "bogus", "x")])
    assert row("bogus") == nil
  end

  test "dismissed-Feld schreibt eine eigene Row" do
    apply_all([ev("e1", 1, "dismissed", "true")])
    assert row("dismissed").value == "true"
  end
end
