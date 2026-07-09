defmodule Worker.Recording.AudioBufferTest do
  @moduledoc """
  Smoke tests for AudioBuffer's `open_session/2,3` (mode resolution +
  single-source recording).

  AudioBuffer is a named GenServer; we restart a fresh instance per test
  to keep session state clean.
  """

  use ExUnit.Case, async: false

  alias Worker.Recording.AudioBuffer
  alias Worker.Settings

  setup do
    {:atomic, :ok} = :mnesia.clear_table(Worker.Schema.Mnesia.worker_state())

    # AudioBuffer fan-outs hit Worker.HubClient (publish_status) which is a
    # named GenServer that doesn't exist in the test. Register a no-op
    # stub under that name so the sends don't crash.
    hub_stub = stub_named_process(Worker.HubClient)

    {:ok, pid} = AudioBuffer.start_link(:test)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal)
      if hub_stub && Process.alive?(hub_stub), do: Process.exit(hub_stub, :kill)
      Application.delete_env(:worker, :env)
    end)

    %{audio_buffer: pid}
  end

  defp stub_named_process(name) do
    case Process.whereis(name) do
      nil ->
        pid = spawn(fn -> stub_loop() end)
        Process.register(pid, name)
        pid

      _ ->
        nil
    end
  end

  defp stub_loop do
    receive do
      _ -> stub_loop()
    end
  end

  describe "open_session — modeless Container (Issue #642)" do
    test "open_session/2 wird immer akzeptiert (kein listen-gate, #418)" do
      Application.put_env(:worker, :env, :prod)
      assert :ok = AudioBuffer.open_session("test-session", "test-campaign")
    end

    test "open_session/3 akzeptiert einen Alt-mode-Arg (ignoriert, Abwärtskompat)" do
      Application.put_env(:worker, :env, :prod)
      assert :ok = AudioBuffer.open_session("ss-compat", "camp", :single_source)
    end
  end

  describe "append/4 — Per-Stream-Routing (Issue #642)" do
    setup do
      dir = Path.join(System.tmp_dir!(), "lore_audio_test_#{System.unique_integer([:positive])}")
      :ok = Settings.put(:audio_dir, dir)
      Application.put_env(:worker, :env, :prod)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir, chunk: Base.encode64("opus-bytes-here")}
    end

    test ":per_player → eine Datei pro discord_id", %{dir: dir, chunk: chunk} do
      sid = "pp-session"
      assert :ok = AudioBuffer.open_session(sid, "camp")
      AudioBuffer.append(sid, "did-alice", :per_player, chunk)
      AudioBuffer.append(sid, "did-bob", :per_player, chunk)

      # streamers/1 ist ein call → flusht die vorangegangenen casts.
      assert AudioBuffer.streamers(sid) == ["did-alice", "did-bob"]
      assert Enum.sort(session_files(dir, sid)) == ["did-alice.webm", "did-bob.webm"]
    end

    test ":multi → multi_<discord_id>.webm, eigene Spur, KEIN ':' im Namen", %{
      dir: dir,
      chunk: chunk
    } do
      sid = "multi-session"
      assert :ok = AudioBuffer.open_session(sid, "camp")
      AudioBuffer.append(sid, "did-room", :multi, chunk)

      assert AudioBuffer.streamers(sid) == ["multi_did-room"]
      files = session_files(dir, sid)
      assert files == ["multi_did-room.webm"]
      # Footgun-Check: der Routing-key wird zum Dateinamen — kein ffmpeg/whisper-
      # gefährliches ':'.
      refute Enum.any?(files, &String.contains?(&1, ":"))
    end

    test "gemischt: per_player + multi GLEICHZEITIG in einer Session", %{dir: dir, chunk: chunk} do
      sid = "mixed-session"
      assert :ok = AudioBuffer.open_session(sid, "camp")
      AudioBuffer.append(sid, "did-alice", :per_player, chunk)
      AudioBuffer.append(sid, "did-room", :multi, chunk)

      assert AudioBuffer.streamers(sid) == ["did-alice", "multi_did-room"]
      assert Enum.sort(session_files(dir, sid)) == ["did-alice.webm", "multi_did-room.webm"]
    end

    test "fehlender mic_mode (nil — alter Hub) → :per_player", %{dir: dir, chunk: chunk} do
      sid = "nil-session"
      assert :ok = AudioBuffer.open_session(sid, "camp")
      AudioBuffer.append(sid, "did-x", nil, chunk)

      assert AudioBuffer.streamers(sid) == ["did-x"]
      assert session_files(dir, sid) == ["did-x.webm"]
    end

    test "String-mic_mode vom Wire (\"multi\" / \"mic\")", %{chunk: chunk} do
      sid = "wire-session"
      assert :ok = AudioBuffer.open_session(sid, "camp")
      AudioBuffer.append(sid, "did-room", "multi", chunk)
      AudioBuffer.append(sid, "did-alice", "mic", chunk)

      assert AudioBuffer.streamers(sid) == ["did-alice", "multi_did-room"]
    end

    test "schreibt pro Chunk einen Sidecar-Eintrag (Issue #757)", %{dir: dir, chunk: chunk} do
      sid = "manifest-session"
      assert :ok = AudioBuffer.open_session(sid, "camp")
      AudioBuffer.append(sid, "did-alice", :per_player, chunk)
      AudioBuffer.append(sid, "did-alice", :per_player, chunk)
      # streamers-call flusht die vorangegangenen casts.
      _ = AudioBuffer.streamers(sid)

      session_dir = Path.join(dir, sid)
      manifest = Worker.Recording.ChunkManifest.load(session_dir, "did-alice")

      # Zwei Chunks à ~11 Bytes ("opus-bytes-here" base64-decoded). Wall-Clocks
      # aufsteigend, Bytes monoton wachsend, kein Nulleintrag.
      assert length(manifest) == 2
      [{wc1, b1}, {wc2, b2}] = manifest
      assert wc2 >= wc1
      assert b1 > 0
      assert b2 > b1
    end
  end

  describe "Issue #758 — :append statt :write bei Writer-State-Loss" do
    setup do
      dir = Path.join(System.tmp_dir!(), "lore_audio_758_#{System.unique_integer([:positive])}")
      :ok = Settings.put(:audio_dir, dir)
      Application.put_env(:worker, :env, :prod)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "verlorener Writer-State bei offener Session → Chunk appended, truncatet nicht",
         %{dir: dir, audio_buffer: pid} do
      import ExUnit.CaptureLog

      sid = "reopen-session"
      did = "did-alice"
      assert :ok = AudioBuffer.open_session(sid, "camp")

      AudioBuffer.append(sid, did, :per_player, Base.encode64("AAAA"))
      # streamers/1 (call) flusht den vorangegangenen cast → "AAAA" ist auf Platte.
      assert AudioBuffer.streamers(sid) == [did]

      # Writer-State-Loss simulieren: die Session bleibt offen, aber die
      # File-Handle-Map geht verloren (Supervisor-Restart-/Reopen-Analogon).
      :sys.replace_state(pid, fn state ->
        sessions = Map.update!(state.sessions, sid, fn sess -> %{sess | writers: %{}} end)
        %{state | sessions: sessions}
      end)

      log =
        capture_log(fn ->
          AudioBuffer.append(sid, did, :per_player, Base.encode64("BBBB"))
          # streamers/1 flusht den cast.
          AudioBuffer.streamers(sid)
        end)

      path = Path.join([dir, sid, "#{did}.webm"])
      # :append bewahrt den ersten Chunk; :write hätte "AAAA" durch "BBBB" ersetzt.
      assert File.read!(path) == "AAAABBBB"
      # State-Loss wird als Integritäts-Signal laut geloggt.
      assert log =~ "writer-state loss"
      assert log =~ "reopening existing"
    end

    test "Normalfall: erster Chunk pro Key loggt KEINE State-Loss-Warnung", %{audio_buffer: _pid} do
      import ExUnit.CaptureLog

      sid = "clean-session"
      assert :ok = AudioBuffer.open_session(sid, "camp")

      log =
        capture_log(fn ->
          AudioBuffer.append(sid, "did-fresh", :per_player, Base.encode64("AAAA"))
          AudioBuffer.streamers(sid)
        end)

      refute log =~ "writer-state loss"
    end
  end

  defp session_files(dir, sid) do
    Path.join(dir, sid)
    |> File.ls!()
    |> Enum.reject(&(&1 == "live"))
    # Issue #757: der Chunk-Arrival-Sidecar liegt neben jeder .webm — für die
    # Audio-Datei-Naming-Assertions rausfiltern (eigene Tests in
    # chunk_manifest_test.exs).
    |> Enum.reject(&String.ends_with?(&1, ".chunks.jsonl"))
  end
end
