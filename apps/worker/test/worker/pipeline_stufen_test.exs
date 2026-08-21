defmodule Worker.PipelineStufenTest do
  @moduledoc """
  Issue #1122: die Stufenfolge ist Daten, kein Kontrollfluss — und diese Daten
  müssen zum echten Lauf passen. Bricht die Übereinstimmung, zeigt das Laufband
  eine Stufe, die es nicht gibt (oder verschweigt eine, die läuft), ohne dass
  irgendetwas rot wird.
  """
  use ExUnit.Case, async: true

  alias Shared.PipelineStufen

  describe "Stufenfolge" do
    test "Reihenfolge entspricht dem Lauf: glätten → extrahieren → prüfen → rendern → Geschwister" do
      assert PipelineStufen.namen() == [
               "smooth",
               "extract",
               "verify",
               "render",
               "timeline",
               "render_epos",
               "render_arc_progressions"
             ]
    end

    test "Position ist 1-basiert und liefert das „von N\" der Anzeige" do
      assert PipelineStufen.position("smooth") == 1
      assert PipelineStufen.position("verify") == 3
      assert PipelineStufen.position("render_arc_progressions") == PipelineStufen.anzahl()
    end

    test "fremde Melder stören die Anzeige nicht" do
      # `stage1` (Transkription, eigener Melder in stage1_status.ex) und
      # `campaign_replay` laufen über denselben PubSub-Kanal. Sie sind keine
      # Stufen dieses Laufs — die Anzeige muss sie ignorieren können, statt
      # sich an einer nil-Position zu verschlucken.
      assert PipelineStufen.position("stage1") == nil
      assert PipelineStufen.position("campaign_replay") == nil
      refute PipelineStufen.stufe?("stage1")
    end
  end

  describe "zählbare Einheiten" do
    test "genau die vier Stufen mit echter Schleife zählen" do
      zaehlbar = Enum.filter(PipelineStufen.namen(), &PipelineStufen.zaehlbar?/1)

      assert zaehlbar == ["smooth", "extract", "verify", "render_arc_progressions"]
    end

    test "Einzelaufrufe tragen KEINE Einheit — 1/1 wäre eine Attrappe" do
      for name <- ["render", "timeline", "render_epos"] do
        refute PipelineStufen.zaehlbar?(name)
        assert %{einheit: nil} = PipelineStufen.finde(name)
      end
    end
  end

  describe "Stufenmeldung (Issue #1122)" do
    alias Worker.Recording.Pipeline

    setup do
      Phoenix.PubSub.subscribe(Worker.PubSub, "pipeline_status")
      :ok
    end

    test "trägt session_id und run_id" do
      Pipeline.notify_status("c1", "verify", "started", nil, %{
        session_id: "s1",
        run_id: "r1"
      })

      assert_receive {:pipeline_stage, p}
      assert p["session_id"] == "s1"
      assert p["run_id"] == "r1"
      assert p["stage"] == "verify"
    end

    test "ohne Kontext fehlen die Keys, statt null zu behaupten" do
      Pipeline.notify_status("c1", "verify", "started", nil)

      assert_receive {:pipeline_stage, p}
      refute Map.has_key?(p, "session_id")
      refute Map.has_key?(p, "run_id")
    end
  end
end
