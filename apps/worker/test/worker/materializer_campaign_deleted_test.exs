defmodule Worker.MaterializerCampaignDeletedTest do
  @moduledoc """
  Issue #15: `CampaignDeleted` cascade-löscht alle materialisierten
  Rows die zu der Kampagne gehören — campaign, members, invites,
  sessions, utterances, markers, epos_entries, epos_history,
  session_summaries, chronik_entries.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Materializer
  alias Worker.Schema.Builder
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-deleted-test"
  @other_cid "camp-other"
  @owner "owner-did"

  setup do
    clear_all_tables!()
    {:atomic, :ok} = :mnesia.clear_table(S.worker_state())

    mat_pid = ensure_materializer!()

    now = DateTime.utc_now()

    # Setup: 2 Campaigns mit identischer Sub-Struktur. Der Cascade darf
    # NUR die Ziel-Campaign treffen, die andere muss komplett unangetastet
    # bleiben (Sanity gegen broad index-write-Bugs).
    seed_campaign = fn cid ->
      sid = "sess-#{cid}"

      Builder.write_many!([
        Builder.campaign(cid, name: "Campaign #{cid}", created_at: now),
        Builder.campaign_member(cid, @owner, role: :spielleiter, joined_at: now),
        Builder.session(sid, cid,
          number: 1,
          name: "Session 1",
          status: :completed,
          started_at: now,
          ended_at: now
        ),
        Builder.utterance("utt-#{cid}", sid,
          discord_id: @owner,
          timestamp: now,
          text: "hello",
          confidence: 0.9,
          status: :confirmed
        ),
        Builder.marker("mark-#{cid}", sid, at_ts: now, kind: :plot, label: "marker")
      ])

      # Builder hält die Tabellen-Arities zentral (Issue #462) — kein
      # hartkodiertes Tupel mehr. write_many! raised bei Arity-Drift statt
      # — wie vor #459 — silent zu aborten und die Seed-Tx zurückzurollen.
      Builder.write_many!([
        Builder.campaign_invite("invite-#{cid}", cid, created_by_discord_id: @owner, created_at: now),
        Builder.epos_entry(cid, cid, content_md: "epos content", updated_at: now),
        Builder.epos_history("ehist-#{cid}", cid,
          content_md: "old epos",
          edited_at: now,
          edited_by: @owner
        ),
        Builder.session_summary(sid, cid, content_md: "summary", generated_at: now),
        Builder.chronik_entry("chr-#{cid}", cid, label: "Event", summary: "summary line", session_id: sid)
      ])
    end

    seed_campaign.(@cid)
    seed_campaign.(@other_cid)

    on_exit(fn ->
      if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill)
    end)

    :ok
  end

  defp count(table),
    do: :mnesia.dirty_match_object({table, :_, :_, :_, :_, :_, :_, :_, :_}) |> length()

  test "cascade-löscht alle 10 tables für die Ziel-Campaign" do
    # Sanity vorab: jede Campaign hat 1 Row in jeder ihrer Tabellen.
    assert :mnesia.dirty_read(S.campaigns(), @cid) != []
    assert :mnesia.dirty_index_read(S.sessions(), @cid, :campaign_id) != []

    ev = event("CampaignDeleted", %{"campaign_id" => @cid, "deleted_by" => @owner}, 1000)
    assert {:applied, 1000} = Materializer.apply_event(ev)

    # Ziel-Campaign weg.
    assert :mnesia.dirty_read(S.campaigns(), @cid) == []
    assert :mnesia.dirty_index_read(S.campaign_members(), @cid, :campaign_id) == []
    assert :mnesia.dirty_index_read(S.campaign_invites(), @cid, :campaign_id) == []
    assert :mnesia.dirty_index_read(S.sessions(), @cid, :campaign_id) == []
    assert :mnesia.dirty_index_read(S.utterances(), "sess-#{@cid}", :session_id) == []
    assert :mnesia.dirty_index_read(S.markers(), "sess-#{@cid}", :session_id) == []
    assert :mnesia.dirty_read(S.epos_entries(), @cid) == []
    assert :mnesia.dirty_index_read(S.epos_history(), @cid, :entry_id) == []
    assert :mnesia.dirty_index_read(S.session_summaries(), @cid, :campaign_id) == []
    assert :mnesia.dirty_index_read(S.chronik_entries(), @cid, :campaign_id) == []

    # Andere Campaign UNANGETASTET.
    assert :mnesia.dirty_read(S.campaigns(), @other_cid) != []
    assert :mnesia.dirty_index_read(S.sessions(), @other_cid, :campaign_id) != []
    assert :mnesia.dirty_index_read(S.utterances(), "sess-#{@other_cid}", :session_id) != []
    assert :mnesia.dirty_index_read(S.session_summaries(), @other_cid, :campaign_id) != []
  end

  test "unbekannte campaign_id wird ignoriert, keine Mutation" do
    rows_before = count(S.campaigns())

    ev = event("CampaignDeleted", %{"campaign_id" => "nope", "deleted_by" => @owner}, 1001)
    assert {:applied, 1001} = Materializer.apply_event(ev)

    assert count(S.campaigns()) == rows_before
  end
end
