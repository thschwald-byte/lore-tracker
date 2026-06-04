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

        loop(worker_id, parent)
      end)

    assert_receive {:tracked, ^worker_id}, 2_000
    wait_until_visible(worker_id)

    pid
  end

  # Worker-Prozess-Loop: hört auf Steuer-Messages für held_session-Ops
  # (Phoenix.Tracker.update keyed auf calling pid → muss VOM Worker-Prozess
  # gerufen werden, nicht vom Test-Prozess) und schickt erhaltene
  # Channel-Messages an den Test-Parent. Loopt durchgängig — der Worker
  # darf mehrere Chunks empfangen + zwischendurch held_session-Toggles.
  defp loop(worker_id, parent) do
    receive do
      {:add_held, sid, replyto} ->
        WorkerRegistry.add_held_session(worker_id, sid)
        send(replyto, {:added, worker_id, sid})
        loop(worker_id, parent)

      {:remove_held, sid, replyto} ->
        WorkerRegistry.remove_held_session(worker_id, sid)
        send(replyto, {:removed, worker_id, sid})
        loop(worker_id, parent)

      msg ->
        send(parent, {:received, worker_id, msg})
        loop(worker_id, parent)
    after
      10_000 -> :timeout
    end
  end

  defp hold_session(pid, worker_id, sid) do
    send(pid, {:add_held, sid, self()})
    assert_receive {:added, ^worker_id, ^sid}, 2_000
    wait_until_held(worker_id, sid)
  end

  defp release_session(pid, worker_id, sid) do
    send(pid, {:remove_held, sid, self()})
    assert_receive {:removed, ^worker_id, ^sid}, 2_000
    wait_until_not_held(worker_id, sid)
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

  describe "forward_audio_chunk/4 — Session-Stickiness (Cut 2)" do
    test "Wenn Worker A die Session hält, geht der Chunk an A — auch wenn Worker B lexikografisch kleiner ist" do
      cid = "camp-stick-#{System.unique_integer([:positive])}"
      sid = "session-stick-#{System.unique_integer([:positive])}"

      # B hat die lexikografisch kleinere ID — würde ohne Stickiness gewinnen.
      _b = spawn_fake_worker("aaa-worker-B", "admin-B", [cid])
      _a = spawn_fake_worker("zzz-worker-A", "admin-A", [cid])

      # Worker A meldet sich als Session-Halter.
      hold_session(_a, "zzz-worker-A", sid)

      assert 1 == Commands.forward_audio_chunk(cid, sid, "sender", "chunk-data")

      # A bekommt den Chunk, B nicht.
      assert_receive {:received, "zzz-worker-A", {:audio_chunk, ^sid, "sender", "chunk-data"}},
                     2_000

      refute_received {:received, "aaa-worker-B", _}
    end

    test "Ohne held_session-Eintrag → normale lexikografische Wahl (Cut 1-Default)" do
      cid = "camp-default-#{System.unique_integer([:positive])}"
      sid = "session-default-#{System.unique_integer([:positive])}"

      _b = spawn_fake_worker("aaa-worker-default-B", "admin-B", [cid])
      _a = spawn_fake_worker("zzz-worker-default-A", "admin-A", [cid])

      # Niemand meldet sich als Halter.

      assert 1 == Commands.forward_audio_chunk(cid, sid, "sender", "chunk")

      # B gewinnt (lexikografisch kleiner).
      assert_receive {:received, "aaa-worker-default-B", _}, 2_000
      refute_received {:received, "zzz-worker-default-A", _}
    end

    test "Stickiness gilt nur für die richtige session_id" do
      cid = "camp-mixed-#{System.unique_integer([:positive])}"
      sid_a = "session-A-#{System.unique_integer([:positive])}"
      sid_b = "session-B-#{System.unique_integer([:positive])}"

      _w_b = spawn_fake_worker("aaa-mixed-B", "admin-B", [cid])
      _w_a = spawn_fake_worker("zzz-mixed-A", "admin-A", [cid])

      # Worker A hält Session sid_a. Session sid_b ist NICHT in seinem Set.
      hold_session(_w_a, "zzz-mixed-A", sid_a)

      # Chunk für sid_a → Stickiness greift, A bekommt's.
      assert 1 == Commands.forward_audio_chunk(cid, sid_a, "sender", "chunk-a")
      assert_receive {:received, "zzz-mixed-A", {:audio_chunk, ^sid_a, _, "chunk-a"}}, 2_000

      # Chunk für sid_b → keine Stickiness, B (lex kleiner) bekommt's.
      assert 1 == Commands.forward_audio_chunk(cid, sid_b, "sender", "chunk-b")
      assert_receive {:received, "aaa-mixed-B", {:audio_chunk, ^sid_b, _, "chunk-b"}}, 2_000
    end

    test "remove_held_session → Stickiness verschwindet, lex-default greift wieder" do
      cid = "camp-release-#{System.unique_integer([:positive])}"
      sid = "session-release-#{System.unique_integer([:positive])}"

      _b = spawn_fake_worker("aaa-release-B", "admin-B", [cid])
      _a = spawn_fake_worker("zzz-release-A", "admin-A", [cid])

      hold_session(_a, "zzz-release-A", sid)

      assert 1 == Commands.forward_audio_chunk(cid, sid, "sender", "chunk-pre")
      assert_receive {:received, "zzz-release-A", _}, 2_000

      release_session(_a, "zzz-release-A", sid)

      assert 1 == Commands.forward_audio_chunk(cid, sid, "sender", "chunk-post")
      assert_receive {:received, "aaa-release-B", {:audio_chunk, ^sid, _, "chunk-post"}}, 2_000
    end
  end

  defp wait_until_held(worker_id, sid, attempts \\ 50) do
    case Enum.find(WorkerRegistry.list(), fn {id, _} -> id == worker_id end) do
      {_id, meta} ->
        if MapSet.member?(Map.get(meta, :held_sessions, MapSet.new()), sid) do
          :ok
        else
          if attempts > 0, do: (Process.sleep(20); wait_until_held(worker_id, sid, attempts - 1)),
            else: flunk("held_session #{sid} nie an #{worker_id} attached")
        end

      nil ->
        flunk("Worker #{worker_id} nicht im Tracker")
    end
  end

  defp wait_until_not_held(worker_id, sid, attempts \\ 50) do
    case Enum.find(WorkerRegistry.list(), fn {id, _} -> id == worker_id end) do
      {_id, meta} ->
        if not MapSet.member?(Map.get(meta, :held_sessions, MapSet.new()), sid) do
          :ok
        else
          if attempts > 0, do: (Process.sleep(20); wait_until_not_held(worker_id, sid, attempts - 1)),
            else: flunk("held_session #{sid} an #{worker_id} nie released")
        end

      nil ->
        :ok
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
