defmodule Worker.MaterializerSourceRefsTest do
  @moduledoc """
  Issue #114: source_refs trailing in den 3 LLM-Output-Tabellen.
  - SessionSummaryGenerated → worker_session_summaries (7-Tupel)
  - EposEntryEdited → worker_epos_entries (7-Tupel)
  - ChronikEntryChanged → worker_chronik_entries (8-Tupel)

  Backward-kompat: fehlender Payload-Key → []. SessionSummaryEdited (manual
  Edit) behält die alten refs.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper, only: [event: 3, ensure_materializer!: 0]

  alias Worker.Materializer
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-114-srefs"
  @sid "sess-114"
  @did "user-114"

  setup do
    Enum.each(
      [
        S.session_summaries(),
        S.epos_entries(),
        S.chronik_entries(),
        S.worker_state()
      ],
      fn t -> {:atomic, :ok} = :mnesia.clear_table(t) end
    )

    mat_pid = ensure_materializer!()

    on_exit(fn ->
      if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill)
    end)

    :ok
  end

  describe "SessionSummaryGenerated" do
    test "schreibt source_refs als trailing-Feld" do
      ev =
        event(
          "SessionSummaryGenerated",
          %{
            "session_id" => @sid,
            "campaign_id" => @cid,
            "content_md" => "Romeo trifft Julia.",
            "source" => "llm",
            "source_refs" => ["utt-1", "utt-2"]
          },
          1
        )

      assert {:applied, 1} = Materializer.apply_event(ev)

      [row] = :mnesia.dirty_read(S.session_summaries(), @sid)
      # Schema: {table, sid, cid, content, ts, source, source_refs, flagged_claims}
      assert elem(row, 6) == ["utt-1", "utt-2"]
    end

    test "fehlender source_refs-Key → []" do
      ev =
        event(
          "SessionSummaryGenerated",
          %{
            "session_id" => @sid,
            "campaign_id" => @cid,
            "content_md" => "Pre-#114 Event ohne refs.",
            "source" => "llm"
          },
          1
        )

      assert {:applied, 1} = Materializer.apply_event(ev)

      [row] = :mnesia.dirty_read(S.session_summaries(), @sid)
      assert elem(row, 6) == []
    end

    test "SessionSummaryEdited behält die existierenden refs" do
      Materializer.apply_event(
        event(
          "SessionSummaryGenerated",
          %{
            "session_id" => @sid,
            "campaign_id" => @cid,
            "content_md" => "LLM-Output",
            "source" => "llm",
            "source_refs" => ["utt-A"]
          },
          1
        )
      )

      Materializer.apply_event(
        event(
          "SessionSummaryEdited",
          %{"session_id" => @sid, "new_md" => "Manuelle Korrektur", "edited_by" => @did},
          2
        )
      )

      [row] = :mnesia.dirty_read(S.session_summaries(), @sid)
      assert elem(row, 3) == "Manuelle Korrektur"
      # source bleibt :manual
      assert elem(row, 5) == :manual
      # source_refs werden NICHT durch den manuellen Edit überschrieben.
      assert elem(row, 6) == ["utt-A"]
    end
  end

  describe "SessionSummaryGenerated flagged_claims (Issue #715)" do
    test "schreibt flagged_claims als 8. Feld" do
      ev =
        event(
          "SessionSummaryGenerated",
          %{
            "session_id" => @sid,
            "campaign_id" => @cid,
            "content_md" => "Recap mit zwei ungegroundeten Sätzen.",
            "source" => "llm",
            "source_refs" => ["utt-1"],
            "flagged_claims" => ["Ungegroundeter Satz A.", "Ungegroundeter Satz B."]
          },
          1
        )

      assert {:applied, 1} = Materializer.apply_event(ev)

      [row] = :mnesia.dirty_read(S.session_summaries(), @sid)
      assert elem(row, 7) == ["Ungegroundeter Satz A.", "Ungegroundeter Satz B."]
    end

    test "fehlender flagged_claims-Key → [] (backward-kompat: Chain-Pfad, alte Events)" do
      ev =
        event(
          "SessionSummaryGenerated",
          %{
            "session_id" => @sid,
            "campaign_id" => @cid,
            "content_md" => "Chain-Pfad-Resümee ohne Render-Gate.",
            "source" => "llm",
            "source_refs" => ["utt-1"]
          },
          1
        )

      assert {:applied, 1} = Materializer.apply_event(ev)

      [row] = :mnesia.dirty_read(S.session_summaries(), @sid)
      assert elem(row, 7) == []
    end

    test "SessionSummaryEdited löscht flagged_claims (der Text passt danach nicht mehr)" do
      Materializer.apply_event(
        event(
          "SessionSummaryGenerated",
          %{
            "session_id" => @sid,
            "campaign_id" => @cid,
            "content_md" => "Original mit geflaggtem Satz.",
            "source" => "llm",
            "source_refs" => ["utt-1"],
            "flagged_claims" => ["Original mit geflaggtem Satz."]
          },
          1
        )
      )

      Materializer.apply_event(
        event(
          "SessionSummaryEdited",
          %{"session_id" => @sid, "new_md" => "GM-Korrektur.", "edited_by" => @did},
          2
        )
      )

      [row] = :mnesia.dirty_read(S.session_summaries(), @sid)
      assert elem(row, 3) == "GM-Korrektur."
      assert elem(row, 7) == []
    end
  end

  describe "SessionSummaryGenerated render_backend/render_model Provenance (#783 Phase 2, Design E)" do
    test "schreibt render_backend/render_model als 9./10. Feld" do
      ev =
        event(
          "SessionSummaryGenerated",
          %{
            "session_id" => @sid,
            "campaign_id" => @cid,
            "content_md" => "Romeo trifft Julia.",
            "source" => "llm",
            "source_refs" => ["utt-1"],
            "render_backend" => "openai",
            "render_model" => "gpt-4o-mini"
          },
          1
        )

      assert {:applied, 1} = Materializer.apply_event(ev)

      [row] = :mnesia.dirty_read(S.session_summaries(), @sid)
      assert elem(row, 8) == "openai"
      assert elem(row, 9) == "gpt-4o-mini"
    end

    test "fehlende render_backend/render_model-Keys → nil (Pre-#783-Events)" do
      ev =
        event(
          "SessionSummaryGenerated",
          %{
            "session_id" => @sid,
            "campaign_id" => @cid,
            "content_md" => "Pre-#783 Event ohne Provenance.",
            "source" => "llm"
          },
          1
        )

      assert {:applied, 1} = Materializer.apply_event(ev)

      [row] = :mnesia.dirty_read(S.session_summaries(), @sid)
      assert elem(row, 8) == nil
      assert elem(row, 9) == nil
    end

    test "SessionSummaryEdited behält render_backend/render_model (analog source_refs)" do
      Materializer.apply_event(
        event(
          "SessionSummaryGenerated",
          %{
            "session_id" => @sid,
            "campaign_id" => @cid,
            "content_md" => "LLM-Output",
            "source" => "llm",
            "source_refs" => ["utt-A"],
            "render_backend" => "google",
            "render_model" => "gemini-2.5-flash"
          },
          1
        )
      )

      Materializer.apply_event(
        event(
          "SessionSummaryEdited",
          %{"session_id" => @sid, "new_md" => "Manuelle Korrektur", "edited_by" => @did},
          2
        )
      )

      [row] = :mnesia.dirty_read(S.session_summaries(), @sid)
      assert elem(row, 8) == "google"
      assert elem(row, 9) == "gemini-2.5-flash"
    end
  end

  describe "EposEntryEdited" do
    test "schreibt source_refs als trailing-Feld" do
      ev =
        event(
          "EposEntryEdited",
          %{
            "entry_id" => @cid,
            "campaign_id" => @cid,
            "new_md" => "# Epos\n...",
            "edited_by" => "llm",
            "source" => "llm",
            "source_refs" => ["utt-1", "utt-3"]
          },
          1
        )

      assert {:applied, 1} = Materializer.apply_event(ev)

      [row] = :mnesia.dirty_read(S.epos_entries(), @cid)
      # Schema: {table, id, cid, parent, content, ts, source_refs}
      assert elem(row, 6) == ["utt-1", "utt-3"]
    end

    test "manueller Edit ohne source_refs behält die alten refs" do
      # Erst LLM-Edit mit refs
      Materializer.apply_event(
        event(
          "EposEntryEdited",
          %{
            "entry_id" => @cid,
            "campaign_id" => @cid,
            "new_md" => "v1",
            "edited_by" => "llm",
            "source" => "llm",
            "source_refs" => ["utt-X"]
          },
          1
        )
      )

      # Dann manueller Edit (ohne source_refs im payload)
      Materializer.apply_event(
        event(
          "EposEntryEdited",
          %{
            "entry_id" => @cid,
            "campaign_id" => @cid,
            "new_md" => "v2 manuell",
            "edited_by" => @did,
            "source" => "manual"
          },
          2
        )
      )

      [row] = :mnesia.dirty_read(S.epos_entries(), @cid)
      assert elem(row, 4) == "v2 manuell"
      assert elem(row, 6) == ["utt-X"]
    end
  end

  describe "ChronikEntryChanged" do
    test "schreibt source_refs als trailing-Feld" do
      ev =
        event(
          "ChronikEntryChanged",
          %{
            "id" => "chr-1",
            "campaign_id" => @cid,
            "in_game_date" => "Tag 1",
            "label" => "Begegnung",
            "summary" => "Romeo trifft Julia.",
            "session_id" => @sid,
            "source_refs" => ["utt-1", "utt-2"]
          },
          1
        )

      assert {:applied, 1} = Materializer.apply_event(ev)

      [row] = :mnesia.dirty_read(S.chronik_entries(), "chr-1")
      # Schema: {table, id, cid, in_game_date, label, summary, sid, source_refs}
      assert elem(row, 7) == ["utt-1", "utt-2"]
    end

    test "fehlender source_refs-Key → []" do
      ev =
        event(
          "ChronikEntryChanged",
          %{
            "id" => "chr-2",
            "campaign_id" => @cid,
            "in_game_date" => "Tag 2",
            "label" => "Pre-#114",
            "summary" => "Alter Event ohne refs.",
            "session_id" => @sid
          },
          1
        )

      assert {:applied, 1} = Materializer.apply_event(ev)

      [row] = :mnesia.dirty_read(S.chronik_entries(), "chr-2")
      assert elem(row, 7) == []
    end
  end
end
