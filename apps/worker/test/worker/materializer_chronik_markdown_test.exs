defmodule Worker.MaterializerChronikMarkdownTest do
  @moduledoc """
  Issue #385: `apply_kind("ChronikEntryChanged", ...)` schreibt 9-Tupel mit
  `markdown_body` als letztem Element. Backward-Compat: nil bei alten
  Events ohne das Feld. `Repo.list_chronik_entries/1` liefert das neue
  Feld im Map-Result.
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
    test "schreibt 9-Tupel mit markdown_body am Ende" do
      md = "# Akt 1\n\n**Romeo** trifft Julia."

      ev =
        event(
          "ChronikEntryChanged",
          chronik_payload("chr-md-1", markdown_body: md),
          1
        )

      assert {:applied, 1} = Materializer.apply_event(ev)

      row = dirty_row("chr-md-1")
      # Schema (9-Tupel): {table, id, campaign_id, in_game_date, label,
      #                    summary, session_id, source_refs, markdown_body}
      assert tuple_size(row) == 9
      assert elem(row, 8) == md
    end

    test "ohne markdown_body im Payload → nil im 9-Tupel (Backward-Compat)" do
      ev =
        event(
          "ChronikEntryChanged",
          chronik_payload("chr-bc-1", []),
          2
        )

      assert {:applied, 2} = Materializer.apply_event(ev)

      row = dirty_row("chr-bc-1")
      assert tuple_size(row) == 9
      assert elem(row, 8) == nil
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

    test "ChronikClearedForSession löscht 9-Tupel-Rows korrekt (elem(row, 6) arity-safe)" do
      # Drei Einträge: zwei für sid-x, einer für sid-y. Nur die für sid-x
      # sollen gelöscht werden — verifiziert dass elem(row, 6) auch im
      # 9-Tupel weiter session_id liefert.
      [
        event("ChronikEntryChanged", chronik_payload("c-x1", session_id: "sid-x", markdown_body: "x1"), 4),
        event("ChronikEntryChanged", chronik_payload("c-x2", session_id: "sid-x", markdown_body: "x2"), 5),
        event("ChronikEntryChanged", chronik_payload("c-y1", session_id: "sid-y", markdown_body: "y1"), 6)
      ]
      |> Enum.each(&Materializer.apply_event/1)

      assert dirty_row("c-x1")
      assert dirty_row("c-x2")
      assert dirty_row("c-y1")

      clear_ev =
        event(
          "ChronikClearedForSession",
          %{"campaign_id" => @cid, "session_id" => "sid-x"},
          7
        )

      assert {:applied, 7} = Materializer.apply_event(clear_ev)

      refute dirty_row("c-x1")
      refute dirty_row("c-x2")
      assert dirty_row("c-y1")
    end
  end
end
