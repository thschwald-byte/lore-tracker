defmodule Worker.ChronikCrossSessionTest do
  @moduledoc """
  Issue #650: Chronik über mehrere Sessions — Einträge verschiedener Sessions
  mit gleichem (date,label) dürfen sich nicht überschreiben (session-scoped
  IDs), und `list_chronik_entries` sortiert primär nach session.number.
  (#786: der frühere Chain-Producer `Stages.derive_chronik_id/2` ist entfernt —
  die Timeline-IDs kommen aus `derive_timeline_id` in pipeline.ex; hier zählt
  das RETENTION-Verhalten des Readers/Materializers für historische Rows.)
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.{Materializer, Repo}
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-chron-650"
  @s1 "sess-650-1"
  @s2 "sess-650-2"

  setup do
    clear_all_tables!()
    {:atomic, :ok} = :mnesia.clear_table(S.worker_state())
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
    :ok
  end

  describe "list_chronik_entries/1 — Cross-Session" do
    setup do
      # Zwei Sessions, S1 number=1, S2 number=2.
      [
        event(
          "SessionScheduled",
          %{"campaign_id" => @cid, "id" => @s1, "number" => 1, "name" => ""},
          1
        ),
        event(
          "SessionScheduled",
          %{"campaign_id" => @cid, "id" => @s2, "number" => 2, "name" => ""},
          2
        )
      ]
      |> Enum.each(&Materializer.apply_event/1)

      :ok
    end

    defp write_entry(session_id, date, label, seq) do
      payload = %{
        "id" =>
          ("chronik-" <>
             Base.encode16(:crypto.hash(:sha, "#{session_id}|#{date}|#{label}"), case: :lower))
          |> binary_part(0, 20),
        "campaign_id" => @cid,
        "in_game_date" => date,
        "label" => label,
        "summary" => "#{label} (#{session_id})",
        "session_id" => session_id
      }

      Materializer.apply_event(event("ChronikEntryChanged", payload, seq))
    end

    test "identischer (date,label) in beiden Sessions: BEIDE überleben (kein Overwrite)" do
      write_entry(@s1, "Tag 1", "Showdown", 10)
      write_entry(@s2, "Tag 1", "Showdown", 11)

      entries = Repo.list_chronik_entries(@cid)
      assert length(entries) == 2
      assert Enum.map(entries, & &1.session_id) |> Enum.sort() == [@s1, @s2]
    end

    test "Reihenfolge: nach session.number, dann in_game_date — kein Cross-Session-Scramble" do
      # S2 hat das frühere in_game_date (Tag 1), S1 das spätere (Tag 9).
      # Pure-Datum-Sortierung würde S2 vor S1 ziehen — Session-primär nicht.
      write_entry(@s1, "Tag 9", "Spät-in-S1", 10)
      write_entry(@s2, "Tag 1", "Früh-in-S2", 11)

      order = Repo.list_chronik_entries(@cid) |> Enum.map(& &1.session_id)
      assert order == [@s1, @s2]
    end

    test "innerhalb einer Session nach in_game_date sortiert" do
      write_entry(@s1, "Tag 9", "B", 10)
      write_entry(@s1, "Tag 2", "A", 11)

      labels = Repo.list_chronik_entries(@cid) |> Enum.map(& &1.label)
      assert labels == ["A", "B"]
    end
  end
end
