defmodule Worker.RepoTombstoneFilterTest do
  @moduledoc """
  Etappe 3d (Issue #133): Tombstone-Read-Filter in Worker.Repo.
  MemberRemoved + UtteranceDeleted setzen deleted_at; list_members,
  list_utterances, list_campaign_ids_for + member? müssen das respektieren.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Repo
  alias Worker.Schema.Builder

  @cid "cid-tombstone-test"
  @did_active "did-active"
  @did_removed "did-removed"
  @sid "sess-tombstone-test"
  @utt_active "utt-active"
  @utt_deleted "utt-deleted"

  setup do
    clear_all_tables!()

    now = DateTime.utc_now()
    tombstone_ts = DateTime.utc_now()

    Builder.write_many!([
      Builder.campaign_member(@cid, @did_active, role: :player, joined_at: now),
      Builder.campaign_member(@cid, @did_removed,
        role: :player,
        joined_at: now,
        deleted_at: tombstone_ts
      ),
      Builder.utterance(@utt_active, @sid,
        discord_id: @did_active,
        timestamp: now,
        text: "active text",
        confidence: 0.9
      ),
      Builder.utterance(@utt_deleted, @sid,
        discord_id: @did_active,
        timestamp: now,
        text: "deleted text",
        confidence: 0.9,
        deleted_at: tombstone_ts
      )
    ])

    :ok
  end

  test "list_members/1 filtert tombstone'd Members aus" do
    members = Repo.list_members(@cid)
    assert length(members) == 1
    assert hd(members).discord_id == @did_active
  end

  test "member?/2 returnt false für tombstone'd Members" do
    assert Repo.member?(@cid, @did_active) == true
    assert Repo.member?(@cid, @did_removed) == false
  end

  test "list_campaign_ids_for/1 ignoriert tombstone'd Memberships" do
    assert @cid in Repo.list_campaign_ids_for(@did_active)
    refute @cid in Repo.list_campaign_ids_for(@did_removed)
  end

  test "list_utterances/2 filtert tombstone'd Utterances aus" do
    utts = Repo.list_utterances(@sid)
    assert length(utts) == 1
    assert hd(utts).id == @utt_active
  end
end
