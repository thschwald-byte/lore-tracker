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

      :mnesia.transaction(fn ->
        :mnesia.write({S.campaign_invites(), "invite-#{cid}", cid, @owner, now, nil, :active, nil})
        :mnesia.write({S.epos_entries(), cid, cid, nil, "epos content", now})

        :mnesia.write(
          {S.epos_history(), "ehist-#{cid}", cid, "old epos", now, @owner, :manual, 1}
        )

        :mnesia.write({S.session_summaries(), sid, cid, "summary", now, :llm})

        :mnesia.write(
          {S.chronik_entries(), "chr-#{cid}", cid, "Tag 1", "Event", "summary line", sid}
        )
      end)
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
