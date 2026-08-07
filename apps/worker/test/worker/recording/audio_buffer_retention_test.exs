defmodule Worker.Recording.AudioBufferRetentionTest do
  @moduledoc """
  Issue #934: Retention-Sidecar (`.retention.json`) + TTL-Purge + Alt-Pfad-Migration.

  Getestet werden die FS-Bausteine ohne laufenden GenServer:
  `archive_session_audio/1` (stempelt `purge_after`), `purge_expired_now/1`
  (löscht nur Deklariertes, behält frisches/sidecar-loses/aktives) und
  `move_legacy_sessions/2` (Migration).
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Recording.AudioBuffer
  alias Worker.Recording.AudioBuffer.Retention

  setup do
    clear_all_tables!()
    base = Path.join(System.tmp_dir!(), "lore_ret_test_#{System.unique_integer([:positive])}")
    live = Path.join(base, "live")
    done = Path.join(base, "done")
    Worker.Settings.put(:audio_dir, live)
    Worker.Settings.put(:audio_done_dir, done)
    Worker.Settings.put(:audio_retention_days, 14)

    on_exit(fn ->
      File.rm_rf(base)
      Worker.Settings.put(:audio_dir, "/tmp/lore_audio")
      Worker.Settings.put(:audio_done_dir, "/tmp/lore_audio_done")
      Worker.Settings.put(:audio_retention_days, 14)
    end)

    {:ok, base: base, live: live, done: done}
  end

  defp read_sidecar(dir),
    do: dir |> Path.join(".retention.json") |> File.read!() |> Jason.decode!()

  defp write_sidecar(dir, map),
    do: File.write!(Path.join(dir, ".retention.json"), Jason.encode!(map))

  defp iso(dt), do: DateTime.to_iso8601(dt)

  # Ein Done-Dir-Session mit deklariertem purge_after anlegen.
  defp mk_done(done, name, purge_after_dt) do
    dir = Path.join(done, name)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "a.webm"), "X")

    write_sidecar(dir, %{
      "created_at" => iso(DateTime.utc_now()),
      "purge_after" => iso(purge_after_dt)
    })

    dir
  end

  describe "archive_session_audio/1 stempelt purge_after" do
    test "setzt purge_after ~14 Tage in der Zukunft, created_at überlebt",
         %{live: live, done: done} do
      sdir = Path.join(live, "sess-x")
      File.mkdir_p!(sdir)
      File.write!(Path.join(sdir, "a.webm"), "BYTES")
      write_sidecar(sdir, %{"created_at" => iso(DateTime.utc_now()), "purge_after" => nil})

      assert :ok = AudioBuffer.archive_session_audio("sess-x")

      meta = read_sidecar(Path.join(done, "sess-x"))
      assert is_binary(meta["purge_after"])
      assert is_binary(meta["created_at"])
      {:ok, pa, _} = DateTime.from_iso8601(meta["purge_after"])
      assert DateTime.diff(pa, DateTime.utc_now(), :day) in 13..14
    end

    test "retention_days = 0 → kein purge_after (nie purgen)", %{live: live, done: done} do
      Worker.Settings.put(:audio_retention_days, 0)
      sdir = Path.join(live, "sess-z")
      File.mkdir_p!(sdir)
      File.write!(Path.join(sdir, "a.webm"), "B")
      write_sidecar(sdir, %{"created_at" => iso(DateTime.utc_now()), "purge_after" => nil})

      assert :ok = AudioBuffer.archive_session_audio("sess-z")
      # days=0 → stamp_purge_after ist no-op; das Sidecar bleibt mit purge_after=nil.
      refute read_sidecar(Path.join(done, "sess-z"))["purge_after"]
    end
  end

  describe "purge_expired_now/1" do
    test "löscht Abgelaufenes, behält Frisches + Sidecar-loses (flag-not-drop)",
         %{done: done} do
      File.mkdir_p!(done)
      past = mk_done(done, "old", DateTime.add(DateTime.utc_now(), -3600, :second))
      future = mk_done(done, "new", DateTime.add(DateTime.utc_now(), 3600, :second))

      nosc = Path.join(done, "nosc")
      File.mkdir_p!(nosc)
      File.write!(Path.join(nosc, "a.webm"), "X")

      assert :ok = Retention.purge_expired(done, [])

      refute File.dir?(past), "abgelaufen → weg"
      assert File.dir?(future), "frisch → bleibt"
      assert File.dir?(nosc), "sidecar-los → bleibt (flag-not-drop)"
    end

    test "aktive Session wird trotz abgelaufenem purge_after nie gepurged", %{done: done} do
      File.mkdir_p!(done)
      active = mk_done(done, "act", DateTime.add(DateTime.utc_now(), -3600, :second))

      assert :ok = Retention.purge_expired(done, ["act"])
      assert File.dir?(active), "aktive Session bleibt (Purge-vs-offener-Writer-Race)"
    end

    test "kaputtes Sidecar (unparsbares purge_after) → behalten", %{done: done} do
      dir = Path.join(done, "broken")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "a.webm"), "X")
      write_sidecar(dir, %{"purge_after" => "nicht-ein-datum"})

      assert :ok = Retention.purge_expired(done, [])
      assert File.dir?(dir), "unparsbar → behalten (flag-not-drop)"
    end
  end

  describe "move_legacy_sessions/2 (Alt-Pfad-Migration)" do
    test "verschiebt Alt-Session in den neuen Ordner", %{base: base} do
      old = Path.join(base, "oldtmp")
      new = Path.join(base, "newdir")
      s = Path.join(old, "sess-m")
      File.mkdir_p!(s)
      File.write!(Path.join(s, "a.webm"), "AUDIO")

      Retention.move_legacy_sessions(old, new)

      refute File.dir?(s), "Alt-Pfad-Session muss weg sein"
      assert File.read!(Path.join([new, "sess-m", "a.webm"])) == "AUDIO"
    end

    test "überschreibt ein bestehendes Ziel nicht", %{base: base} do
      old = Path.join(base, "o2")
      new = Path.join(base, "n2")
      File.mkdir_p!(Path.join(old, "s"))
      File.write!(Path.join([old, "s", "a.webm"]), "OLD")
      File.mkdir_p!(Path.join(new, "s"))
      File.write!(Path.join([new, "s", "a.webm"]), "KEEP")

      Retention.move_legacy_sessions(old, new)

      assert File.read!(Path.join([new, "s", "a.webm"])) == "KEEP"
    end

    test "Alt == Neu → no-op (kein Selbst-Verschieben)", %{base: base} do
      dir = Path.join(base, "same")
      File.mkdir_p!(Path.join(dir, "s"))
      File.write!(Path.join([dir, "s", "a.webm"]), "A")

      Retention.move_legacy_sessions(dir, dir)

      assert File.read!(Path.join([dir, "s", "a.webm"])) == "A"
    end
  end
end
