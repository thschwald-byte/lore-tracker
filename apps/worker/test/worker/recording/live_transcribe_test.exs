defmodule Worker.Recording.LiveTranscribeTest do
  @moduledoc """
  Pure-functional tests for LiveTranscribe's VAD-output parser. The full
  port + tick loop is end-to-end-tested manually until we have a fake
  whisper-cli harness; for now this locks down the parsing layer that's
  most prone to whisper.cpp-version drift.
  """

  use ExUnit.Case, async: true

  alias Worker.Recording.LiveTranscribe

  describe "parse_vad_segments/1" do
    test "parses arrow-style lines (`[ 0.000 --> 1.234 ]`)" do
      out = """
      [ 0.000 -->  1.234 ]
      [ 2.500 -->  4.700 ]
      [12.000 --> 15.500 ]
      """

      assert LiveTranscribe.parse_vad_segments(out) == [
               {0, 1234},
               {2500, 4700},
               {12_000, 15_500}
             ]
    end

    test "parses bare-pair lines (`0.000 1.234`)" do
      out = "0.000 1.234\n2.500 4.700\n"

      assert LiveTranscribe.parse_vad_segments(out) == [
               {0, 1234},
               {2500, 4700}
             ]
    end

    test "ignores garbage / non-matching lines" do
      out = """
      whisper.cpp loaded model
      [ 1.000 -->  2.000 ]
      threads: 4
      use_gpu: false
      [ 3.000 -->  4.500 ]
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

    test "rounds half-millisecond floats" do
      # 0.0005 s == 0.5 ms → rounds to 1
      assert LiveTranscribe.parse_vad_segments("0.0005 0.0015") == [{1, 2}]
    end
  end
end
