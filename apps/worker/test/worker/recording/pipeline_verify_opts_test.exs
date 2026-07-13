defmodule Worker.Recording.Pipeline.VerifyOptsTest do
  @moduledoc """
  Issue #755 (Reopen): Reader-Beweis für die Stage-3-Sampling-Knöpfe —
  `Verify.judge_opts/1` (die Opts BEIDER Judge-Calls, Grounding +
  Attribution) liest tatsächlich `temperature_stage3`/`top_p_stage3`/
  `repeat_penalty_stage3`/`ctx_stage3`. Vorher hartcodierten die Callsites
  `temperature: 0` und die UI-Knöpfe waren wirkungslos (totes Setting).

  Eigene Datei statt pipeline_verify_test.exs, weil Settings-Writes das
  Singleton `worker_state` anfassen → async: false (Muster settings_test).
  """

  use ExUnit.Case, async: false

  alias Worker.Recording.Pipeline.Verify
  alias Worker.Settings

  setup do
    {:atomic, :ok} = :mnesia.clear_table(Worker.Schema.Mnesia.worker_state())
    :ok
  end

  test "Defaults: greedy Judge (temperature 0.0, top_p 1.0, repeat_penalty 1.0, ctx 8192)" do
    opts = Verify.judge_opts(%{"type" => "object"})

    assert Keyword.get(opts, :format) == %{"type" => "object"}
    assert Keyword.get(opts, :num_ctx) == 8192
    assert Keyword.get(opts, :temperature) == 0.0
    assert Keyword.get(opts, :top_p) == 1.0
    assert Keyword.get(opts, :repeat_penalty) == 1.0
  end

  test "persistierte Stage-3-Werte wirken im Judge-Call (der UI-Knopf ist kein totes Feld mehr)" do
    Settings.put(:temperature_stage3, 0.42)
    Settings.put(:top_p_stage3, 0.63)
    Settings.put(:repeat_penalty_stage3, 1.27)
    Settings.put(:ctx_stage3, 16_384)

    opts = Verify.judge_opts(%{})

    assert Keyword.get(opts, :temperature) == 0.42
    assert Keyword.get(opts, :top_p) == 0.63
    assert Keyword.get(opts, :repeat_penalty) == 1.27
    assert Keyword.get(opts, :num_ctx) == 16_384
  end

  describe "num_predict_stage{3,4,5} — optionale Notbremse (leer = aus)" do
    alias Worker.Recording.Pipeline.Render

    test "ungesetzt → KEIN num_predict-Key (bisheriges Verhalten, terminiert selbst)" do
      refute Keyword.has_key?(Verify.judge_opts(%{}), :num_predict)
      refute Keyword.has_key?(Render.render_opts(), :num_predict)
      refute Keyword.has_key?(Render.epos_opts(), :num_predict)
    end

    test "gesetzt → Deckel wirkt im jeweiligen Call (Stage-getrennt)" do
      Settings.put(:num_predict_stage3, 2048)
      Settings.put(:num_predict_stage4, 4096)
      Settings.put(:num_predict_stage5, 20_000)

      assert Keyword.get(Verify.judge_opts(%{}), :num_predict) == 2048
      assert Keyword.get(Render.render_opts(), :num_predict) == 4096
      assert Keyword.get(Render.epos_opts(), :num_predict) == 20_000
    end

    test "Junk-Wert (0/negativ/String) → aus statt kaputter Call" do
      Settings.put(:num_predict_stage3, 0)
      Settings.put(:num_predict_stage4, -5)
      Settings.put(:num_predict_stage5, "viel")

      refute Keyword.has_key?(Verify.judge_opts(%{}), :num_predict)
      refute Keyword.has_key?(Render.render_opts(), :num_predict)
      refute Keyword.has_key?(Render.epos_opts(), :num_predict)
    end
  end
end
