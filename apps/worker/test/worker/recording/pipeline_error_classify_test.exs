defmodule Worker.Recording.PipelineErrorClassifyTest do
  @moduledoc """
  Issue #589 (Cut 3): Regressionsschutz für `classify_pipeline_error/1`.

  Die Wahrheitsbild-Schritte wrappen ihren inneren Fehler als
  `{:error, {tag, inner_reason}}` (tag ∈ extraction/verify/render/timeline/
  render_epos). `with_status` reicht den *gewrappten* Reason an
  `classify_pipeline_error/1` — ohne die Unwrap-Klausel matchte keine der
  spezifischen Klauseln (die alle den INNEREN Reason erwarten), sodass JEDER
  Pipeline-Fehler auf `"other"` fiel und die ganze #68-Error-Taxonomie für
  /admin/errors tot war. Diese Tests pinnen, dass der Wrapper gestrippt wird und
  der innere Reason korrekt klassifiziert. (#786: die Chain-Wrapper stageN sind
  mit der Chain entfernt.)
  """

  use ExUnit.Case, async: true

  alias Worker.Recording.Pipeline

  describe "classify_pipeline_error/1 — Schritt-Wrapper-Unwrap (#589/#716)" do
    test "gewrappter Atom-Reason wird korrekt klassifiziert statt 'other'" do
      assert Pipeline.classify_pipeline_error({:extraction, :no_key_configured}) ==
               "no_key_configured"

      assert Pipeline.classify_pipeline_error({:verify, :timeout}) == "timeout"
      assert Pipeline.classify_pipeline_error({:verify, :sidecar_offline}) == "sidecar_offline"

      assert Pipeline.classify_pipeline_error({:render, :no_verified_facts}) ==
               "no_verified_facts"

      assert Pipeline.classify_pipeline_error({:render_epos, :upstream_auth}) == "upstream_auth"
    end

    test "gewrappter Tupel-Reason (network/http) wird korrekt klassifiziert" do
      assert Pipeline.classify_pipeline_error({:extraction, {:network_error, :econnrefused}}) ==
               "ollama_unreachable"

      assert Pipeline.classify_pipeline_error({:render, {:network_error, :timeout}}) ==
               "network_error"

      assert Pipeline.classify_pipeline_error({:timeline, {:upstream_error, 500, "boom"}}) ==
               "upstream_error"
    end

    test "leere Extraktion hat ihre eigene Klasse (VOR dem generischen Strip)" do
      assert Pipeline.classify_pipeline_error({:extraction, :empty}) == "extraction_empty"
    end
  end

  describe "classify_pipeline_error/1 — direkte (ungewrappte) Reasons" do
    test "bare Atom-Reasons" do
      assert Pipeline.classify_pipeline_error(:no_facts) == "no_facts"
      assert Pipeline.classify_pipeline_error(:all_chunks_failed) == "all_chunks_failed"
      assert Pipeline.classify_pipeline_error(:spend_cap_exceeded) == "spend_cap_exceeded"
    end

    test "unbekannter Atom → Atom-String; unbekanntes Tupel → 'other'" do
      assert Pipeline.classify_pipeline_error(:irgendwas_neues) == "irgendwas_neues"
      assert Pipeline.classify_pipeline_error({:völlig, :unbekannt, :tripel}) == "other"
    end

    test "historische Chain-Klassen fallen auf den Atom-String-Fallback (keine Sonderklausel mehr)" do
      # Alte PipelineErrorLogged-Rows behalten ihre Strings; NEUE Fehler dieser
      # Form entstehen nicht mehr — der Fallback hält das Verhalten stabil.
      assert Pipeline.classify_pipeline_error(:empty_chronik) == "empty_chronik"
      assert Pipeline.classify_pipeline_error(:no_summary) == "no_summary"
    end
  end
end
