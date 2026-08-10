defmodule Worker.Discord.OggOpusMuxerTest do
  @moduledoc """
  Issue #985 Slice 1: `Worker.Discord.OggOpusMuxer`.

  Zwei Ebenen: reine Struktur-Asserts (kein ffmpeg nötig, laufen immer) +
  ein echter ffmpeg-Decode-Roundtrip (Regressions-Guard, Muster
  `webm_concat_repro_test.exs` — self-skip mit stderr-Hinweis, wenn ffmpeg
  im PATH fehlt, z.B. auf dem Codeberg-Woodpecker-CI-Image).
  """

  use ExUnit.Case, async: true

  alias Worker.Discord.{OggOpusMuxer, TestFixtures}

  defp ffmpeg_available?, do: System.find_executable("ffmpeg") != nil

  describe "Struktur (kein ffmpeg nötig)" do
    test "Output beginnt mit einer gültigen OggS-Capture-Pattern-Seite" do
      muxed = OggOpusMuxer.mux(TestFixtures.sample_opus_packets())
      assert <<"OggS", _::binary>> = muxed
    end

    test "erste Seite ist BOS (header_type=2) und enthält den OpusHead-Packet" do
      muxed = OggOpusMuxer.mux(TestFixtures.sample_opus_packets())
      <<"OggS", 0, header_type, _rest::binary>> = muxed
      assert header_type == 2
      assert muxed =~ "OpusHead"
      assert muxed =~ "OpusTags"
    end

    test "crc32/1 reproduziert einen bekannten, gegen echtes ffmpeg-Output verifizierten Wert" do
      # Bytes einer echten von `ffmpeg -c:a libopus -f opus` erzeugten
      # OggS-Seite (Header mit genulltem CRC-Feld + 1-Byte-OpusHead-Payload-
      # Präfix) — der erwartete CRC ist der reale Wert aus dieser Datei,
      # nicht erfunden.
      # pre_skip=312 (nicht 0!) — der echte Encoder-Lookahead-Wert, den
      # ffmpegs libopus-Encoder tatsächlich schreibt. Der eigene Muxer nutzt
      # bewusst pre_skip=0 (repackt bereits fertige Discord-Pakete ohne
      # eigenen Encoder-Lookahead) — dieser Test verifiziert nur den CRC
      # gegen die REALEN Referenz-Bytes, nicht die eigene Muxer-Wahl.
      page_with_zeroed_crc =
        <<"OggS", 0, 2, 0::little-64, 4_121_499_722::little-32, 0::little-32, 0::little-32, 1, 19,
          "OpusHead", 1, 1, 312::little-16, 48_000::little-32, 0::little-signed-16, 0>>

      assert OggOpusMuxer.crc32(page_with_zeroed_crc) == 3_267_494_338
    end

    test "leere Paket-Liste erzeugt trotzdem valide Header-Seiten" do
      muxed = OggOpusMuxer.mux([])
      assert <<"OggS", _::binary>> = muxed
      assert muxed =~ "OpusHead"
    end
  end

  describe "ffmpeg-Roundtrip (Regressions-Guard)" do
    test "ffmpeg dekodiert den gemuxten Container korrekt (48kHz/Stereo, exakte Sample-Anzahl)" do
      if not ffmpeg_available?() do
        IO.puts(
          :stderr,
          "ogg_opus_muxer_test: skipping ffmpeg-Roundtrip — ffmpeg nicht im PATH"
        )
      else
        packets = TestFixtures.sample_opus_packets()
        muxed = OggOpusMuxer.mux(packets)

        dir =
          Path.join(
            System.tmp_dir!(),
            "ogg_opus_muxer_test_#{:erlang.unique_integer([:positive])}"
          )

        File.mkdir_p!(dir)
        on_exit(fn -> File.rm_rf!(dir) end)

        ogg_path = Path.join(dir, "muxed.opus")
        # Rohes PCM ohne Container/Header — vermeidet WAV-Chunk-Parsing im
        # Test (ffmpeg-WAV-Output hat variable Chunk-Reihenfolge, s.
        # AudioBridge-Moduledoc-Fund: LIST-Chunk vor data).
        pcm_path = Path.join(dir, "decoded.pcm")
        File.write!(ogg_path, muxed)

        {out, 0} =
          System.cmd("ffprobe", [
            "-v",
            "error",
            "-show_entries",
            "stream=sample_rate,channels",
            "-of",
            "csv=p=0",
            ogg_path
          ])

        assert String.trim(out) == "48000,2"

        {_out, 0} =
          System.cmd(
            "ffmpeg",
            ["-y", "-i", ogg_path, "-f", "s16le", "-ar", "48000", "-ac", "2", pcm_path],
            stderr_to_stdout: true
          )

        # 26 Pakete * 960 Samples/Paket (20ms @ 48kHz) = exakt 24960 Samples,
        # KEINE Drift — verifiziert PreSkip=0 im OpusHead wirkt wie erwartet.
        pcm = File.read!(pcm_path)
        # 2 Kanäle * 2 Bytes/Sample = 4 Bytes/Sample-Frame.
        assert div(byte_size(pcm), 4) == length(packets) * 960
      end
    end
  end
end
