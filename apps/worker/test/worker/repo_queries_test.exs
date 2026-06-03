defmodule Worker.RepoQueriesTest do
  @moduledoc """
  Issue #66 (Coverage-Followup): Read-Query-Coverage für `Worker.Repo`.

  Vor diesem Test lag `Worker.Repo` bei ~35% — die ~50 Read-Funktionen
  (`list_sessions`, `list_members`, `campaign_role`, `list_utterances`, …)
  waren nur indirekt über LV-/Materializer-Tests berührt. Hier bauen wir mit
  `TestHelper.build_campaign(apply: true)` eine voll-materialisierte Kampagne
  und assert'en direkt gegen die Query-API — der Fixture-Generator aus dem
  ersten #66-PR macht das in <10 Setup-Zeilen.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Repo

  @cid "repo-q-camp"
  @owner "did-owner-repo-q"
  @member_a "did-member-a"
  @member_b "did-member-b"

  setup do
    clear_all_tables!()
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)

    built =
      build_campaign(
        campaign_id: @cid,
        name: "Repo-Query-Kampagne",
        owner_did: @owner,
        owner_name: "Owner Repo-Q",
        members: [@member_a, @member_b],
        sessions: [2, 3],
        include_summaries?: true,
        apply: true
      )

    {:ok, built: built}
  end

  describe "Campaign-Queries" do
    test "get_campaign/1 liefert die Kampagne mit abgeleitetem owner_discord_id" do
      camp = Repo.get_campaign(@cid)
      assert camp.id == @cid
      assert camp.name == "Repo-Query-Kampagne"
      # Issue #140: owner_discord_id ist abgeleitet = erster Spielleiter.
      assert camp.owner_discord_id == @owner
      assert camp.transcript_source == :confirmed
    end

    test "get_campaign/1 → nil für unbekannte ID" do
      assert Repo.get_campaign("gibt-es-nicht") == nil
    end

    test "all_campaigns/0 enthält die Kampagne" do
      ids = Repo.all_campaigns() |> Enum.map(& &1.id)
      assert @cid in ids
    end

    test "list_campaigns_for/1 listet nur Kampagnen mit Membership" do
      assert Repo.list_campaigns_for(@owner) |> Enum.map(& &1.id) == [@cid]
      assert Repo.list_campaigns_for(@member_a) |> Enum.map(& &1.id) == [@cid]
      assert Repo.list_campaigns_for("fremder-did") == []
    end

    test "list_campaign_ids_for/1" do
      assert Repo.list_campaign_ids_for(@owner) == [@cid]
      assert Repo.list_campaign_ids_for("fremder-did") == []
    end
  end

  describe "Member-Queries" do
    test "list_members/1 enthält Owner (spielleiter) + beide Member (spieler)" do
      members = Repo.list_members(@cid)
      by_did = Map.new(members, &{&1.discord_id, &1.role})

      assert by_did[@owner] == :spielleiter
      assert by_did[@member_a] == :spieler
      assert by_did[@member_b] == :spieler
    end

    test "member?/2" do
      assert Repo.member?(@cid, @owner)
      assert Repo.member?(@cid, @member_a)
      refute Repo.member?(@cid, "fremder-did")
    end

    test "campaign_role/2" do
      assert Repo.campaign_role(@cid, @owner) == :spielleiter
      assert Repo.campaign_role(@cid, @member_a) == :spieler
      assert Repo.campaign_role(@cid, "fremder-did") == nil
    end

    test "first_spielleiter/1 = Owner" do
      assert Repo.first_spielleiter(@cid) == @owner
    end
  end

  describe "Session-Queries" do
    test "list_sessions/1 liefert beide Sessions nach Nummer sortiert", %{built: built} do
      sessions = Repo.list_sessions(@cid)
      assert Enum.map(sessions, & &1.number) == [1, 2]
      assert Enum.map(sessions, & &1.id) == Enum.map(built.sessions, & &1.id)
    end

    test "get_session/1" do
      [s1, _s2] = Repo.list_sessions(@cid)
      assert Repo.get_session(s1.id).number == 1
      assert Repo.get_session("keine-session") == nil
    end

    test "next_session_number/1 = max+1" do
      assert Repo.next_session_number(@cid) == 3
      assert Repo.next_session_number("leere-kampagne") == 1
    end

    test "active_session_for/1 findet die gestartete Session" do
      # build_campaign emittiert SessionStarted (→ :recording), aber kein
      # SessionEnded → die Session ist „aktiv".
      active = Repo.active_session_for(@cid)
      assert active && active.status == :recording
    end
  end

  describe "Utterance-Queries" do
    test "list_utterances/2 liefert die Utterances der ersten Session", %{built: built} do
      [s1, _s2] = built.sessions
      utts = Repo.list_utterances(s1.id)
      assert length(utts) == 2
      assert Enum.all?(utts, &(&1.status == :confirmed))
      assert Enum.map(utts, & &1.id) |> Enum.sort() == Enum.sort(s1.utterance_ids)
    end

    test "list_utterances/2 respektiert :limit (nimmt die neuesten)" do
      [_s1, s2] = Repo.list_sessions(@cid)
      assert length(Repo.list_utterances(s2.id, limit: 1)) == 1
    end

    test "recent_utterance_texts/2 liefert Texte" do
      [_s1, s2] = Repo.list_sessions(@cid)
      texts = Repo.recent_utterance_texts(s2.id, 2)
      assert length(texts) == 2
      assert Enum.all?(texts, &is_binary/1)
    end

    test "list_utterances_for_campaign/1 aggregiert über alle Sessions" do
      # 2 + 3 Utterances.
      assert length(Repo.list_utterances_for_campaign(@cid)) == 5
    end
  end

  describe "Summary-Queries" do
    test "get_session_summary/1 liefert das pro Session generierte Resümee", %{built: built} do
      [s1, _s2] = built.sessions
      summary = Repo.get_session_summary(s1.id)
      assert summary.content_md == "Resümee #{s1.id}"
      assert summary.source == :llm
    end

    test "get_session_summary/1 → nil ohne Resümee" do
      assert Repo.get_session_summary("session-ohne-summary") == nil
    end

    test "list_session_summaries/1 liefert beide Resümees" do
      assert length(Repo.list_session_summaries(@cid)) == 2
    end
  end

  describe "snapshot/1 — die Hub.Reader-Konsum-API" do
    test "kind=campaigns_for liefert string-keyed Dashboard-Snapshot" do
      snap = Repo.snapshot(%{"kind" => "campaigns_for", "discord_id" => @owner})
      assert is_list(snap["campaigns"])
      assert Enum.map(snap["campaigns"], & &1["id"]) == [@cid]
      assert is_map(snap["users"])
      assert snap["viewer_role"] == "spieler"
    end

    test "kind=campaigns_for für Fremden → leere Kampagnenliste" do
      snap = Repo.snapshot(%{"kind" => "campaigns_for", "discord_id" => "fremder-did"})
      assert snap["campaigns"] == []
    end

    test "kind=campaign liefert den vollen Kampagnen-Snapshot für ein Member" do
      snap = Repo.snapshot(%{"kind" => "campaign", "id" => @cid, "viewer_discord_id" => @owner})

      assert snap["campaign"]["id"] == @cid
      assert length(snap["sessions"]) == 2
      assert length(snap["members"]) == 3
      assert length(snap["summaries"]) == 2
      # 2 + 3 Utterances über beide Sessions.
      assert length(snap["utterances"]) == 5
      assert snap["viewer_role"] == "spieler"
      # Leere-aber-valide Fan-out-Felder.
      assert snap["chronik"] == []
      assert snap["epos"] == nil
    end

    test "kind=campaign für Nicht-Member → forbidden" do
      snap =
        Repo.snapshot(%{"kind" => "campaign", "id" => @cid, "viewer_discord_id" => "fremder-did"})

      assert snap == %{"forbidden" => true}
    end

    test "kind=active_session liefert die laufende Session-ID" do
      snap = Repo.snapshot(%{"kind" => "active_session", "campaign_id" => @cid})
      assert is_binary(snap["session_id"])
    end

    test "kind=active_session ohne aktive Session → nil" do
      snap = Repo.snapshot(%{"kind" => "active_session", "campaign_id" => "leere-kampagne"})
      assert snap["session_id"] == nil
    end
  end
end
