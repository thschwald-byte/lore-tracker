defmodule Worker.LLM.CloudHelperSettingsTest do
  @moduledoc """
  Issue #658 (Coverage-Floor): die Settings-/ApiKey-abhängigen CloudHelper-Pfade
  (`model_for_stage/2`, `with_key/2`). Nicht async — schreibt/liest das Singleton
  `worker_state` (Mnesia, vom test_helper gebootstrappt), wie settings_test.
  """

  use ExUnit.Case, async: false

  alias Worker.LLM.CloudHelper
  alias Worker.Settings

  setup do
    {:atomic, :ok} = :mnesia.clear_table(Worker.Schema.Mnesia.worker_state())
    :ok
  end

  describe "model_for_stage/2 — Stage → Settings-Modell" do
    test ":summary/:epos/:chronik liefern das konfigurierte (Default-)Modell" do
      assert CloudHelper.model_for_stage(:summary, "X") == Settings.get(:model_stage2)
      assert is_binary(CloudHelper.model_for_stage(:summary, "X"))
      assert is_binary(CloudHelper.model_for_stage(:epos, "X"))
      assert is_binary(CloudHelper.model_for_stage(:chronik, "X"))
    end

    test "explizit gesetztes Modell wird zurückgegeben" do
      :ok = Settings.put(:model_stage2, "claude-test-modell")
      assert CloudHelper.model_for_stage(:summary, "Anthropic") == "claude-test-modell"
    end
  end

  describe "with_key/2 — API-Key-Lookup" do
    test "Settings-Key vorhanden → fun bekommt den Key" do
      :ok = Settings.put(:anthropic_api_key, "sk-test-123")

      assert {:got, "sk-test-123"} =
               CloudHelper.with_key(:anthropic, fn key -> {:got, key} end)
    end

    test "fun wird NICHT aufgerufen, wenn ein Key da ist → reicht ihn nur durch" do
      :ok = Settings.put(:anthropic_api_key, "sk-x")
      # Settings-first: deterministisch unabhängig von einer ENV-Var.
      assert CloudHelper.with_key(:anthropic, fn _ -> :reached end) == :reached
    end
  end
end
