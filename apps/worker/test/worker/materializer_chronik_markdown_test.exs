defmodule Worker.MaterializerChronikMarkdownTest do
  @moduledoc """
  Issue #385: `apply_kind("ChronikEntryChanged", ...)` schreibt `markdown_body`.
  Seit #698 ist die Row ein 12-Tupel (in_game_day/precision/generation trailing);
  markdown_body bleibt Index 8. Backward-Compat: nil bei alten Events ohne die
  Felder. `Repo.list_chronik_entries/1` liefert die Felder im Map-Result.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.{Materializer, Repo}
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-chron-385"

  setup do
    clear_all_tables!()
    {:atomic, :ok} = :mnesia.clear_table(S.worker_state())
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
    :ok
  end

  defp dirty_row(id), do: :mnesia.dirty_read(S.chronik_entries(), id) |> List.first()

  defp chronik_ids, do: Repo.list_chronik_entries(@cid) |> Enum.map(& &1.id) |> Enum.sort()

  defp chronik_payload(id, opts) do
    base = %{
      "id" => id,
      "campaign_id" => @cid,
      "in_game_date" => Keyword.get(opts, :date, "Tag 1"),
      "label" => Keyword.get(opts, :label, "L-#{id}"),
      "summary" => Keyword.get(opts, :summary, "S-#{id}"),
      "session_id" => Keyword.get(opts, :session_id, nil),
      "source_refs" => Keyword.get(opts, :source_refs, [])
    }

    case Keyword.get(opts, :markdown_body, :unset) do
      :unset -> base
      val -> Map.put(base, "markdown_body", val)
    end
  end

  describe "ChronikEntryChanged mit markdown_body (neu, Issue #385)" do
    test "schreibt markdown_body an Index 8 (12-Tupel seit #698)" do
      md = "# Akt 1\n\n**Romeo** trifft Julia."

      ev =
        event(
          "ChronikEntryChanged",
          chronik_payload("chr-md-1", markdown_body: md),
          1
        )

      assert {:applied, 1} = Materializer.apply_event(ev)

      row = dirty_row("chr-md-1")
      # Schema (12-Tupel seit #698): {table, id, campaign_id, in_game_date, label,
      #   summary, session_id, source_refs, markdown_body, in_game_day, precision,
      #   generation}. markdown_body bleibt Index 8 (neue Felder trailing).
      assert tuple_size(row) == 12
      assert elem(row, 8) == md
    end

    test "ohne markdown_body im Payload → nil im 12-Tupel (Backward-Compat)" do
      ev =
        event(
          "ChronikEntryChanged",
          chronik_payload("chr-bc-1", []),
          2
        )

      assert {:applied, 2} = Materializer.apply_event(ev)

      row = dirty_row("chr-bc-1")
      assert tuple_size(row) == 12
      assert elem(row, 8) == nil
      # Issue #724: neue Trailing-Felder in_game_day/precision → nil bei Events
      # ohne diese Keys (BC).
      assert elem(row, 9) == nil
      assert elem(row, 10) == nil
    end

    test "Repo.list_chronik_entries liefert markdown_body als Atom-Key" do
      md = "# Hallo\n\n- Listenpunkt"

      ev =
        event(
          "ChronikEntryChanged",
          chronik_payload("chr-repo-1", markdown_body: md),
          3
        )

      assert {:applied, 3} = Materializer.apply_event(ev)

      [entry] = Repo.list_chronik_entries(@cid)
      assert Map.has_key?(entry, :markdown_body)
      assert entry.markdown_body == md
      # Restliche Felder bleiben sauber durchgereicht
      assert entry.in_game_date == "Tag 1"
      assert entry.summary == "S-chr-repo-1"
    end

    test "ChronikClearedForSession unterdrückt via Watermark nur die eigene Session (Read)" do
      # Issue #698: der Clear löscht nicht mehr physisch, sondern hebt den
      # Watermark der Session — `list_chronik_entries` filtert Rows mit
      # generation < clear raus. Zwei sid-x (e01/e02) + ein sid-y (e03); Clear
      # sid-x (e04) unterdrückt sid-x, sid-y (kein Mark) bleibt.
      [
        event("ChronikEntryChanged", chronik_payload("c-x1", session_id: "sid-x"), 4,
          event_id: "e01"
        ),
        event("ChronikEntryChanged", chronik_payload("c-x2", session_id: "sid-x"), 5,
          event_id: "e02"
        ),
        event("ChronikEntryChanged", chronik_payload("c-y1", session_id: "sid-y"), 6,
          event_id: "e03"
        )
      ]
      |> Enum.each(&Materializer.apply_event/1)

      assert chronik_ids() == ["c-x1", "c-x2", "c-y1"]

      clear_ev =
        event("ChronikClearedForSession", %{"campaign_id" => @cid, "session_id" => "sid-x"}, 7,
          event_id: "e04"
        )

      assert {:applied, 7} = Materializer.apply_event(clear_ev)

      assert chronik_ids() == ["c-y1"]
    end
  end
end
