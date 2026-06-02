defmodule Worker.TestHelperBuildCampaignTest do
  @moduledoc """
  Issue #66: Tests für den `Worker.TestHelper.build_campaign/1`-Fixture-Generator.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  describe "build_campaign/1 — Struktur (ohne apply)" do
    test "Defaults: 1 Session × 3 Utterances, Events in korrekter Reihenfolge + Seq" do
      c = build_campaign()

      assert c.campaign_id == "test-campaign"
      assert [%{id: "test-campaign-s1", number: 1, utterance_ids: utt_ids}] = c.sessions
      assert length(utt_ids) == 3

      kinds = Enum.map(c.events, & &1["payload"]["kind"])

      assert kinds ==
               ["CampaignCreated", "SessionScheduled", "SessionStarted"] ++
                 List.duplicate("UtteranceAppended", 3)

      # Seq lückenlos ab 1
      assert Enum.map(c.events, & &1["seq"]) == Enum.to_list(1..6)
    end

    test ":sessions-Liste + :members + Speaker-Round-Robin" do
      c = build_campaign(sessions: [2, 3], members: ["m1", "m2"], owner_did: "owner")

      assert length(c.sessions) == 2
      assert Enum.map(c.sessions, &length(&1.utterance_ids)) == [2, 3]

      # AdminMemberAdded pro Member
      member_evs = Enum.filter(c.events, &(&1["payload"]["kind"] == "AdminMemberAdded"))
      assert Enum.map(member_evs, & &1["payload"]["discord_id"]) == ["m1", "m2"]

      # Speaker round-robin über [owner, m1, m2]
      s1_utts =
        c.events
        |> Enum.filter(
          &(&1["payload"]["kind"] == "UtteranceAppended" and
              &1["payload"]["session_id"] == "test-campaign-s1")
        )
        |> Enum.map(& &1["payload"]["discord_id"])

      assert s1_utts == ["owner", "m1"]
    end

    test ":include_summaries? hängt pro Session ein SessionSummaryGenerated an" do
      c = build_campaign(sessions: [1, 1], include_summaries?: true)
      summaries = Enum.filter(c.events, &(&1["payload"]["kind"] == "SessionSummaryGenerated"))
      assert length(summaries) == 2
    end
  end

  describe "build_campaign/1 — :apply materialisiert nach Mnesia" do
    setup do
      clear_all_tables!()
      mat = ensure_materializer!()
      on_exit(fn -> if mat && Process.alive?(mat), do: Process.exit(mat, :kill) end)
      :ok
    end

    test "Campaign + Sessions + Utterances landen im Repo" do
      c = build_campaign(campaign_id: "applied-camp", sessions: [4], apply: true)

      assert %{} = Worker.Repo.get_campaign("applied-camp")
      [sess] = c.sessions
      assert length(Worker.Repo.list_utterances(sess.id)) == 4
    end
  end
end
