defmodule Hub.CommandsAudioChunkTest do
  @moduledoc """
  Issue #468 — Tests dass `Hub.Commands.forward_audio_chunk/4` Audio-Chunks
  weder still verwirft noch das Log spamt:

  - Bei Member-Worker connected → Forward + return 1, KEIN telemetry-Drop.
  - Bei keinem Member-Worker connected → return 0 + telemetry-Event
    `[:hub, :audio, :chunk_dropped]`. KEIN pick_leader-Logger-Spam (auch
    bei wiederholten Drops, weil Audio-Hot-Path mit `quiet?: true` ruft).

  Pattern wie in commands_member_routing_test.exs.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Hub.{Commands, WorkerRegistry}

  setup do
    on_exit(fn -> :ok end)
    :ok
  end

  defp spawn_fake_worker(worker_id, admin_did, subscribed_to) do
    parent = self()

    pid =
      spawn_link(fn ->
        {:ok, _} = WorkerRegistry.track(worker_id, admin_did)

        if subscribed_to != [] do
          {:ok, _} = WorkerRegistry.subscribe(worker_id, subscribed_to)
        end

        send(parent, {:tracked, worker_id})

        receive do
          msg ->
            send(parent, {:received, worker_id, msg})
        after
          5_000 -> :timeout
        end
      end)

    assert_receive {:tracked, ^worker_id}, 2_000
    wait_until_visible(worker_id)

    pid
  end

  defp wait_until_visible(worker_id, attempts \\ 50) do
    case Enum.find(WorkerRegistry.list(), fn {id, _} -> id == worker_id end) do
      nil when attempts > 0 ->
        Process.sleep(20)
        wait_until_visible(worker_id, attempts - 1)

      nil ->
        flunk("Worker #{worker_id} nie im Tracker sichtbar geworden")

      _ ->
        :ok
    end
  end

  # Attach einen Test-Telemetry-Handler, der jedes Event an `self()` sendet.
  defp attach_telemetry(event_name) do
    test_pid = self()
    handler_id = "test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      event_name,
      fn _name, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event_name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  describe "forward_audio_chunk/4 — happy path" do
    test "Member-Worker connected → return 1 + Chunk geht raus + KEIN Drop-Telemetry" do
      cid = "camp-fwd-#{System.unique_integer([:positive])}"
      sid = "session-#{System.unique_integer([:positive])}"

      _worker = spawn_fake_worker("w-fwd-A", "admin-A", [cid])

      attach_telemetry([:hub, :audio, :chunk_dropped])

      assert 1 == Commands.forward_audio_chunk(cid, sid, "sender-did", "chunk-payload")

      assert_receive {:received, "w-fwd-A", {:audio_chunk, ^sid, "sender-did", "chunk-payload"}},
                     2_000

      refute_received {:telemetry, [:hub, :audio, :chunk_dropped], _, _}
    end
  end

  describe "forward_audio_chunk/4 — Drop-Pfad" do
    test "Kein Member-Worker → return 0 + Drop-Telemetry mit campaign+session+reason" do
      cid = "camp-drop-#{System.unique_integer([:positive])}"
      other_cid = "camp-other-#{System.unique_integer([:positive])}"
      sid = "session-drop-#{System.unique_integer([:positive])}"

      # Worker connected, aber NICHT auf cid subscribed → pick_leader liefert nil.
      _non_member = spawn_fake_worker("w-drop-other", "admin-X", [other_cid])

      attach_telemetry([:hub, :audio, :chunk_dropped])

      assert 0 == Commands.forward_audio_chunk(cid, sid, "sender", "chunk")

      assert_receive {:telemetry, [:hub, :audio, :chunk_dropped], measurements, metadata}, 2_000

      assert measurements.count == 1
      assert measurements.bytes == byte_size("chunk")
      assert metadata.campaign_id == cid
      assert metadata.session_id == sid
      assert metadata.reason == :no_member_worker
    end

    test "Audio-Hot-Path schweigt pick_leader-Logger (quiet?: true) auch bei wiederholtem Drop" do
      cid = "camp-quiet-#{System.unique_integer([:positive])}"
      sid = "session-quiet-#{System.unique_integer([:positive])}"

      log =
        capture_log(fn ->
          Enum.each(1..5, fn _ ->
            Commands.forward_audio_chunk(cid, sid, "sender", "chunk")
          end)
        end)

      # Kein "no member-worker connected"-Log aus pick_leader (sonst wäre
      # 500ms-Streaming = Log-Flood).
      refute log =~ "Hub.Commands.pick_leader: no member-worker connected"
    end

    test "Recording-Start (NICHT-Audio-Hot-Path) loggt pick_leader-Fail weiter" do
      cid = "camp-loud-#{System.unique_integer([:positive])}"

      log =
        capture_log(fn ->
          assert 0 == Commands.request_recording_start("caller", cid)
        end)

      # request_recording_start ruft pick_leader OHNE quiet? → loggt.
      assert log =~ "Hub.Commands.pick_leader: no member-worker connected"
      assert log =~ cid
    end
  end
end
