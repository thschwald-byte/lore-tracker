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

    test "Float → Map mit allen vier Feldern (Platzhalter-Defaults)" do
      assert Transcribe.to_confidence_map(0.95) ==
               %{"mean_p" => 0.95, "min_p" => 0.95, "low_token_fraction" => 0.0, "token_count" => 0}
    end

    test "Integer → Map (per Float-Coercion)" do
      assert Transcribe.to_confidence_map(1) ==
               %{"mean_p" => 1.0, "min_p" => 1.0, "low_token_fraction" => 0.0, "token_count" => 0}
    end

    test "Issue #381: token_count: 0 ist der Platzhalter-Marker" do
      # Hub-Side asr_uncertain?/1 nutzt das im Primary-Guard.
      assert %{"token_count" => 0} = Transcribe.to_confidence_map(0.42)
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

  describe "aggregate_token_confidence/1 — Issue #381 längen-normalisierte Felder" do
    setup do
      # Default-Threshold explizit setzen (auch der `get/2`-Default ist 0.5,
      # aber pinning macht die Tests robust gegen versehentliche andere puts).
      Worker.Settings.put(:confidence_low_token_threshold, 0.5)
      :ok
    end

    test "schreibt low_token_fraction + token_count zusätzlich zu mean+min" do
      tokens = [
        %{"id" => 1, "p" => 0.9},
        %{"id" => 2, "p" => 0.8},
        %{"id" => 3, "p" => 0.3},
        %{"id" => 4, "p" => 0.2}
      ]

      result = Transcribe.aggregate_token_confidence(tokens)

      assert %{
               "mean_p" => mean,
               "min_p" => 0.2,
               "low_token_fraction" => 0.5,
               "token_count" => 4
             } = result

      assert_in_delta mean, 0.55, 0.001
    end

    test "low_token_fraction = 0.0 wenn alle Tokens über Schwelle" do
      tokens = [%{"id" => 1, "p" => 0.9}, %{"id" => 2, "p" => 0.7}]
      assert %{"low_token_fraction" => +0.0, "token_count" => 2} =
               Transcribe.aggregate_token_confidence(tokens)
    end

    test "low_token_fraction = 1.0 wenn alle Tokens unter Schwelle" do
      tokens = [%{"id" => 1, "p" => 0.1}, %{"id" => 2, "p" => 0.3}]
      assert %{"low_token_fraction" => 1.0, "token_count" => 2} =
               Transcribe.aggregate_token_confidence(tokens)
    end

    test "Per-Token-Schwellwert via Settings veränderbar" do
      tokens = [%{"id" => 1, "p" => 0.4}, %{"id" => 2, "p" => 0.6}]

      # Default 0.5: ein Token darunter → fraction 0.5
      assert %{"low_token_fraction" => 0.5} = Transcribe.aggregate_token_confidence(tokens)

      # Threshold auf 0.3 hochgesetzt … äh runter, dann fällt kein Token mehr drunter
      Worker.Settings.put(:confidence_low_token_threshold, 0.3)
      assert %{"low_token_fraction" => +0.0} = Transcribe.aggregate_token_confidence(tokens)

      # Threshold auf 0.7 → beide Tokens drunter
      Worker.Settings.put(:confidence_low_token_threshold, 0.7)
      assert %{"low_token_fraction" => 1.0} = Transcribe.aggregate_token_confidence(tokens)
    end

    test "token_count zählt nur real Tokens (nach Special-Token-Filter)" do
      tokens = [
        # Special-Token, raus
        %{"id" => 50364, "p" => 1.0},
        %{"id" => 1, "p" => 0.9},
        %{"id" => 2, "p" => 0.4}
      ]

      assert %{"token_count" => 2, "low_token_fraction" => 0.5} =
               Transcribe.aggregate_token_confidence(tokens)
    end
  end
end
