defmodule Worker.LLMTest do
  @moduledoc """
  Issue #783 Phase 2: `Worker.LLM.stage_label/1` — Stage-Atom → "stageN"-String
  fürs `LLMCallBilled`-Event-Payload. Reine Funktion, kein Mnesia nötig.
  """
  use ExUnit.Case, async: true

  alias Worker.LLM

  describe "stage_label/1" do
    test "kennt alle drei Wahrheitsbild-Slots + Transcribe" do
      assert LLM.stage_label(:summary) == "stage2"
      assert LLM.stage_label(:verify) == "stage3"
      assert LLM.stage_label(:render) == "stage4"
      assert LLM.stage_label(:transcribe) == "stage1"
    end

    test "unbekanntes Atom fällt auf Atom.to_string/1 zurück" do
      assert LLM.stage_label(:irgendwas) == "irgendwas"
    end
  end
end
