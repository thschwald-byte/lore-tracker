defmodule Worker.Discord.AudioBridgeTest do
  @moduledoc """
  Issue #985 Slice 1: `Worker.Discord.AudioBridge.build_speaker_clips/1` —
  End-to-End der vollen Pipeline (FrameBuffer-Zeitkorrektur → Ogg-Opus-Mux →
  ffmpeg-Decode → PCM-Stille-Splice → WAV → WebM/Opus). Das im Plan-Review
  geforderte Zwei-Sprecher-Pause-Szenario, real gegen ffmpeg verifiziert
  (nicht nur die reine FrameBuffer-Logik wie in `frame_buffer_test.exs`).

  Self-skip ohne ffmpeg im PATH (Muster `webm_concat_repro_test.exs` — das
  Codeberg-Woodpecker-CI-Image bringt kein ffmpeg mit).
  """

  use ExUnit.Case, async: true

  alias Worker.Discord.{AudioBridge, TestFixtures}

  defp ffmpeg_available?, do: System.find_executable("ffmpeg") != nil

  setup do
    Worker.Settings.put(:ffmpeg_bin, "ffmpeg")
    :ok
  end

  defp frame(ssrc, opus, arrival_ms), do: %{ssrc: ssrc, opus: opus, arrival_ms: arrival_ms}

  test "Zwei-Sprecher-Pause-Szenario: beide Clips korrekt zeitlich ausgerichtet" do
    if not ffmpeg_available?() do
      IO.puts(:stderr, "audio_bridge_test: skipping — ffmpeg nicht im PATH")
    else
      packets = TestFixtures.sample_opus_packets()

      # Sprecher A: Pakete 0-9 ab t=0 (200ms), Pause, Fortsetzung mit Paketen
      # 20-25 ab t=10000ms (120ms). Sprecher B: Pakete 10-19 ab t=5000ms
      # (200ms) — während A schweigt.
      a1 =
        packets
        |> Enum.slice(0, 10)
        |> Enum.with_index()
        |> Enum.map(fn {p, i} -> frame(:a, p, i * 20) end)

      b1 =
        packets
        |> Enum.slice(10, 10)
        |> Enum.with_index()
        |> Enum.map(fn {p, i} -> frame(:b, p, 5000 + i * 20) end)

      a2 =
        packets
        |> Enum.slice(20, 6)
        |> Enum.with_index()
        |> Enum.map(fn {p, i} -> frame(:a, p, 10_000 + i * 20) end)

      frames = a1 ++ b1 ++ a2

      clips = AudioBridge.build_speaker_clips(frames)

      assert %{a: {:ok, a_b64}, b: {:ok, b_b64}} = clips

      dir =
        Path.join(System.tmp_dir!(), "audio_bridge_test_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      a_duration = webm_duration_s(dir, "a", a_b64)
      b_duration = webm_duration_s(dir, "b", b_b64)

      # A: letzter Frame bei 10000+5*20=10100ms, +20ms Framedauer = 10120ms
      # Session-Ende -> ~10.12s. Toleranz für Opus/WebM-Encoding-Overhead.
      assert_in_delta a_duration, 10.12, 0.1

      # B: letzter Frame bei 5000+9*20=5180ms, +20ms = 5200ms -> ~5.2s.
      assert_in_delta b_duration, 5.2, 0.1
    end
  end

  test "Sprecher ohne jedes Frame -> kein Eintrag im Ergebnis (nur registrierte SSRCs)" do
    if ffmpeg_available?() do
      packets = TestFixtures.sample_opus_packets() |> Enum.take(2)
      frames = packets |> Enum.with_index() |> Enum.map(fn {p, i} -> frame(:only, p, i * 20) end)

      clips = AudioBridge.build_speaker_clips(frames)
      assert Map.keys(clips) == [:only]
    end
  end

  test "leere Frame-Liste -> leere Map, kein Crash" do
    assert AudioBridge.build_speaker_clips([]) == %{}
  end

  defp webm_duration_s(dir, label, base64_webm) do
    path = Path.join(dir, "#{label}.webm")
    File.write!(path, Base.decode64!(base64_webm))

    {out, 0} =
      System.cmd("ffprobe", [
        "-v",
        "error",
        "-show_entries",
        "format=duration",
        "-of",
        "csv=p=0",
        path
      ])

    out |> String.trim() |> String.to_float()
  end
end
