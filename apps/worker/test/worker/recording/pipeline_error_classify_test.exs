defmodule Worker.Recording.PipelineErrorClassifyTest do
  @moduledoc """
  Issue #589 (Cut 3): Regressionsschutz für `classify_pipeline_error/1`.

  Die Stage-Bodies wrappen ihren inneren Fehler als `{:error, {:stageN,
  inner_reason}}` (stages.ex). `with_status` reicht den *gewrappten* Reason an
  `classify_pipeline_error/1` — ohne die Unwrap-Klausel matchte keine der
  spezifischen Klauseln (die alle den INNEREN Reason erwarten), sodass JEDER
  Pipeline-Fehler auf `"other"` fiel und die ganze #68-Error-Taxonomie für
  /admin/errors tot war. Diese Tests pinnen, dass der Wrapper gestrippt wird und
  der innere Reason korrekt klassifiziert.
  """

  use ExUnit.Case, async: true

  alias Worker.Recording.Pipeline

  describe "classify_pipeline_error/1 — Stage-Wrapper-Unwrap (#589)" do
    test "gewrappter Atom-Reason wird korrekt klassifiziert statt 'other'" do
      assert Pipeline.classify_pipeline_error({:stage2, :no_key_configured}) ==
               "no_key_configured"

      assert Pipeline.classify_pipeline_error({:stage3, :timeout}) == "timeout"
      assert Pipeline.classify_pipeline_error({:stage4, :empty_chronik}) == "empty_chronik"
      assert Pipeline.classify_pipeline_error({:stage4, :upstream_auth}) == "upstream_auth"
    end

    test "gewrappter Tupel-Reason (network/http) wird korrekt klassifiziert" do
      assert Pipeline.classify_pipeline_error({:stage3, {:network_error, :econnrefused}}) ==
               "ollama_unreachable"

      assert Pipeline.classify_pipeline_error({:stage2, {:network_error, :timeout}}) ==
               "network_error"

      assert Pipeline.classify_pipeline_error({:stage4, {:upstream_error, 500, "boom"}}) ==
               "upstream_error"
    end

    test "stage4_publish-Wrapper wird ebenfalls gestrippt" do
      assert Pipeline.classify_pipeline_error({:stage4_publish, :timeout}) == "timeout"
    end
  end

  describe "classify_pipeline_error/1 — direkte (ungewrappte) Reasons" do
    test "bare Atom-Reasons" do
      assert Pipeline.classify_pipeline_error(:no_summary) == "no_summary"
      assert Pipeline.classify_pipeline_error(:spend_cap_exceeded) == "spend_cap_exceeded"
    end

    test "unbekannter Atom → Atom-String; unbekanntes Tupel → 'other'" do
      assert Pipeline.classify_pipeline_error(:irgendwas_neues) == "irgendwas_neues"
      assert Pipeline.classify_pipeline_error({:völlig, :unbekannt, :tripel}) == "other"
    end
  end
end
