defmodule Worker.SettingsTest do
  @moduledoc """
  Default value + round-trip tests for `Worker.Settings`. Uses Mnesia
  (bootstrapped by test_helper); not async to avoid cross-test stomping
  on the singleton worker_state table.
  """

  use ExUnit.Case, async: false

  alias Worker.Settings

  setup do
    # Wipe the worker_state table so each test sees @defaults only.
    {:atomic, :ok} = :mnesia.clear_table(Worker.Schema.Mnesia.worker_state())
    :ok
  end

  describe "defaults" do
    test "backend_stage{2,3,4} default to :local" do
      assert Settings.get(:backend_stage2) == :local
      assert Settings.get(:backend_stage3) == :local
      assert Settings.get(:backend_stage4) == :local
    end
  end

  describe "put/get round-trip" do
    test "put overrides default" do
      assert Settings.get(:model_stage2) == "qwen2.5:7b"
      :ok = Settings.put(:model_stage2, "qwen2.5:14b-instruct-q5_K_M")
      assert Settings.get(:model_stage2) == "qwen2.5:14b-instruct-q5_K_M"
    end
  end

  describe "pipeline_mode (Issue #651 Phase C)" do
    test "default ist :chain (kein Verhaltens-Change ohne expliziten Flip)" do
      assert Settings.get(:pipeline_mode) == :chain
    end

    test "lässt sich auf :wahrheitsbild flippen" do
      :ok = Settings.put(:pipeline_mode, :wahrheitsbild)
      assert Settings.get(:pipeline_mode) == :wahrheitsbild
    end
  end

  describe "grounding_method (Issue #677)" do
    test "default ist :nli" do
      assert Settings.get(:grounding_method) == :nli
    end

    test "lässt sich auf :llm_judge flippen" do
      :ok = Settings.put(:grounding_method, :llm_judge)
      assert Settings.get(:grounding_method) == :llm_judge
    end
  end
end
