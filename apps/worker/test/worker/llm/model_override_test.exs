defmodule Worker.LLM.ModelOverrideTest do
  @moduledoc """
  Issue #783 (Phase 1): `LLM.put_model_override/2` — der gemeinsame Helper für
  die `:judge_model`-/`:render_model`-Overrides (Verify + Render). Pure, kein
  Mnesia. Leerstring/Whitespace zählt als ungesetzt, weil das /settings-Formular
  `""` liefert, wenn der GM das Feld leert (= zurück aufs Stage-Modell).
  """

  use ExUnit.Case, async: true

  alias Worker.LLM

  test "gesetzter Modellname landet getrimmt als :model-Opt" do
    assert LLM.put_model_override([temperature: 0], "qwen2.5:32b") ==
             [model: "qwen2.5:32b", temperature: 0]

    assert Keyword.get(LLM.put_model_override([], "  mistral-nemo:12b "), :model) ==
             "mistral-nemo:12b"
  end

  test "nil / Leerstring / Whitespace lassen die Opts unverändert (kein :model-Key)" do
    for unset <- [nil, "", "   "] do
      opts = [temperature: 0, num_ctx: 8192]
      assert LLM.put_model_override(opts, unset) == opts
    end
  end

  test "vorhandener :model-Key wird vom Override ersetzt" do
    assert Keyword.get(LLM.put_model_override([model: "alt"], "neu"), :model) == "neu"
  end
end
