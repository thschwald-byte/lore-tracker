defmodule Worker.LLM.CloudHelperSettingsTest do
  @moduledoc """
  Issue #658 (Coverage-Floor): die Settings-/ApiKey-abhängigen CloudHelper-Pfade
  (`model_for_stage/3`, `with_key/2`). Nicht async — schreibt/liest das Singleton
  `worker_state` (Mnesia, vom test_helper gebootstrappt), wie settings_test.
  """

  use ExUnit.Case, async: false

  alias Worker.LLM.CloudHelper
  alias Worker.Settings

  setup do
    {:atomic, :ok} = :mnesia.clear_table(Worker.Schema.Mnesia.worker_state())
    :ok
  end

  describe "model_for_stage/3 — Stage → pro-Backend-Modell (#451, #786 nur :summary)" do
    test ":summary liefert das gesetzte pro-Backend-Modell" do
      :ok = Settings.put(:model_stage2_anthropic, "claude-3-5-sonnet")

      assert CloudHelper.model_for_stage(:summary, :anthropic, "X") == "claude-3-5-sonnet"
    end

    test ":epos/:chronik sind entfernt (#786) → klares Raise statt stiller Lookup" do
      assert_raise RuntimeError, ~r/kein Stage-Mapping/, fn ->
        CloudHelper.model_for_stage(:epos, :openai, "X")
      end
    end

    test "kein pro-Backend-Key gesetzt → fail-loud (kein Legacy-Fallback mehr, #784)" do
      # Legacy `model_stage2` ist entfernt — auch ein alter Wert im Store zählt
      # nicht mehr, weil der Key nicht in known_keys steht und model_for/2 ihn
      # gar nicht mehr liest. Ohne pro-Backend-Key: fail-loud.
      assert_raise RuntimeError, ~r/kein Modell für :summary gesetzt/, fn ->
        CloudHelper.model_for_stage(:summary, :anthropic, "Anthropic")
      end
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
