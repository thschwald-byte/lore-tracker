defmodule Worker.ProbelaufCollectorTest do
  @moduledoc """
  Issue #786: Pure-Tests für die Wahrheitsbild-Collector-Logik des
  Probelaufs — Terminal-Erkennung, Frame-Recording und die Schritt-Metriken
  aus `finalize/1`. Kritischster Fall: `timeline`-failed ist NICHT terminal
  (best-effort-Geschwister — `render_epos` läuft danach trotzdem), während
  ein failed bei extract/verify/render die `with`-Kette bricht und damit
  terminal ist.
  """
  use ExUnit.Case, async: true

  alias Worker.Probelauf

  # ─── terminal?/2 ──────────────────────────────────────────────────

  describe "terminal?/2" do
    test "render_epos ended|failed ist terminal (letzter Schritt)" do
      assert Probelauf.terminal?("render_epos", "ended")
      assert Probelauf.terminal?("render_epos", "failed")
    end

    test "failed bei extract/verify/render ist terminal (bricht die with-Kette)" do
      assert Probelauf.terminal?("extract", "failed")
      assert Probelauf.terminal?("verify", "failed")
      assert Probelauf.terminal?("render", "failed")
    end

    test "timeline-failed ist NICHT terminal (best-effort, render_epos folgt)" do
      refute Probelauf.terminal?("timeline", "failed")
    end

    test "started/ended der Zwischenschritte sind nicht terminal" do
      refute Probelauf.terminal?("extract", "started")
      refute Probelauf.terminal?("extract", "ended")
      refute Probelauf.terminal?("verify", "ended")
      refute Probelauf.terminal?("render", "ended")
      refute Probelauf.terminal?("timeline", "ended")
      refute Probelauf.terminal?("render_epos", "started")
    end
  end

  # ─── classify_outcome/2 ──────────────────────────────────────────

  describe "classify_outcome/2" do
    test "ended → ok, failed → failed" do
      assert Probelauf.classify_outcome("ended", false) == :ok
      assert Probelauf.classify_outcome("failed", false) == :failed
    end

    test "fehlender Frame + Timeout → timeout, ohne Timeout → skipped" do
      assert Probelauf.classify_outcome(nil, true) == :timeout
      assert Probelauf.classify_outcome(nil, false) == :skipped
    end
  end

  # ─── record/4 + finalize/1 ───────────────────────────────────────

  defp ts(seconds), do: DateTime.add(~U[2026-07-10 12:00:00Z], seconds, :second)

  defp play(frames) do
    Enum.reduce(frames, %{}, fn {stage, status, t}, acc ->
      Probelauf.record(acc, stage, status, ts(t))
    end)
  end

  describe "finalize/1" do
    test "voller Erfolgslauf: alle 5 Schritte ok mit Dauer" do
      acc =
        play([
          {"extract", "started", 0},
          {"extract", "ended", 10},
          {"verify", "started", 10},
          {"verify", "ended", 25},
          {"render", "started", 25},
          {"render", "ended", 31},
          {"timeline", "started", 31},
          {"timeline", "ended", 32},
          {"render_epos", "started", 32},
          {"render_epos", "ended", 40}
        ])

      metrics = Probelauf.finalize(acc)

      assert Map.keys(metrics) |> Enum.sort() == Enum.sort(Probelauf.steps())
      assert metrics["extract"].outcome == "ok"
      assert metrics["extract"].duration_ms == 10_000
      assert metrics["verify"].duration_ms == 15_000
      assert metrics["render_epos"].outcome == "ok"
      assert Enum.all?(metrics, fn {_step, m} -> m.error_type == nil end)
    end

    test "extract-failed: Downstream-Schritte sind skipped, nicht timeout" do
      acc =
        play([
          {"extract", "started", 0},
          {"extract", "failed", 5}
        ])

      metrics = Probelauf.finalize(acc)

      assert metrics["extract"].outcome == "failed"
      assert metrics["verify"].outcome == "skipped"
      assert metrics["render"].outcome == "skipped"
      assert metrics["timeline"].outcome == "skipped"
      assert metrics["render_epos"].outcome == "skipped"
    end

    test "timeline-failed mit nachlaufendem render_epos: beide gemessen" do
      acc =
        play([
          {"extract", "started", 0},
          {"extract", "ended", 5},
          {"verify", "started", 5},
          {"verify", "ended", 10},
          {"render", "started", 10},
          {"render", "ended", 15},
          {"timeline", "started", 15},
          {"timeline", "failed", 16},
          {"render_epos", "started", 16},
          {"render_epos", "ended", 20}
        ])

      metrics = Probelauf.finalize(acc)

      assert metrics["timeline"].outcome == "failed"
      # Der Beweis der Terminal-Logik: render_epos hat trotz timeline-failed
      # noch Frames bekommen und ist ok.
      assert metrics["render_epos"].outcome == "ok"
      assert metrics["render_epos"].duration_ms == 4_000
    end

    test "Gap-Timeout markiert fehlende Schritte als timeout" do
      acc =
        play([
          {"extract", "started", 0},
          {"extract", "ended", 5},
          {"verify", "started", 5}
        ])
        |> Map.put(:__timeout__, true)

      metrics = Probelauf.finalize(acc)

      assert metrics["extract"].outcome == "ok"
      # verify hat nur started — kein Stop-Frame → timeout.
      assert metrics["verify"].outcome == "timeout"
      assert metrics["verify"].duration_ms == nil
      assert metrics["render"].outcome == "timeout"
    end

    test "unbekannte Status-Frames (z.B. started-only) verändern kein Outcome" do
      acc = play([{"extract", "weird_status", 0}])
      assert Probelauf.finalize(acc)["extract"].outcome == "skipped"
    end
  end
end
