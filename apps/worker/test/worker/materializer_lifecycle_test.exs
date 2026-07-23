defmodule Worker.MaterializerLifecycleTest do
  @moduledoc """
  Issue #66 (Coverage-Followup): Apply-Coverage für die Lifecycle-Event-Kinds,
  die bislang kein dediziertes `materializer_*_test` hatten — Invites
  (Created/Redeemed/Revoked), MarkerAdded, MemberRemoved (Tombstone),
  SessionEnded, RecordingStateChanged, SessionDeleted, CampaignUpdated,
  SessionFaithfulnessScored.

  Aufbau: eine Basis-Kampagne via `build_campaign(apply: true)`, dann pro Test
  ein Lifecycle-Event mit eigenem `event_id` drüber-applied (siehe `apply!/3`
  zum event_id- statt seq-Cursor-Pfad) und das Ergebnis über die
  `Worker.Repo`-Read-API verifiziert.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Materializer
  alias Worker.Repo

  @cid "mat-lc-camp"
  @owner "did-owner-lc"
  @member "did-member-lc"
  @sid "mat-lc-camp-s1"

  setup do
    clear_all_tables!()
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)

    build_campaign(
      campaign_id: @cid,
      owner_did: @owner,
      members: [@member],
      sessions: [3],
      apply: true
    )

    :ok
  end

  # event_id setzen → Apply läuft über den event_id-Pfad (line 135), der
  # unabhängig vom seq-Cursor materialisiert. `clear_all_tables!` resettet
  # `last_applied_seq` nicht, daher würde ein reiner seq-Pfad ab dem zweiten
  # Test am geleakten Cursor skippen.
  #
  # Issue #896: das Lifecycle-Event passiert KAUSAL nach dem `build_campaign`-Seed
  # (dessen event_ids `"#{@cid}-ev-<seq>"` sind) — bei den neuen Existenz-LWW-Folds
  # (`:membership` etc.) muss die event_id daher lexikografisch DAHINTER sortieren
  # (`"…-zz-…"` > `"…-ev-…"`), so wie in Prod die spätere UUIDv7 höher ist.
  defp apply!(kind, payload, seq) do
    ev = event(kind, payload, seq, event_id: "#{@cid}-zz-#{seq}-#{kind}")
    assert {:applied, _} = Materializer.apply_event(ev)
  end

  describe "CampaignUpdated" do
    test "überschreibt name + theme_blurb, behält created_at" do
      before = Repo.get_campaign(@cid)

      apply!(
        "CampaignUpdated",
        %{"id" => @cid, "name" => "Neuer Name", "theme_blurb" => "Düster"},
        100
      )

      camp = Repo.get_campaign(@cid)
      assert camp.name == "Neuer Name"
      assert camp.theme_blurb == "Düster"
      assert camp.created_at == before.created_at
    end
  end

  describe "Invites" do
    test "InviteCreated → aktiver Invite, abrufbar über get_invite/list_invites" do
      apply!(
        "InviteCreated",
        %{
          "token" => "tok-1",
          "campaign_id" => @cid,
          "created_by_discord_id" => @owner,
          "expires_at" => "2099-01-01T00:00:00Z"
        },
        100
      )

      inv = Repo.get_invite("tok-1")
      assert inv.campaign_id == @cid
      assert inv.status == :active
      assert Enum.map(Repo.list_invites(@cid), & &1.token) == ["tok-1"]
    end

    test "InviteRedeemed → Invite :redeemed + neuer Member als :spieler" do
      apply!(
        "InviteCreated",
        %{
          "token" => "tok-2",
          "campaign_id" => @cid,
          "created_by_discord_id" => @owner,
          "expires_at" => "2099-01-01T00:00:00Z"
        },
        100
      )

      apply!(
        "InviteRedeemed",
        %{
          "token" => "tok-2",
          "discord_id" => "did-newcomer",
          "display_name" => "Newcomer"
        },
        101
      )

      assert Repo.get_invite("tok-2").status == :redeemed
      assert Repo.member?(@cid, "did-newcomer")
      assert Repo.campaign_role(@cid, "did-newcomer") == :spieler
    end

    test "InviteRevoked → Invite :revoked" do
      apply!(
        "InviteCreated",
        %{
          "token" => "tok-3",
          "campaign_id" => @cid,
          "created_by_discord_id" => @owner,
          "expires_at" => "2099-01-01T00:00:00Z"
        },
        100
      )

      apply!("InviteRevoked", %{"token" => "tok-3"}, 101)
      assert Repo.get_invite("tok-3").status == :revoked
    end
  end

  describe "MarkerAdded" do
    test "schreibt einen Marker, lesbar über list_markers" do
      apply!(
        "MarkerAdded",
        %{
          "id" => "mark-1",
          "session_id" => @sid,
          "at_ts" => "2026-01-01T20:05:00Z",
          "marker_kind" => "funny",
          "label" => "Würfel-Patzer"
        },
        100
      )

      [m] = Repo.list_markers(@sid)
      assert m.id == "mark-1"
      assert m.kind == :funny
      assert m.label == "Würfel-Patzer"
    end
  end

  describe "MemberRemoved" do
    test "tombstoned den Member → member?/campaign_role spiegeln das" do
      assert Repo.member?(@cid, @member)

      apply!("MemberRemoved", %{"campaign_id" => @cid, "discord_id" => @member}, 100)

      refute Repo.member?(@cid, @member)
      assert Repo.campaign_role(@cid, @member) == nil
    end
  end

  describe "Session-Lifecycle" do
    test "SessionEnded → status :completed + ended_at gesetzt" do
      apply!("SessionEnded", %{"id" => @sid, "campaign_id" => @cid}, 100)

      s = Repo.get_session(@sid)
      assert s.status == :completed
      assert s.ended_at
    end

    test "RecordingStateChanged → Status spiegelt den neuen State" do
      apply!("RecordingStateChanged", %{"session_id" => @sid, "state" => "processing"}, 100)
      assert Repo.get_session(@sid).status == :processing
    end

    test "SessionDeleted → Session + ihre Utterances verschwinden" do
      assert length(Repo.list_utterances(@sid)) == 3

      apply!("SessionDeleted", %{"session_id" => @sid, "campaign_id" => @cid}, 100)

      assert Repo.get_session(@sid) == nil
      assert Repo.list_utterances(@sid) == []
    end
  end

  describe "SessionFaithfulnessScored" do
    test "schreibt Score + Claims, lesbar über get_faithfulness_score" do
      apply!(
        "SessionFaithfulnessScored",
        %{
          "session_id" => @sid,
          "campaign_id" => @cid,
          "score" => 0.87,
          "claims" => [%{"text" => "Romeo trifft Julia", "supported" => true}]
        },
        100
      )

      score = Repo.get_faithfulness_score(@sid)
      assert score.score == 0.87
      assert length(score.claims) == 1
    end
  end
end
