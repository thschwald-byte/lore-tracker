defmodule Worker.Recording.AudioBufferStreamersTest do
  @moduledoc """
  Issue #392: Chunk-Recency-Presence im AudioBuffer.

  Streamer-Liveness wird aus `last_chunk_at` abgeleitet (frische Keys
  innerhalb @ghost_timeout_ms), entkoppelt von den `writers`-File-Handles.
  Tests decken ab: frische Listung, Recency-Filter, Sweep-Shrinkage-
  Broadcast, graceful drop_streamer, transienter Gap (self-healing ohne
  File-Truncate).
  """

  use ExUnit.Case, async: false

  alias Worker.Recording.AudioBuffer

  @cid "camp-streamers-392"
  # Gültiger base64-Chunk; Inhalt egal (batch-mode → kein live_tee).
  @chunk Base.encode64("audio-bytes-here")

  setup do
    {:atomic, :ok} = :mnesia.clear_table(Worker.Schema.Mnesia.worker_state())

    # HubClient-Stub leitet {:publish_status, payload} an den Test-Prozess
    # weiter, damit wir publish_streamers-Broadcasts asserten können.
    test_pid = self()
    stub = stub_forwarding_process(Worker.HubClient, test_pid)

    {:ok, pid} = AudioBuffer.start_link(:test)
    Application.put_env(:worker, :env, :test)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal)
      if stub && Process.alive?(stub), do: Process.exit(stub, :kill)
      Application.delete_env(:worker, :env)
    end)

    %{audio_buffer: pid}
  end

  defp stub_forwarding_process(name, target) do
    case Process.whereis(name) do
      nil ->
        pid = spawn(fn -> forward_loop(target) end)
        Process.register(pid, name)
        pid

      _ ->
        nil
    end
  end

  defp forward_loop(target) do
    receive do
      msg ->
        send(target, msg)
        forward_loop(target)
    end
  end

  defp open!(sid) do
    :ok = AudioBuffer.open_session(sid, @cid)
    # open_session broadcastet initial []
    assert_receive {:publish_status, %{"kind" => "mic_streamers", "discord_ids" => []}}, 500
  end

  # Backdatet den last_chunk_at-Eintrag eines Keys, sodass er als Ghost gilt.
  defp expire_key(pid, sid, key) do
    :sys.replace_state(pid, fn state ->
      old = System.monotonic_time(:millisecond) - 10_000
      put_in(state, [:sessions, sid, :last_chunk_at, key], old)
    end)
  end

  test "frische Streamer werden gelistet (sortiert)", %{audio_buffer: _pid} do
    sid = "s-fresh"
    open!(sid)

    AudioBuffer.append(sid, "did-b", @chunk)
    AudioBuffer.append(sid, "did-a", @chunk)

    assert AudioBuffer.streamers(sid) == ["did-a", "did-b"]
  end

  test "stale Streamer fällt aus der Liste (Recency-Filter in streamers/1)", %{
    audio_buffer: pid
  } do
    sid = "s-stale"
    open!(sid)

    AudioBuffer.append(sid, "did-a", @chunk)
    AudioBuffer.append(sid, "did-b", @chunk)
    assert AudioBuffer.streamers(sid) == ["did-a", "did-b"]

    expire_key(pid, sid, "did-a")
    assert AudioBuffer.streamers(sid) == ["did-b"]
  end

  test "Sweep broadcastet die geschrumpfte Liste wenn ein Ghost expirt", %{audio_buffer: pid} do
    sid = "s-sweep"
    open!(sid)

    AudioBuffer.append(sid, "did-a", @chunk)
    # First-Chunk-Broadcast mit ["did-a"]
    assert_receive {:publish_status, %{"kind" => "mic_streamers", "discord_ids" => ["did-a"]}}, 500

    expire_key(pid, sid, "did-a")
    send(pid, :sweep_ghosts)

    # Sweep erkennt Shrinkage → broadcastet []
    assert_receive {:publish_status, %{"kind" => "mic_streamers", "discord_ids" => []}}, 1000
  end

  test "Sweep broadcastet NICHT wenn sich nichts ändert (kein Shrink)", %{audio_buffer: pid} do
    sid = "s-nochange"
    open!(sid)

    AudioBuffer.append(sid, "did-a", @chunk)
    assert_receive {:publish_status, %{"discord_ids" => ["did-a"]}}, 500

    # frischer Streamer → Sweep darf nicht erneut broadcasten
    send(pid, :sweep_ghosts)
    refute_receive {:publish_status, %{"kind" => "mic_streamers"}}, 300
  end

  test "drop_streamer entfernt den Key sofort + broadcastet", %{audio_buffer: _pid} do
    sid = "s-drop"
    open!(sid)

    AudioBuffer.append(sid, "did-a", @chunk)
    AudioBuffer.append(sid, "did-b", @chunk)
    # Broadcasts ["did-a"] dann ["did-a","did-b"] abräumen
    assert_receive {:publish_status, %{"discord_ids" => ["did-a"]}}, 500
    assert_receive {:publish_status, %{"discord_ids" => ["did-a", "did-b"]}}, 500

    AudioBuffer.drop_streamer(sid, "did-a")
    assert_receive {:publish_status, %{"discord_ids" => ["did-b"]}}, 500
    assert AudioBuffer.streamers(sid) == ["did-b"]
  end

  test "transienter Gap: re-append nach Expire re-added den Key, File bleibt intakt (append)", %{
    audio_buffer: pid
  } do
    sid = "s-gap"
    open!(sid)

    AudioBuffer.append(sid, "did-a", @chunk)
    assert AudioBuffer.streamers(sid) == ["did-a"]

    # Datei-Pfad + Größe nach erstem Chunk
    file_path = streamer_file_path(pid, sid, "did-a")
    size1 = File.stat!(file_path).size
    assert size1 > 0

    # Key expiren → aus Presence raus
    expire_key(pid, sid, "did-a")
    assert AudioBuffer.streamers(sid) == []

    # Verspäteter Chunk → Key re-added, File wird APPENDED (nicht truncated)
    AudioBuffer.append(sid, "did-a", @chunk)
    assert AudioBuffer.streamers(sid) == ["did-a"]

    size2 = File.stat!(file_path).size
    assert size2 > size1, "File wurde truncated statt appended (#{size2} <= #{size1})"
  end

  # Liest den Writer-File-Pfad aus dem GenServer-State (writers bleiben offen
  # über den Gap hinweg — das ist der Punkt: kein Truncate).
  defp streamer_file_path(pid, sid, key) do
    state = :sys.get_state(pid)
    {_file, path} = get_in(state, [:sessions, sid, :writers, key])
    path
  end

  # Backdated last_chunk_at über die silence_alert_threshold_ms-Schwelle.
  # Sweep löst dann den :streamer_silent-Edge-Trigger aus.
  defp make_silent(pid, sid, key) do
    threshold = Worker.Settings.get(:silence_alert_threshold_ms, 300_000)

    :sys.replace_state(pid, fn state ->
      old = System.monotonic_time(:millisecond) - threshold - 1000
      put_in(state, [:sessions, sid, :last_chunk_at, key], old)
    end)
  end

  # Issue #399: server-side Silence-Watchdog. AudioBuffer.handle_info(:sweep_ghosts)
  # ruft check_silence/2 — Edge-Trigger frisch→silent + silent→recovered, kein Re-Spam.
  describe "silence-watchdog (#399)" do
    test "frisch → silent: publish_status mit kind=streamer_silent", %{audio_buffer: pid} do
      sid = "s-silent-1"
      open!(sid)

      AudioBuffer.append(sid, "did-x", @chunk)
      # Initial broadcast (frisch dazu)
      assert_receive {:publish_status, %{"kind" => "mic_streamers", "discord_ids" => ["did-x"]}},
                     500

      make_silent(pid, sid, "did-x")
      send(pid, :sweep_ghosts)

      assert_receive {:publish_status,
                      %{
                        "kind" => "streamer_silent",
                        "campaign_id" => @cid,
                        "session_id" => ^sid,
                        "discord_id" => "did-x",
                        "silent_for_ms" => silent_for
                      }},
                     500

      assert silent_for > 0
    end

    test "kein Re-Spam: zweiter Sweep ohne State-Wechsel sendet KEIN streamer_silent erneut", %{
      audio_buffer: pid
    } do
      sid = "s-silent-2"
      open!(sid)

      AudioBuffer.append(sid, "did-y", @chunk)
      assert_receive {:publish_status, %{"kind" => "mic_streamers"}}, 500

      make_silent(pid, sid, "did-y")
      send(pid, :sweep_ghosts)
      assert_receive {:publish_status, %{"kind" => "streamer_silent"}}, 500

      # zweiter Sweep ohne neuen Chunk → kein neues silent-Event
      send(pid, :sweep_ghosts)
      refute_receive {:publish_status, %{"kind" => "streamer_silent"}}, 200
    end

    test "silent → recovered: neuer Chunk löst streamer_recovered aus", %{audio_buffer: pid} do
      sid = "s-recovered"
      open!(sid)

      AudioBuffer.append(sid, "did-z", @chunk)
      assert_receive {:publish_status, %{"kind" => "mic_streamers"}}, 500

      make_silent(pid, sid, "did-z")
      send(pid, :sweep_ghosts)
      assert_receive {:publish_status, %{"kind" => "streamer_silent"}}, 500

      # Frischer Chunk → last_chunk_at = now → check_silence sieht gap < threshold
      AudioBuffer.append(sid, "did-z", @chunk)
      send(pid, :sweep_ghosts)

      assert_receive {:publish_status,
                      %{
                        "kind" => "streamer_recovered",
                        "campaign_id" => @cid,
                        "session_id" => ^sid,
                        "discord_id" => "did-z"
                      }},
                     500
    end
  end
end
