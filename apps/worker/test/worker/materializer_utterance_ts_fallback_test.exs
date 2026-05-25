defmodule Worker.MaterializerUtteranceTsFallbackTest do
  @moduledoc """
  Issue #95: Wenn ein UtteranceAppended-Event kein payload["timestamp"] hat
  (z.B. Seed-Events die nur das Envelope-"ts" tragen), muss der Materializer
  auf das Envelope-`ts` zurückfallen. Sonst crasht `Worker.Repo.list_utterances`
  später in Enum.sort_by mit DateTime.compare(nil, nil).
  """

  use ExUnit.Case, async: false

  alias Worker.Materializer
  alias Worker.Schema.Mnesia, as: S

  setup do
    {:atomic, :ok} = :mnesia.clear_table(S.utterances())
    {:atomic, :ok} = :mnesia.clear_table(S.applied_event_ids())

    mat_pid =
      case Worker.Materializer.start_link([]) do
        {:ok, pid} -> pid
        {:error, {:already_started, _}} -> nil
      end

    on_exit(fn ->
      if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill)
    end)

    :ok
  end

  test "UtteranceAppended ohne payload[timestamp] fällt auf event[ts] zurück" do
    envelope_ts = "2026-01-01T12:00:00Z"

    event = %{
      "event_id" => "019e5555-5555-7555-8555-555555555501",
      "ts" => envelope_ts,
      "author_worker_id" => "test",
      "payload" => %{
        "kind" => "UtteranceAppended",
        "id" => "utt-no-payload-ts",
        "campaign_id" => "test-camp",
        "session_id" => "test-sess",
        "discord_id" => "test-user",
        # KEIN "timestamp"-Feld — wie Seed-Events
        "text" => "Test utterance",
        "confidence" => 1.0,
        "status" => "final"
      }
    }

    assert :ok = Materializer.apply_local(event)

    [{_, _id, _sid, _did, ts, _text, _conf, _stat, _del}] =
      :mnesia.dirty_read(S.utterances(), "utt-no-payload-ts")

    assert %DateTime{} = ts, "ts darf nicht nil sein, sondern muss DateTime aus envelope sein"
    assert DateTime.to_iso8601(ts) == "2026-01-01T12:00:00Z"
  end

  test "UtteranceAppended mit payload[timestamp] benutzt payload-ts, nicht envelope" do
    payload_ts = "2026-02-02T15:30:00Z"
    envelope_ts = "2026-01-01T12:00:00Z"

    event = %{
      "event_id" => "019e5555-5555-7555-8555-555555555502",
      "ts" => envelope_ts,
      "author_worker_id" => "test",
      "payload" => %{
        "kind" => "UtteranceAppended",
        "id" => "utt-with-payload-ts",
        "campaign_id" => "test-camp",
        "session_id" => "test-sess",
        "discord_id" => "test-user",
        "timestamp" => payload_ts,
        "text" => "Test utterance",
        "confidence" => 1.0,
        "status" => "final"
      }
    }

    assert :ok = Materializer.apply_local(event)

    [{_, _id, _sid, _did, ts, _, _, _, _}] =
      :mnesia.dirty_read(S.utterances(), "utt-with-payload-ts")

    assert DateTime.to_iso8601(ts) == "2026-02-02T15:30:00Z",
           "payload[timestamp] muss Vorrang vor envelope[ts] haben"
  end
end
