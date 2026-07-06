defmodule Worker.IntentsPublishBatchTest do
  @moduledoc """
  Issue #702: `Intents.publish_batch/1` — gebatchter Hub-Sync für Event-
  Schwälle (Transkriptions-Backlog). Gesicherte Verträge:

  - Local-first: JEDES Event ist lokal applied, unabhängig vom (offline) Hub.
  - Hub offline → `{:ok, %{synced: 0, pending: N}}`, kein Raise, lautes Log.
  - Leere Liste → no-op ohne Hub-Call.
  - `chunk_events/2` (pur): Reihenfolge + Chunk-Größen + Rest-Chunk.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Worker.TestHelper

  alias Worker.{Intents, Repo}
  alias Worker.Schema.Builder
  alias Shared.Events

  setup do
    clear_all_tables!()
    mat = ensure_materializer!()
    on_exit(fn -> if mat && Process.alive?(mat), do: Process.exit(mat, :kill) end)
    :ok
  end

  defp utt_payload(sid, i) do
    %{
      "kind" => Events.utterance_appended(),
      "id" => "u-batch-#{i}",
      "session_id" => sid,
      "discord_id" => "111",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "text" => "Batch-Utterance #{i}",
      "confidence" => %{
        "mean_p" => 1.0,
        "min_p" => 1.0,
        "low_token_fraction" => 0.0,
        "token_count" => 0
      },
      "status" => "confirmed"
    }
  end

  test "Hub offline: alle Events lokal applied, Rückgabe {:ok, %{synced: 0, pending: N}}" do
    Builder.write!(Builder.session("s-batch", "c-1", number: 1))
    payloads = Enum.map(1..7, &utt_payload("s-batch", &1))

    log =
      capture_log(fn ->
        assert {:ok, %{synced: 0, pending: 7}} = Intents.publish_batch(payloads)
      end)

    assert log =~ "Intents.publish_batch"

    utts = Repo.list_utterances("s-batch", limit: :all)
    assert length(utts) == 7
    assert Enum.map(utts, & &1.text) |> Enum.member?("Batch-Utterance 3")
  end

  test "leere Liste ist ein no-op" do
    assert {:ok, %{synced: 0, pending: 0}} = Intents.publish_batch([])
  end

  test "pending_publish_count wird um die Batch-Größe gebumpt (nicht um 1)" do
    Builder.write!(Builder.session("s-cnt", "c-1", number: 1))
    before = Repo.get_state(:pending_publish_count) || 0

    capture_log(fn ->
      assert {:ok, %{pending: 3}} =
               Intents.publish_batch(Enum.map(1..3, &utt_payload("s-cnt", &1)))
    end)

    assert (Repo.get_state(:pending_publish_count) || 0) == before + 3
  end

  describe "chunk_events/2 (pur)" do
    test "chunked in Reihenfolge mit Rest-Chunk" do
      events = Enum.map(1..7, &%{event_id: "e#{&1}", payload: %{}})
      assert [[a, _b, c], [d, _e, f], [g]] = Intents.chunk_events(events, 3)
      assert a.event_id == "e1" and c.event_id == "e3"
      assert d.event_id == "e4" and f.event_id == "e6"
      assert g.event_id == "e7"
    end

    test "Default-Chunk-Größe ist 25" do
      events = Enum.map(1..26, &%{event_id: "e#{&1}", payload: %{}})
      assert [first, second] = Intents.chunk_events(events)
      assert length(first) == 25
      assert length(second) == 1
    end
  end
end
