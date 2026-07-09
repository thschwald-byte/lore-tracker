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

  describe "pipeline_mode (Issue #651 Phase C, Default-Flip 2026-07-08)" do
    test "default ist :wahrheitsbild (Flip nach Free-Seattle-Real-Lauf + Tom-OK)" do
      assert Settings.get(:pipeline_mode) == :wahrheitsbild
    end

    test "lässt sich auf :chain (Legacy-Kette) zurückstellen" do
      :ok = Settings.put(:pipeline_mode, :chain)
      assert Settings.get(:pipeline_mode) == :chain
    end
  end

  describe "grounding_method (Issue #677, Default-Flip #675)" do
    test "default ist :llm_judge" do
      assert Settings.get(:grounding_method) == :llm_judge
    end

    test "lässt sich auf :nli zurückstellen" do
      :ok = Settings.put(:grounding_method, :nli)
      assert Settings.get(:grounding_method) == :nli
    end
  end

  describe "model_for/2 — pro-Backend-Auflösung (#451 Track C)" do
    test "frische Installation: local löst auf den Bootstrap-Default auf" do
      assert Settings.model_for(2, :local) == "qwen2.5:7b"
      assert Settings.model_for(3, :local) == "qwen2.5:7b"
      assert Settings.model_for(4, :local) == "qwen2.5:7b"
    end

    test "persistierter pro-Backend-Key gewinnt über alles" do
      :ok = Settings.put(:model_stage2, "legacy-modell")
      :ok = Settings.put(:model_stage2_local, "per-backend-modell")
      assert Settings.model_for(2, :local) == "per-backend-modell"
    end

    test "persistierter Legacy-Key gewinnt über den pro-Backend-DEFAULT (Bestandsworker)" do
      # Bestandsworker: hat vor Track C model_stage2 auf command-r gestellt,
      # pro-Backend-Key nie berührt. Der local-Default ("qwen2.5:7b") darf den
      # persistierten Legacy-Wert NICHT verdecken.
      :ok = Settings.put(:model_stage2, "command-r")
      assert Settings.model_for(2, :local) == "command-r"
    end

    test "Cloud-Backend ohne alles → Legacy-Default (nie nil bei frischem Worker)" do
      assert Settings.model_for(2, :anthropic) == "qwen2.5:7b"
    end

    test "Cloud-Backend mit gesetztem pro-Backend-Key" do
      :ok = Settings.put(:model_stage3_google, "gemini-2.5-flash")
      assert Settings.model_for(3, :google) == "gemini-2.5-flash"
      # andere Backends unberührt
      assert Settings.model_for(3, :anthropic) == "qwen2.5:7b"
    end

    test "String-Backend wird normalisiert; leerer String zählt als ungesetzt" do
      :ok = Settings.put(:model_stage2_openai, "")
      :ok = Settings.put(:model_stage2, "fallback-modell")
      assert Settings.model_for(2, "openai") == "fallback-modell"
    end

    test "unbekanntes Backend → Legacy-Kette" do
      :ok = Settings.put(:model_stage2, "x")
      assert Settings.model_for(2, :bundled) == "x"
    end
  end

  describe "model_key/2 — gewinnender Schreib-Key (#451 Track C)" do
    test "bekanntes Backend → pro-Backend-Key (atom + string)" do
      assert Settings.model_key(2, :local) == :model_stage2_local
      assert Settings.model_key(4, "google") == :model_stage4_google
    end

    test "unbekanntes Backend → Legacy-Key" do
      assert Settings.model_key(3, :bundled) == :model_stage3
      assert Settings.model_key(3, nil) == :model_stage3
    end
  end
end
