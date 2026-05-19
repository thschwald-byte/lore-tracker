defmodule Worker.Recording.LiveTranscribeTest do
  @moduledoc """
  Pure-functional tests for LiveTranscribe's VAD-output parser. The full
  port + tick loop is end-to-end-tested manually until we have a fake
  whisper-cli harness; for now this locks down the parsing layer that's
  most prone to whisper.cpp-version drift.

  whisper.cpp-hip 1.8.3's `whisper-vad-speech-segments` emits its
  start/end values in **10 ms frames (centiseconds)**, NOT in seconds.
  Empirical evidence: a 33.5 s recording produces a last `end = 3350.00`,
  which would be nonsense if it were seconds (≈ 56 minutes).
  """

  use ExUnit.Case, async: true

  alias Worker.Recording.LiveTranscribe

  describe "parse_vad_segments/1" do
    test "parses the real `Speech segment N: start = X, end = Y` shape" do
      out = """
      Detected 5 speech segments:
      Speech segment 0: start = 579.00, end = 694.00
      Speech segment 1: start = 714.00, end = 1043.00
      """

      # Centiseconds → ms via the parser's ×10 conversion.
      assert LiveTranscribe.parse_vad_segments(out) == [
               {5790, 6940},
               {7140, 10_430}
             ]
    end

    test "parses arrow-style lines (`[ 0.000 --> 1.234 ]`)" do
      # Older / alternative format. Still parsed as 10ms frames.
      out = """
      [ 0.000 -->  100.0 ]
      [ 250.0 -->  470.0 ]
      """

      assert LiveTranscribe.parse_vad_segments(out) == [
               {0, 1000},
               {2500, 4700}
             ]
    end

    test "parses bare-pair lines (`123.4 567.8`)" do
      out = "0.0 100.0\n250.0 470.0\n"

      assert LiveTranscribe.parse_vad_segments(out) == [
               {0, 1000},
               {2500, 4700}
             ]
    end

    test "ignores garbage / non-matching lines" do
      out = """
      whisper.cpp loaded model
      Detected 2 speech segments:
      Speech segment 0: start = 100.0, end = 200.0
      threads: 4
      use_gpu: false
      Speech segment 1: start = 300.0, end = 450.0
      done.
      """

      assert LiveTranscribe.parse_vad_segments(out) == [
               {1000, 2000},
               {3000, 4500}
             ]
    end

    test "empty input → empty list" do
      assert LiveTranscribe.parse_vad_segments("") == []
      assert LiveTranscribe.parse_vad_segments("\n\n") == []
    end
  end
end
