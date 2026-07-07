defmodule Mix.Tasks.Lore.Eval.SummaryTest do
  @moduledoc """
  Issue #685: Pure Helpers des `mix lore.eval.summary --mode`-Flags.

  Der Rest des Task-Bodies (`run/1`, `run_stage2!/2`, `run_wahrheitsbild!/2`)
  treibt EvalBootstrap + Ollama + Repo — nicht unit-testbar; die Integration
  läuft manuell im A/B-Vergleich.
  """

  use ExUnit.Case, async: true

  alias Mix.Tasks.Lore.Eval.Summary

  describe "parse_mode!/1" do
    test "\"chain\" → :chain (Default)" do
      assert Summary.parse_mode!("chain") == :chain
    end

    test "\"wahrheitsbild\" → :wahrheitsbild" do
      assert Summary.parse_mode!("wahrheitsbild") == :wahrheitsbild
    end

    test "unbekannter Wert raist mit Bedienungsanweisung — nicht 30 min später scheitern" do
      assert_raise Mix.Error, ~r/--mode muss `chain` oder `wahrheitsbild`/, fn ->
        Summary.parse_mode!("bogus")
      end
    end
  end

  describe "model_label_with_mode/2" do
    test ":chain lässt das Label unverändert — bestehende Baselines bleiben lesbar" do
      assert Summary.model_label_with_mode("qwen2.5:7b", :chain) == "qwen2.5:7b"
    end

    test ":wahrheitsbild hängt einen Suffix an — Baselines pro Mode getrennt" do
      assert Summary.model_label_with_mode("qwen2.5:7b", :wahrheitsbild) ==
               "qwen2.5:7b (wahrheitsbild)"

      # Auch cloud- oder tag-artige Namen bleiben unversehrt inkl. Ports/Slashes.
      assert Summary.model_label_with_mode("command-r:35b-08-2024-q4_K_M", :wahrheitsbild) ==
               "command-r:35b-08-2024-q4_K_M (wahrheitsbild)"
    end
  end
end
