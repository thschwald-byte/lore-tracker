defmodule Worker.LLMTest do
  @moduledoc """
  Issue #783 Phase 2: `Worker.LLM.stage_label/1` — Stage-Atom → "stageN"-String
  fürs `LLMCallBilled`-Event-Payload. Reine Funktion, kein Mnesia nötig.
  """
  use ExUnit.Case, async: true

  alias Worker.LLM

  describe "stage_label/1" do
    test "kennt die drei Wahrheitsbild-LLM-Slots + Transcribe" do
      assert LLM.stage_label(:summary) == "stage2"
      assert LLM.stage_label(:render) == "stage4"
      assert LLM.stage_label(:epos) == "stage5"
      assert LLM.stage_label(:transcribe) == "stage1"
    end

    test "J4 (#1207): :verify erzeugt kein \"stage3\" mehr" do
      # Stufe 3 ist entfallen — ein Aufruf mit dem alten Atom fiele auf den
      # generischen Fallback, statt still als Stufe 3 abgerechnet zu werden.
      assert LLM.stage_label(:verify) == "verify"
    end

    test "unbekanntes Atom fällt auf Atom.to_string/1 zurück" do
      assert LLM.stage_label(:irgendwas) == "irgendwas"
    end
  end
end
