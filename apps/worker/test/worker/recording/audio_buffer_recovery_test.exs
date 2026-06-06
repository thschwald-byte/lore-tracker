defmodule Worker.Recording.AudioBufferRecoveryTest do
  @moduledoc """
  Issue #466/#467: Crash-Recovery + Archivierung der Stage-1-Rohaudios.

  Getestet werden die puren/FS-Bausteine — recover_files/2 (Mode-Detection aus
  Dir-Inhalt) und archive_session_audio/1 (Verschieben vs. Löschen). Der volle
  Recovery-Scan spawnt echte whisper-Transkription und ist Integrationsebene
  (PR-Test), kein Unit-Test.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Recording.AudioBuffer

  setup do
    clear_all_tables!()
    :ok
  end

  # Issue #642: recover_files liefert nur noch {:ok, [{key, path}]} (kein
  # mode-Tag) — das Routing (per-Spieler vs. diarisiert) macht
  # start_transcribe_task über den key-Prefix (`multi_` / das alte
  # `single_source`).
  describe "recover_files/2 — Datei-Rekonstruktion" do
    test "per-discord .webm → {discord_id, path}" do
      assert {:ok, files} =
               AudioBuffer.recover_files("/x/sess1", ["alice.webm", "bob.webm"])

      assert {"alice", "/x/sess1/alice.webm"} in files
      assert {"bob", "/x/sess1/bob.webm"} in files
      assert length(files) == 2
    end

    test "multi_<did>.webm → key behält den multi_-Prefix (Routing-Signal)" do
      assert {:ok, [{"multi_room", path}]} =
               AudioBuffer.recover_files("/x/s", ["multi_room.webm"])

      assert path == "/x/s/multi_room.webm"
    end

    test "altes single_source.webm bleibt rekonstruierbar (Abwärtskompat)" do
      assert {:ok, [{"single_source", _}]} =
               AudioBuffer.recover_files("/x/s", ["single_source.webm"])
    end

    test "gemischt: per-Spieler + multi nebeneinander" do
      assert {:ok, files} =
               AudioBuffer.recover_files("/x/s", ["alice.webm", "multi_room.webm"])

      assert {"alice", "/x/s/alice.webm"} in files
      assert {"multi_room", "/x/s/multi_room.webm"} in files
    end

    test "keine .webm → :skip" do
      assert {:skip, _reason} = AudioBuffer.recover_files("/x/s", [])
    end
  end

  describe "archive_session_audio/1" do
    setup do
      base = Path.join(System.tmp_dir!(), "lore_audio_test_#{System.unique_integer([:positive])}")
      live = Path.join(base, "live")
      done = Path.join(base, "done")
      Worker.Settings.put(:audio_dir, live)
      Worker.Settings.put(:audio_done_dir, done)

      on_exit(fn ->
        File.rm_rf(base)
        Worker.Settings.put(:audio_dir, "/tmp/lore_audio")
        Worker.Settings.put(:audio_done_dir, "/tmp/lore_audio_done")
      end)

      {:ok, live: live, done: done}
    end

    test "verschiebt das Session-Dir nach audio_done_dir (Rohaudio bleibt erhalten)",
         %{live: live, done: done} do
      sdir = Path.join(live, "sess-a")
      File.mkdir_p!(sdir)
      File.write!(Path.join(sdir, "alice.webm"), "AUDIO-BYTES")

      assert :ok = AudioBuffer.archive_session_audio("sess-a")

      refute File.dir?(sdir), "Live-Dir muss nach Archivierung weg sein"
      assert File.read!(Path.join([done, "sess-a", "alice.webm"])) == "AUDIO-BYTES"
    end

    test "löscht das Dir wenn audio_done_dir = nil", %{live: live} do
      Worker.Settings.put(:audio_done_dir, nil)
      sdir = Path.join(live, "sess-b")
      File.mkdir_p!(sdir)
      File.write!(Path.join(sdir, "x.webm"), "A")

      assert :ok = AudioBuffer.archive_session_audio("sess-b")
      refute File.dir?(sdir)
    end

    test "no-op wenn das Session-Dir nicht existiert" do
      assert :ok = AudioBuffer.archive_session_audio("does-not-exist")
    end
  end
end
