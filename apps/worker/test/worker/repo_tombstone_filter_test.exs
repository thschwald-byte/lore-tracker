defmodule Worker.RepoTombstoneFilterTest do
  @moduledoc """
  Etappe 3d (Issue #133): Tombstone-Read-Filter in Worker.Repo.
  MemberRemoved + UtteranceDeleted setzen deleted_at; list_members,
  list_utterances, list_campaign_ids_for + member? müssen das respektieren.
  """

  use ExUnit.Case, async: false

  alias Worker.Repo
  alias Worker.Schema.Mnesia, as: S

  @cid "cid-tombstone-test"
  @did_active "did-active"
  @did_removed "did-removed"
  @sid "sess-tombstone-test"
  @utt_active "utt-active"
  @utt_deleted "utt-deleted"

  setup do
    Enum.each(
      [S.campaign_members(), S.utterances()],
      fn t -> {:atomic, :ok} = :mnesia.clear_table(t) end
    )

    now = DateTime.utc_now()
    tombstone_ts = DateTime.utc_now()

    {:atomic, :ok} =
      :mnesia.transaction(fn ->
        # Active member (deleted_at = nil)
        :mnesia.write({
          S.campaign_members(),
          S.member_key(@cid, @did_active),
          @cid,
          @did_active,
          :player,
          now,
          nil,
          nil
        })

        # Removed member (deleted_at gesetzt)
        :mnesia.write({
          S.campaign_members(),
          S.member_key(@cid, @did_removed),
          @cid,
          @did_removed,
          :player,
          now,
          nil,
          tombstone_ts
        })

        # Active utterance
        :mnesia.write({
          S.utterances(),
          @utt_active,
          @sid,
          @did_active,
          now,
          "active text",
          0.9,
          :confirmed,
          nil
        })

        # Deleted utterance (tombstone)
        :mnesia.write({
          S.utterances(),
          @utt_deleted,
          @sid,
          @did_active,
          now,
          "deleted text",
          0.9,
          :confirmed,
          tombstone_ts
        })
      end)

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
