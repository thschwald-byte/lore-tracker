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

  describe "model_for_stage/3 — Stage → pro-Backend-Modell (#783 Phase 2; seit J6 nur Slot 4)" do
    # Die beiden Raise-Tests rufen über apply/3: ein Literal-Aufruf mit einem
    # Stage-Atom, das die Funktion nie annimmt, ist genau das, wovor der
    # Typprüfer warnt — hier ist er der Zweck des Tests.
    test "J4 (#1207): :summary hat kein Cloud-Mapping mehr (fest lokal) → klares Raise" do
      assert_raise RuntimeError, ~r/kein Stage-Mapping für :summary/, fn ->
        apply(CloudHelper, :model_for_stage, [:summary, :anthropic, "X"])
      end
    end

    test ":render liefert das Stage-4-Modell" do
      :ok = Settings.put(:model_stage4_anthropic, "render-modell")

      assert CloudHelper.model_for_stage(:render, :anthropic, "X") == "render-modell"
    end

    test ":render liefert das Stage-4-Modell auch auf einem anderen Backend" do
      :ok = Settings.put(:model_stage4_openai, "render-modell")

      assert CloudHelper.model_for_stage(:render, :openai, "X") == "render-modell"
    end

    test ":chronik ist entfernt (#786) → klares Raise statt stiller Lookup" do
      assert_raise RuntimeError, ~r/kein Stage-Mapping/, fn ->
        apply(CloudHelper, :model_for_stage, [:chronik, :openai, "X"])
      end
    end

    test "J6 (#1210): :epos (Stage 5) ist entfernt → klares Raise statt stiller Lookup" do
      # Das Kapitel schreibt der Epos-Jack; ein Stage-5-Modell gibt es nicht mehr.
      assert_raise RuntimeError, ~r/kein Stage-Mapping für :epos/, fn ->
        apply(CloudHelper, :model_for_stage, [:epos, :openai, "X"])
      end
    end

    test "kein pro-Backend-Key gesetzt → fail-loud (kein Legacy-Fallback mehr, #784)" do
      # Legacy `model_stage{n}` ist entfernt — auch ein alter Wert im Store zählt
      # nicht mehr, weil der Key nicht in known_keys steht und model_for/2 ihn
      # gar nicht mehr liest. Ohne pro-Backend-Key: fail-loud.
      assert_raise RuntimeError, ~r/kein Modell für :render gesetzt/, fn ->
        CloudHelper.model_for_stage(:render, :anthropic, "Anthropic")
      end
    end

    test "kein pro-Backend-Key für Stage 4 gesetzt → fail-loud mit Stage-4-Setting-Name" do
      assert_raise RuntimeError, ~r/model_stage4_openai/, fn ->
        CloudHelper.model_for_stage(:render, :openai, "OpenAI")
      end
    end
  end

  describe "run_completion/5 — :model-Override (#783)" do
    test "opts[:model] schlägt den Stage-Lookup und erreicht den Backend-Call" do
      # Kein model_stage4_anthropic gesetzt → ohne Override würde model_for_stage
      # raisen. do_call_fn meldet das Modell zurück, das der Backend-Call sähe.
      # :upstream_auth = kein Retry, kein Spend-Event.
      :ok = Settings.put(:anthropic_api_key, "sk-test")
      me = self()

      result =
        CloudHelper.run_completion(
          :anthropic,
          "Anthropic",
          "prompt",
          [stage: :render, model: "claude-override"],
          fn _key, model, _prompt, _max, _temp, _fmt ->
            send(me, {:called_with, model})
            {:error, :upstream_auth}
          end
        )

      assert result == {:error, :upstream_auth}
      assert_received {:called_with, "claude-override"}
    end

    test "ohne opts[:model] bleibt der Stage-Lookup fail-loud" do
      assert_raise RuntimeError, ~r/kein Modell für :render gesetzt/, fn ->
        CloudHelper.run_completion(
          :anthropic,
          "Anthropic",
          "prompt",
          [stage: :render],
          fn _, _, _, _, _, _ -> flunk("do_call_fn erreicht") end
        )
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
