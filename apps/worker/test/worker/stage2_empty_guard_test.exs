defmodule Worker.Stage2EmptyGuardTest do
  @moduledoc """
  Issue #648: Stage 2 persistiert leeres/whitespace `content_md` NICHT als
  gültiges :llm-Resümee, sondern meldet `failed` (analog Stage-4-Guard #75).

  Getestet wird die Guard-Entscheidung `Stages.finalize_stage2/3` direkt mit
  synthetischen `generated`-Tupeln — die Empty-/Error-Fälle publishen nichts,
  brauchen also weder LLM noch Mnesia. Der Erfolgs-Publish-Pfad (nicht leer →
  SessionSummaryGenerated) ist Vorbestandsverhalten und hier nicht abgedeckt.
  """

  use ExUnit.Case, async: true

  alias Worker.Recording.Pipeline.Stages

  @campaign %{id: "stage2-guard-test-campaign"}
  @sid "stage2-guard-test-session"

  test "leerer String → {:error, {:stage2, :empty_output}}, kein Publish" do
    assert {:error, {:stage2, :empty_output}} =
             Stages.finalize_stage2({:ok, "", ["u1"]}, @sid, @campaign)
  end

  test "reiner Whitespace → empty_output" do
    assert {:error, {:stage2, :empty_output}} =
             Stages.finalize_stage2({:ok, "   \n\t  ", []}, @sid, @campaign)
  end

  test "nil content_md → empty_output (kein blank?/1-Crash auf nil)" do
    assert {:error, {:stage2, :empty_output}} =
             Stages.finalize_stage2({:ok, nil, []}, @sid, @campaign)
  end

  test "Generierungs-Fehler wird als {:stage2, reason} durchgereicht" do
    assert {:error, {:stage2, :timeout}} =
             Stages.finalize_stage2({:error, :timeout}, @sid, @campaign)

    assert {:error, {:stage2, :all_chunks_failed}} =
             Stages.finalize_stage2({:error, :all_chunks_failed}, @sid, @campaign)
  end
end
