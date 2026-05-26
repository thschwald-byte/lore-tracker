defmodule Worker.MaterializerReplayTest do
  @moduledoc """
  Issue #92: doppelter Replay einer Event-Sequenz muss kein Diff-Set in den
  materialisierten Mnesia-Tabellen produzieren. Ergänzt den Single-Event-Test
  in `materializer_idempotency_test.exs` um eine realistische Multi-Event-
  Sequenz (CampaignCreated → SessionScheduled → N × UtteranceAppended).
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Materializer
  alias Worker.Schema.Mnesia, as: S
  alias Worker.Schema.DynamicTables

  setup do
    clear_all_tables!()
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
    :ok
  end

  test "Multi-Event-Replay: zweimaliger Apply derselben Sequenz produziert identischen Mnesia-State" do
    campaign_id = "019e2222-2222-7222-8222-222222222222"
    session_id = "019e3333-3333-7333-8333-333333333333"
    owner_did = "test-owner-replay"

    events =
      [
        event(
          "CampaignCreated",
          %{
            "id" => campaign_id,
            "name" => "Replay Test",
            "icon_url" => nil,
            "theme_blurb" => nil,
            "owner_discord_id" => owner_did,
            "owner_display_name" => "Owner"
          },
          1,
          event_id: "019e4444-4444-7444-8444-444444444401"
        ),
        event(
          "SessionScheduled",
          %{
            "id" => session_id,
            "campaign_id" => campaign_id,
            "number" => 1,
            "name" => "Session 1",
            "scheduled_for" => DateTime.to_iso8601(DateTime.utc_now())
          },
          2,
          event_id: "019e4444-4444-7444-8444-444444444402"
        )
      ] ++
        for i <- 1..50 do
          eid =
            "019e4444-4444-7444-8444-44444444#{String.pad_leading("#{i + 2}", 4, "0")}"

          event(
            "UtteranceAppended",
            %{
              "id" => "utt-#{i}",
              "campaign_id" => campaign_id,
              "session_id" => session_id,
              "discord_id" => owner_did,
              "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
              "text" => "utterance #{i}",
              "confidence" => 0.9,
              "status" => "confirmed"
            },
            i + 2,
            event_id: eid
          )
        end

    # Pass 1: cold apply
    Enum.each(events, &Materializer.apply_local/1)

    state_after_pass_1 = capture_state(campaign_id)

    # Pass 2: replay (alle event_ids schon bekannt → applied_event_ids-Skip)
    skip_results =
      Enum.map(events, fn ev ->
        Materializer.apply_event(Map.put(ev, "seq", :rand.uniform(1_000_000)))
      end)

    assert Enum.all?(skip_results, &(&1 == :skipped)),
           "alle Re-Apply-Calls müssen :skipped sein, sonst Doppel-Apply"

    state_after_pass_2 = capture_state(campaign_id)

    assert state_after_pass_1 == state_after_pass_2,
           "Mnesia-State nach Replay weicht ab — Materializer ist nicht idempotent"

    # Sanity: erwartete Größen
    assert state_after_pass_1.campaigns_count == 1
    assert state_after_pass_1.sessions_count == 1
    assert state_after_pass_1.utterances_count == 50
  end

  defp capture_state(campaign_id) do
    campaign = :mnesia.dirty_read(S.campaigns(), campaign_id)
    sessions = :mnesia.dirty_index_read(S.sessions(), campaign_id, :campaign_id)

    utterance_rows =
      sessions
      |> Enum.flat_map(fn s ->
        sid = elem(s, 1)
        :mnesia.dirty_index_read(S.utterances(), sid, :session_id)
      end)
      |> Enum.sort()

    %{
      campaigns_count: length(campaign),
      sessions_count: length(sessions),
      utterances_count: length(utterance_rows),
      utterance_rows: utterance_rows,
      campaign_row: campaign,
      event_log_size: event_log_size(campaign_id)
    }
  end

  defp event_log_size(campaign_id) do
    table = DynamicTables.table_name(campaign_id)

    if :mnesia.table_info(table, :all) |> is_list() do
      :mnesia.table_info(table, :size)
    else
      0
    end
  rescue
    _ -> 0
  end
end
