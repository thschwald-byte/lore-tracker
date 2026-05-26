defmodule Worker.MaterializerChronikSessionIdTest do
  @moduledoc """
  Issue #227: ChronikEntryChanged speichert session_id in der Mnesia-Row,
  und ChronikClearedForSession bulk-löscht alle Chronik-Rows einer
  (campaign, session)-Paarung — damit Stage-4-Re-Runs nicht über alte
  Halluzinationen akkumulieren.
  """

  use ExUnit.Case, async: false

  alias Worker.Materializer
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-chron-227"
  @sid_a "sess-a"
  @sid_b "sess-b"

  setup do
    {:atomic, :ok} = :mnesia.clear_table(S.chronik_entries())
    {:atomic, :ok} = :mnesia.clear_table(S.worker_state())

    mat_pid =
      case Materializer.start_link([]) do
        {:ok, pid} -> pid
        {:error, {:already_started, _}} -> nil
      end

    on_exit(fn ->
      if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill)
    end)

    :ok
  end

  defp event(kind, payload, seq) do
    %{
      "seq" => seq,
      "ts" => DateTime.to_iso8601(DateTime.utc_now()),
      "author_worker_id" => "test",
      "payload" => Map.put(payload, "kind", kind)
    }
  end

  defp chronik_row(id, sid) do
    %{
      "id" => id,
      "campaign_id" => @cid,
      "in_game_date" => "Tag 1",
      "label" => "L-#{id}",
      "summary" => "S-#{id}",
      "session_id" => sid
    }
  end

  defp dirty_row(id), do: :mnesia.dirty_read(S.chronik_entries(), id) |> List.first()

  test "ChronikEntryChanged schreibt session_id in die Mnesia-Row" do
    ev = event("ChronikEntryChanged", chronik_row("chr-1", @sid_a), 1)
    assert {:applied, 1} = Materializer.apply_event(ev)

    row = dirty_row("chr-1")
    # Schema: {table, id, campaign_id, in_game_date, label, summary, session_id}
    assert elem(row, 6) == @sid_a
  end

  test "ChronikClearedForSession löscht nur Rows der angegebenen session_id" do
    [
      event("ChronikEntryChanged", chronik_row("chr-a1", @sid_a), 1),
      event("ChronikEntryChanged", chronik_row("chr-a2", @sid_a), 2),
      event("ChronikEntryChanged", chronik_row("chr-b1", @sid_b), 3)
    ]
    |> Enum.each(&Materializer.apply_event/1)

    assert dirty_row("chr-a1")
    assert dirty_row("chr-a2")
    assert dirty_row("chr-b1")

    clear =
      event(
        "ChronikClearedForSession",
        %{"campaign_id" => @cid, "session_id" => @sid_a, "cleared_by" => "llm"},
        4
      )

    assert {:applied, 4} = Materializer.apply_event(clear)

    refute dirty_row("chr-a1")
    refute dirty_row("chr-a2")
    assert dirty_row("chr-b1"), "Session-B-Row darf nicht angefasst werden"
  end

  test "ChronikClearedForSession ist idempotent (Replay-safe)" do
    Materializer.apply_event(
      event("ChronikEntryChanged", chronik_row("chr-x", @sid_a), 1)
    )

    clear =
      event(
        "ChronikClearedForSession",
        %{"campaign_id" => @cid, "session_id" => @sid_a, "cleared_by" => "llm"},
        2
      )

    assert {:applied, 2} = Materializer.apply_event(clear)
    refute dirty_row("chr-x")

    # Zweites Apply darf nicht crashen, auch wenn nichts mehr zu löschen ist.
    clear2 =
      event(
        "ChronikClearedForSession",
        %{"campaign_id" => @cid, "session_id" => @sid_a, "cleared_by" => "llm"},
        3
      )

    assert {:applied, 3} = Materializer.apply_event(clear2)
  end

  test "ChronikClearedForSession ignoriert andere Campaigns" do
    other_cid = "other-camp"

    Materializer.apply_event(
      event(
        "ChronikEntryChanged",
        %{chronik_row("chr-own", @sid_a) | "campaign_id" => other_cid},
        1
      )
    )

    Materializer.apply_event(
      event("ChronikEntryChanged", chronik_row("chr-target", @sid_a), 2)
    )

    clear =
      event(
        "ChronikClearedForSession",
        %{"campaign_id" => @cid, "session_id" => @sid_a, "cleared_by" => "llm"},
        3
      )

    assert {:applied, 3} = Materializer.apply_event(clear)

    refute dirty_row("chr-target")
    assert dirty_row("chr-own"), "Andere Campaign darf nicht betroffen sein"
  end
end
