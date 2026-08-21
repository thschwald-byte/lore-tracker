defmodule Worker.Recording.Pipeline.RenderArcProgressionTest do
  @moduledoc """
  Issue #838: `Render.render_arc_progression/5`. `complete_fn` injizierbar
  (Muster #842) — kein echter/gemockter LLM-HTTP-Call nötig.

  #1124: die beiden Tests zur Gate-Korpus-Trennung (Prompt sieht den Delta, das
  Gate die volle Arc-Historie) sind mit dem Render-Gate entfallen — es gibt
  keinen Gate-Korpus mehr.
  """

  # Issue #962: async: false — diese Suite schreibt den globalen Worker.Settings-
  # Singleton (z.B. :ctx_stage4); async ließe konkurrierende Reader anderer
  # Suiten flaky werden (CI-Race auf master-Pipeline 721).
  use ExUnit.Case, async: false

  alias Worker.Recording.Pipeline.Render

  defp fact(claim), do: %{"claim" => claim}

  test "Prompt-Größen-Guard feuert bei künstlich kleinem num_ctx (Backend :local)" do
    Worker.Settings.put(:backend_stage4, :local)
    on_exit(fn -> Worker.Settings.put(:backend_stage4, :local) end)
    Worker.Settings.put(:ctx_stage4, 1)
    on_exit(fn -> Worker.Settings.put(:ctx_stage4, 8192) end)

    complete_fn = fn :render, _prompt, _opts ->
      flunk("LLM darf bei Guard-Fehler nicht gerufen werden")
    end

    assert {:error, {:prompt_too_large, _est, 1}} =
             Render.render_arc_progression("X", nil, [fact("x")], %{}, complete_fn)
  end

  test "Fehler vom LLM wird durchgereicht" do
    complete_fn = fn :render, _prompt, _opts -> {:error, :upstream_error} end

    assert {:error, :upstream_error} =
             Render.render_arc_progression("X", nil, [fact("x")], %{}, complete_fn)
  end
end
