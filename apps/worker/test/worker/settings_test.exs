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
    test "transcribe_mode defaults to :batch" do
      assert Settings.get(:transcribe_mode) == :batch
    end

    test "backend_stage{2,3,4} default to :local" do
      assert Settings.get(:backend_stage2) == :local
      assert Settings.get(:backend_stage3) == :local
      assert Settings.get(:backend_stage4) == :local
    end
  end

  describe "put/get round-trip" do
    test "transcribe_mode accepts :listen" do
      :ok = Settings.put(:transcribe_mode, :listen)
      assert Settings.get(:transcribe_mode) == :listen
    end

    test "transcribe_mode accepts :live" do
      :ok = Settings.put(:transcribe_mode, :live)
      assert Settings.get(:transcribe_mode) == :live
    end

    test "put overrides default" do
      assert Settings.get(:model_stage2) == "qwen2.5:7b"
      :ok = Settings.put(:model_stage2, "qwen2.5:14b-instruct-q5_K_M")
      assert Settings.get(:model_stage2) == "qwen2.5:14b-instruct-q5_K_M"
    end
  end
end
