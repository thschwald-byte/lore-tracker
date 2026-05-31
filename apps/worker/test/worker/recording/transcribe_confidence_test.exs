defmodule Worker.Recording.TranscribeConfidenceTest do
  @moduledoc """
  Issue #376: Per-Token-Confidence-Aggregation aus whisper.cpp `-ojf`-JSON
  + Normalisierungs-Helper für Seed/Probelauf-Float-Werte.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Worker.Recording.Transcribe

  describe "aggregate_token_confidence/1" do
    test "berechnet mean + min über reine Wort-Tokens" do
      tokens = [
        %{"id" => 522, "p" => 0.95},
        %{"id" => 339, "p" => 0.80},
        %{"id" => 1532, "p" => 0.60}
      ]

      assert %{"mean_p" => mean, "min_p" => min} = Transcribe.aggregate_token_confidence(tokens)
      # (0.95 + 0.80 + 0.60) / 3 = 0.7833 (auf 4 Dezimalen)
      assert_in_delta mean, 0.7833, 0.0001
      assert min == 0.6
    end

    test "filtert Special-Tokens (ID >= 50257) raus, damit Mean nicht durch p≈1.0 verzerrt wird" do
      tokens = [
        # [_BEG_]
        %{"id" => 50364, "p" => 1.0},
        %{"id" => 522, "p" => 0.5},
        # [_TT_100]
        %{"id" => 50464, "p" => 1.0}
      ]

      assert %{"mean_p" => 0.5, "min_p" => 0.5} = Transcribe.aggregate_token_confidence(tokens)
    end

    test "Tokens ohne p-Key werden verworfen (NICHT auf 0.0 gezwungen — Issue-#376-Review-Bug)" do
      tokens = [
        %{"id" => 522, "p" => 0.9},
        # kein p-Key
        %{"id" => 339}
      ]

      assert %{"mean_p" => 0.9, "min_p" => 0.9} = Transcribe.aggregate_token_confidence(tokens)
    end

    test "Tokens mit p: nil werden ebenfalls verworfen" do
      tokens = [
        %{"id" => 522, "p" => 0.9},
        %{"id" => 339, "p" => nil}
      ]

      assert %{"mean_p" => 0.9, "min_p" => 0.9} = Transcribe.aggregate_token_confidence(tokens)
    end

    test "leere Liste → nil" do
      assert Transcribe.aggregate_token_confidence([]) == nil
    end

    test "Liste ausschließlich aus Special-Tokens → nil" do
      tokens = [%{"id" => 50364, "p" => 1.0}, %{"id" => 50464, "p" => 1.0}]
      assert Transcribe.aggregate_token_confidence(tokens) == nil
    end

    test "Liste ausschließlich aus Tokens ohne p → nil" do
      tokens = [%{"id" => 522}, %{"id" => 339}]
      assert Transcribe.aggregate_token_confidence(tokens) == nil
    end

    test "Nicht-Liste (z.B. nil) → nil" do
      assert Transcribe.aggregate_token_confidence(nil) == nil
      assert Transcribe.aggregate_token_confidence("garbage") == nil
    end

    test "rundet auf 4 Dezimalen" do
      tokens = [%{"id" => 1, "p" => 0.123456789}, %{"id" => 2, "p" => 0.987654321}]
      assert %{"mean_p" => mean, "min_p" => min} = Transcribe.aggregate_token_confidence(tokens)
      assert mean == 0.5556
      assert min == 0.1235
    end
  end

  describe "to_confidence_map/1" do
    test "nil → nil (keine Messung verfügbar)" do
      assert Transcribe.to_confidence_map(nil) == nil
    end

    test "Float → Map mit gleichem Wert für mean + min" do
      assert Transcribe.to_confidence_map(0.95) == %{"mean_p" => 0.95, "min_p" => 0.95}
    end

    test "Integer → Map (per Float-Coercion)" do
      assert Transcribe.to_confidence_map(1) == %{"mean_p" => 1.0, "min_p" => 1.0}
    end

    test "bereits Map → idempotent" do
      m = %{"mean_p" => 0.7, "min_p" => 0.3}
      assert Transcribe.to_confidence_map(m) == m
    end

    test "unbekannter Typ → Warning + nil (kein Crash)" do
      log =
        capture_log(fn ->
          assert Transcribe.to_confidence_map(:weird_atom) == nil
        end)

      assert log =~ "to_confidence_map"
      assert log =~ "weird_atom"
    end
  end
end
