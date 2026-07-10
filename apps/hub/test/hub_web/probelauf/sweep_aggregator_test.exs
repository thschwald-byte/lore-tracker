defmodule HubWeb.Probelauf.SweepAggregatorTest do
  @moduledoc """
  Phase 2a / Issue #88: Aggregations-Tests für den Sweep-Aggregator.
  Pure-function Tests gegen JSON-shaped Mock-Daten — kein Mnesia, kein LV.
  """

  use ExUnit.Case, async: true

  alias HubWeb.Probelauf.SweepAggregator

  describe "aggregate/1" do
    test "nil → nil" do
      assert SweepAggregator.aggregate(nil) == nil
    end

    test "fehlt :runs → nil" do
      assert SweepAggregator.aggregate(%{"sweep_id" => "abc"}) == nil
    end

    test "leere runs → leere rows-Liste" do
      result =
        SweepAggregator.aggregate(%{
          "sweep_id" => "s1",
          "stage" => 3,
          "default_model" => "qwen2.5:7b",
          "runs" => []
        })

      assert result.rows == []
      assert result.sweep_id == "s1"
      assert result.stage == 3
      assert result.stage_key == "stage3"
    end

    test "ein Modell mit 2 Sessions, beide erfolgreich" do
      result =
        SweepAggregator.aggregate(%{
          "sweep_id" => "s1",
          "stage" => 2,
          "default_model" => "qwen2.5:7b",
          "runs" => [
            run_with("qwen2.5:7b", [
              session_with("stage2", "ok", 5000),
              session_with("stage2", "ok", 3000)
            ])
          ]
        })

      assert [%{model: "qwen2.5:7b"} = row] = result.rows
      # median of [3000, 5000] = 4000
      assert row.median_ms == 4000
      assert row.success_rate == 1.0
      assert row.session_count == 2
      assert row.run_count == 1
    end

    test "drei Modelle nach (success ↓, median ↑) sortiert" do
      result =
        SweepAggregator.aggregate(%{
          "sweep_id" => "s1",
          "stage" => 3,
          "default_model" => "fast-but-broken",
          "runs" => [
            # fast aber failt → letzter Rang
            run_with("fast-but-broken", [
              session_with("stage3", "empty_output", 1000),
              session_with("stage3", "empty_output", 1000)
            ]),
            # langsam aber 100% — Mitte
            run_with("slow-but-solid", [
              session_with("stage3", "ok", 20_000),
              session_with("stage3", "ok", 20_000)
            ]),
            # schnell + 100% — Top
            run_with("fast-and-solid", [
              session_with("stage3", "ok", 5000),
              session_with("stage3", "ok", 5000)
            ])
          ]
        })

      assert Enum.map(result.rows, & &1.model) ==
               ["fast-and-solid", "slow-but-solid", "fast-but-broken"]
    end

    test "ignoriert die nicht-variierten Stages" do
      # stage 2 ist die variierte Stage. Andere Stages sind Noise.
      result =
        SweepAggregator.aggregate(%{
          "sweep_id" => "s1",
          "stage" => 2,
          "default_model" => "x",
          "runs" => [
            run_with("model-a", [
              %{
                "stages" => %{
                  "stage2" => %{"outcome" => "ok", "duration_ms" => 1000},
                  "stage3" => %{"outcome" => "timeout", "duration_ms" => 999_999},
                  "stage4" => %{"outcome" => "ok", "duration_ms" => 500}
                }
              }
            ])
          ]
        })

      assert [row] = result.rows
      # nur stage2 zählt — median == 1000, success_rate 100%
      assert row.median_ms == 1000
      assert row.success_rate == 1.0
    end

    test "Sessions ohne duration_ms werden bei Median ausgeklammert, zählen aber bei Success-Rate" do
      result =
        SweepAggregator.aggregate(%{
          "sweep_id" => "s1",
          "stage" => 4,
          "default_model" => "x",
          "runs" => [
            run_with("m", [
              session_with("stage4", "timeout", nil),
              session_with("stage4", "ok", 2000),
              session_with("stage4", "ok", 6000)
            ])
          ]
        })

      assert [row] = result.rows
      # median of [2000, 6000] = 4000
      assert row.median_ms == 4000
      # success_rate: 2 / 3
      assert_in_delta row.success_rate, 2 / 3, 0.001
      assert row.session_count == 3
    end

    test "Missing sweep_variant.model → unter '(unknown)' aggregiert" do
      result =
        SweepAggregator.aggregate(%{
          "sweep_id" => "s1",
          "stage" => 2,
          "default_model" => "x",
          "runs" => [
            %{"sessions" => [session_with("stage2", "ok", 1000)], "sweep_variant" => nil}
          ]
        })

      assert [%{model: "(unknown)"}] = result.rows
    end
  end

  # ─── Wahrheitsbild-Format (#786) ─────────────────────────────────

  describe "aggregate/1 — Wahrheitsbild-Runs (facts-Key)" do
    test "erkennt New-Format und liefert mode + verify_rate" do
      result =
        SweepAggregator.aggregate(%{
          "sweep_id" => "s1",
          "stage" => 2,
          "swept_key" => "model_stage2_local",
          "default_model" => "qwen2.5:7b",
          "runs" => [
            wb_run("model-a", [
              wb_session(%{"n_facts" => 10, "n_grounded" => 8, "n_verified" => 6}, "ok"),
              wb_session(%{"n_facts" => 20, "n_grounded" => 10, "n_verified" => 4}, "ok")
            ])
          ]
        })

      assert result.mode == :wahrheitsbild
      assert result.swept_key == "model_stage2_local"
      assert [row] = result.rows
      # mean(6/10, 4/20) = mean(0.6, 0.2) = 0.4
      assert_in_delta row.verify_rate, 0.4, 0.001
      assert row.success_rate == 1.0
      assert row.session_count == 2
    end

    test "success_rate hängt am render-Schritt, Median an der Schritt-Summe" do
      result =
        SweepAggregator.aggregate(%{
          "sweep_id" => "s1",
          "stage" => 2,
          "default_model" => "x",
          "runs" => [
            wb_run("m", [
              # render failed → Session zählt nicht als Erfolg.
              wb_session(%{"n_facts" => 5, "n_grounded" => 2, "n_verified" => 1}, "failed"),
              wb_session(%{"n_facts" => 5, "n_grounded" => 4, "n_verified" => 3}, "ok")
            ])
          ]
        })

      assert [row] = result.rows
      assert row.success_rate == 0.5
      # Schritt-Summe pro Session: 1000 (extract) + 500 (verify) + 200 (render)
      assert row.median_ms == 1700
    end

    test "sortiert nach verify_rate ↓ vor success/median" do
      result =
        SweepAggregator.aggregate(%{
          "sweep_id" => "s1",
          "stage" => 2,
          "default_model" => "x",
          "runs" => [
            wb_run("low-verify", [
              wb_session(%{"n_facts" => 10, "n_grounded" => 2, "n_verified" => 1}, "ok")
            ]),
            wb_run("high-verify", [
              wb_session(%{"n_facts" => 10, "n_grounded" => 9, "n_verified" => 8}, "ok")
            ])
          ]
        })

      assert Enum.map(result.rows, & &1.model) == ["high-verify", "low-verify"]
    end

    test "Sessions ohne Fakten fließen nicht in die verify_rate ein" do
      result =
        SweepAggregator.aggregate(%{
          "sweep_id" => "s1",
          "stage" => 2,
          "default_model" => "x",
          "runs" => [
            wb_run("m", [
              wb_session(%{"n_facts" => 0, "n_grounded" => 0, "n_verified" => 0}, "ok"),
              wb_session(%{"n_facts" => 10, "n_grounded" => 5, "n_verified" => 5}, "ok")
            ])
          ]
        })

      assert [row] = result.rows
      assert_in_delta row.verify_rate, 0.5, 0.001
    end

    test "has_timeout wenn irgendein Schritt getimeoutet ist" do
      session =
        wb_session(%{"n_facts" => 1, "n_grounded" => 1, "n_verified" => 1}, "ok")
        |> put_in(["stages", "render_epos"], %{"outcome" => "timeout", "duration_ms" => nil})

      result =
        SweepAggregator.aggregate(%{
          "sweep_id" => "s1",
          "stage" => 2,
          "default_model" => "x",
          "runs" => [wb_run("m", [session])]
        })

      assert [%{has_timeout: true}] = result.rows
    end
  end

  # ─── helpers ────────────────────────────────────────────────────

  defp run_with(model, sessions) do
    %{
      "sweep_variant" => %{"stage" => 2, "model" => model},
      "sessions" => sessions
    }
  end

  defp session_with(stage_key, outcome, duration_ms) do
    %{
      "stages" => %{
        stage_key => %{"outcome" => outcome, "duration_ms" => duration_ms}
      }
    }
  end

  defp wb_run(model, sessions) do
    %{
      "sweep_variant" => %{"stage" => 2, "model" => model},
      "sessions" => sessions
    }
  end

  defp wb_session(facts, render_outcome) do
    %{
      "facts" => facts,
      "stages" => %{
        "extract" => %{"outcome" => "ok", "duration_ms" => 1000},
        "verify" => %{"outcome" => "ok", "duration_ms" => 500},
        "render" => %{"outcome" => render_outcome, "duration_ms" => 200}
      }
    }
  end
end
