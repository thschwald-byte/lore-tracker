defmodule Worker.MaterializerCampaignDeletedTest do
  @moduledoc """
  Issue #15: `CampaignDeleted` cascade-löscht alle materialisierten
  Rows die zu der Kampagne gehören — campaign, members, invites,
  sessions, utterances, markers, epos_entries, epos_history,
  session_summaries, chronik_entries.
  """

  use ExUnit.Case, async: false

  alias Worker.Materializer
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-deleted-test"
  @other_cid "camp-other"
  @owner "owner-did"

  setup do
    Enum.each(
      [
        S.campaigns(),
        S.campaign_members(),
        S.campaign_invites(),
        S.sessions(),
        S.utterances(),
        S.markers(),
        S.epos_entries(),
        S.epos_history(),
        S.session_summaries(),
        S.chronik_entries(),
        S.worker_state()
      ],
      fn t -> {:atomic, :ok} = :mnesia.clear_table(t) end
    )

    mat_pid =
      case Worker.Materializer.start_link([]) do
        {:ok, pid} -> pid
        {:error, {:already_started, _}} -> nil
      end

    now = DateTime.utc_now()

    # Setup: 2 Campaigns mit identischer Sub-Struktur. Der Cascade darf
    # NUR die Ziel-Campaign treffen, die andere muss komplett unangetastet
    # bleiben (Sanity gegen broad index-write-Bugs).
    seed_campaign = fn cid ->
      :mnesia.transaction(fn ->
        :mnesia.write({
          S.campaigns(),
          cid,
          "Campaign #{cid}",
          nil,
          nil,
          :active,
          now,
          %{}
        })

        :mnesia.write({
          S.campaign_members(),
          S.member_key(cid, @owner),
          cid,
          @owner,
          :spielleiter,
          now,
          nil,
          nil
        })

        :mnesia.write({
          S.campaign_invites(),
          "invite-#{cid}",
          cid,
          @owner,
          now,
          nil,
          :active,
          nil
        })

        sid = "sess-#{cid}"

        :mnesia.write({
          S.sessions(),
          sid,
          cid,
          1,
          "Session 1",
          :completed,
          nil,
          now,
          now
        })

        :mnesia.write({
          S.utterances(),
          "utt-#{cid}",
          sid,
          @owner,
          now,
          "hello",
          0.9,
          :confirmed,
          nil
        })

        :mnesia.write({
          S.markers(),
          "mark-#{cid}",
          sid,
          now,
          :plot,
          "marker"
        })

        :mnesia.write({
          S.epos_entries(),
          cid,
          cid,
          nil,
          "epos content",
          now
        })

        :mnesia.write({
          S.epos_history(),
          "ehist-#{cid}",
          cid,
          "old epos",
          now,
          @owner,
          :manual,
          1
        })

        :mnesia.write({
          S.session_summaries(),
          sid,
          cid,
          "summary",
          now,
          :llm
        })

        :mnesia.write({
          S.chronik_entries(),
          "chr-#{cid}",
          cid,
          "Tag 1",
          "Event",
          "summary line",
          sid
        })
      end)
    end

    seed_campaign.(@cid)
    seed_campaign.(@other_cid)

    on_exit(fn ->
      if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill)
    end)

    :ok
  end

  defp event(payload, seq) do
    %{
      "seq" => seq,
      "ts" => DateTime.to_iso8601(DateTime.utc_now()),
      "author_worker_id" => "test",
      "payload" => Map.put(payload, "kind", "CampaignDeleted")
    }
  end

  defp count(table), do: :mnesia.dirty_match_object({table, :_, :_, :_, :_, :_, :_, :_, :_}) |> length()

  test "cascade-löscht alle 10 tables für die Ziel-Campaign" do
    # Sanity vorab: jede Campaign hat 1 Row in jeder ihrer Tabellen.
    assert :mnesia.dirty_read(S.campaigns(), @cid) != []
    assert :mnesia.dirty_index_read(S.sessions(), @cid, :campaign_id) != []

    ev = event(%{"campaign_id" => @cid, "deleted_by" => @owner}, 1000)
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

    ev = event(%{"campaign_id" => "nope", "deleted_by" => @owner}, 1001)
    assert {:applied, 1001} = Materializer.apply_event(ev)

    assert count(S.campaigns()) == rows_before
  end
end
