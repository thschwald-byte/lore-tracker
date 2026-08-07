defmodule Worker.Recording.Pipeline.RenderArcProgressionTest do
  @moduledoc """
  Issue #838: `Render.render_arc_progression/6` — die Gate-Korpus-Trennung
  (Prompt sieht nur den Delta, das Gate die VOLLE Arc-Fakt-Historie).
  `complete_fn` injizierbar (Muster #842) — kein echter/gemockter LLM-HTTP-
  Call nötig.
  """

  use ExUnit.Case, async: true

  alias Worker.Recording.Pipeline.Render

  defp fact(claim), do: %{"claim" => claim}

  test "Gate wird gegen gate_facts geprüft, NICHT gegen new_facts (die Kern-Trennung aus Design H)" do
    # trace_fn "kennt" nur EINEN Claim-Text — der steht in gate_facts, aber
    # NICHT in new_facts. Traced der Gate-Call gegen new_facts (falscher
    # Korpus), würde das hier fälschlich flaggen.
    complete_fn = fn :render, _prompt, _opts -> {:ok, "Der Brief aus Sitzung 1 wurde geöffnet."} end
    trace_fn = fn claim, fact_claims -> claim in fact_claims end

    new_facts = [fact("Der Brief wurde geöffnet.")]
    gate_facts = [fact("Der Brief aus Sitzung 1 wurde geöffnet.")]

    assert {:ok, %{clean?: true, flagged: []}} =
             Render.render_arc_progression(
               "X",
               nil,
               new_facts,
               gate_facts,
               %{},
               complete_fn,
               trace_fn
             )
  end

  test "Gate flaggt eine erfundene Aussage, die in KEINER Fakten-Menge steht" do
    complete_fn = fn :render, _prompt, _opts -> {:ok, "Ein Drache verschlang die Burg."} end
    trace_fn = fn claim, fact_claims -> claim in fact_claims end

    new_facts = [fact("Der Brief wurde geöffnet.")]
    gate_facts = [fact("Der Brief wurde geöffnet.")]

    assert {:ok, %{clean?: false, flagged: [_ | _]}} =
             Render.render_arc_progression(
               "X",
               nil,
               new_facts,
               gate_facts,
               %{},
               complete_fn,
               trace_fn
             )
  end

  test "Prompt-Größen-Guard feuert bei künstlich kleinem num_ctx (Backend :local)" do
    Worker.Settings.put(:backend_stage4, :local)
    on_exit(fn -> Worker.Settings.put(:backend_stage4, :local) end)
    Worker.Settings.put(:ctx_stage4, 1)
    on_exit(fn -> Worker.Settings.put(:ctx_stage4, 8192) end)

    complete_fn = fn :render, _prompt, _opts -> flunk("LLM darf bei Guard-Fehler nicht gerufen werden") end

    assert {:error, {:prompt_too_large, _est, 1}} =
             Render.render_arc_progression("X", nil, [fact("x")], [fact("x")], %{}, complete_fn)
  end

  test "Fehler vom LLM wird durchgereicht" do
    complete_fn = fn :render, _prompt, _opts -> {:error, :upstream_error} end

    assert {:error, :upstream_error} =
             Render.render_arc_progression("X", nil, [fact("x")], [fact("x")], %{}, complete_fn)
  end
end
