defmodule Worker.Recording.PipelineStage3ForceRegenTest do
  @moduledoc """
  Issue #226: Stage 3 (Epos) produzierte bit-identische Outputs bei manuellem
  Re-Run, weil temperature_stage3=0.2 + nahezu identischer Prompt → LLM
  deterministisch. Fix: bei `force?: true` wird ein expliziter Re-Run-Hint
  in den Prompt eingebaut + temperature auf 0.5 hochgesetzt.

  Wir testen den Prompt-Build (private fn via Reflection), weil der
  LLM-Call selbst gegen einen echten Ollama liefe — out of scope.
  """

  use ExUnit.Case, async: true

  @summaries [
    %{
      content_md: "Romeo trifft Julia auf dem Maskenball.",
      generated_at: ~U[2026-05-26 10:00:00Z]
    },
    %{
      content_md: "Mercutio fällt im Duell mit Tybalt.",
      generated_at: ~U[2026-05-26 11:00:00Z]
    }
  ]

  test "build_epos_prompt/4 mit force?=false enthält KEINEN Re-Run-Hint" do
    prompt = build_prompt("# Bisheriger Epos\n\nText...", @summaries, %{}, false)

    refute prompt =~ "expliziter Re-Run"
    refute prompt =~ "Wiederhole NICHT"
    assert prompt =~ "Bisheriger Text"
    assert prompt =~ "Romeo trifft Julia"
  end

  test "build_epos_prompt/4 mit force?=true enthält Re-Run-Hint" do
    prompt = build_prompt("# Bisheriger Epos\n\nText...", @summaries, %{}, true)

    assert prompt =~ "expliziter Re-Run"
    assert prompt =~ "Wiederhole"
    assert prompt =~ "jüngsten Session-Inhalte"
    assert prompt =~ "Romeo trifft Julia"
  end

  test "force?=true und force?=false produzieren unterschiedliche Prompts" do
    prompt_false = build_prompt("alter Epos", @summaries, %{}, false)
    prompt_true = build_prompt("alter Epos", @summaries, %{}, true)

    refute prompt_false == prompt_true
    assert byte_size(prompt_true) > byte_size(prompt_false)
  end

  defp build_prompt(existing_md, summaries, flavors, force?) do
    apply(Worker.Recording.Pipeline, :build_epos_prompt, [
      existing_md,
      summaries,
      flavors,
      force?
    ])
  rescue
    UndefinedFunctionError ->
      flunk("expected Pipeline.build_epos_prompt/4 to be defined (defp via apply)")
  end
end
