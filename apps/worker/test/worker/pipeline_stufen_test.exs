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
    test "Reihenfolge entspricht dem Lauf: glätten → Jacks drei Stufen → Resümee-Jack → Geschwister" do
      # J4 (#1207): Gedächtnis, Extraktion und Verifikation statt Extraktion
      # und Prüfung. „verify“ gibt es als Stufe nicht mehr. J5 (#1209): das
      # Resümee schreibt der Resümee-Jack in drei Läufen; „render“ ist das
      # Schreiben.
      assert PipelineStufen.namen() == [
               "smooth",
               "jack_gedaechtnis",
               "extract",
               "jack_verifikation",
               "resuemee_ueberblick",
               "render",
               "resuemee_durchsicht",
               "chronik_ueberblick",
               "timeline",
               "chronik_durchsicht",
               "epos_ueberblick",
               "render_epos",
               "epos_durchsicht",
               "render_arc_progressions"
             ]
    end

    test "Position ist 1-basiert und liefert das „von N\" der Anzeige" do
      assert PipelineStufen.position("smooth") == 1
      assert PipelineStufen.position("extract") == 3
      assert PipelineStufen.position("verify") == nil
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
    test "genau die Stufen mit echter Schleife zählen" do
      zaehlbar = Enum.filter(PipelineStufen.namen(), &PipelineStufen.zaehlbar?/1)

      # J5 (#1209): Überblick (gelesene Fakten) und Durchsicht (entschiedene
      # Absätze); das Schreiben nicht — die Absatzzahl steht vorher nicht fest.
      assert zaehlbar == [
               "smooth",
               "jack_gedaechtnis",
               "extract",
               "jack_verifikation",
               "resuemee_ueberblick",
               "resuemee_durchsicht",
               "chronik_ueberblick",
               "chronik_durchsicht",
               "epos_ueberblick",
               "epos_durchsicht",
               "render_arc_progressions"
             ]
    end

    test "Jacks drei Stufen zählen Blöcke" do
      for name <- ["jack_gedaechtnis", "extract", "jack_verifikation"] do
        assert %{einheit: :bloecke, spalte: "fakten"} = PipelineStufen.finde(name)
      end
    end

    test "Einzelaufrufe tragen KEINE Einheit — 1/1 wäre eine Attrappe" do
      for name <- ["render", "timeline", "render_epos"] do
        refute PipelineStufen.zaehlbar?(name)
        assert %{einheit: nil} = PipelineStufen.finde(name)
      end
    end
  end

  describe "Epos-Jack (J6, #1210)" do
    test "alle drei Läufe sind best-effort — ein Fehlschlag beendet den Lauf nicht" do
      # Die Bogen-Progressionen folgen trotzdem, das bisherige Kapitel bleibt.
      for name <- ["epos_ueberblick", "render_epos", "epos_durchsicht"] do
        assert %{art: :best_effort, spalte: "epos"} = PipelineStufen.finde(name)
      end
    end

    test "der Überblick zählt Fakten, die Durchsicht Absätze, das Schreiben nichts" do
      assert %{einheit: :fakten} = PipelineStufen.finde("epos_ueberblick")
      assert %{einheit: nil, titel: "Epos: Schreiben"} = PipelineStufen.finde("render_epos")
      assert %{einheit: :absaetze} = PipelineStufen.finde("epos_durchsicht")
    end
  end

  describe "Jacks Stufen: pflicht oder best-effort (J4, #1207)" do
    test "ohne Gedächtnis und Extraktion endet der Lauf — Pflicht" do
      assert %{art: :pflicht} = PipelineStufen.finde("jack_gedaechtnis")
      assert %{art: :pflicht} = PipelineStufen.finde("extract")
    end

    test "eine abgebrochene Verifikation beendet ihn nicht — best-effort" do
      # Als Pflichtstufe hielte `Fortschritt` den Lauf bei ihrem Fehlschlag für
      # beendet, und das Band verschwände, während Resümee und Epos noch kommen.
      assert %{art: :best_effort} = PipelineStufen.finde("jack_verifikation")
    end
  end

  describe "Stufenmeldung (Issue #1122)" do
    alias Worker.Recording.Pipeline

    setup do
      Phoenix.PubSub.subscribe(Worker.PubSub, "pipeline_status")
      :ok
    end

    test "trägt session_id und run_id" do
      Pipeline.notify_status("c1", "jack_verifikation", "started", nil, %{
        session_id: "s1",
        run_id: "r1"
      })

      assert_receive {:pipeline_stage, p}
      assert p["session_id"] == "s1"
      assert p["run_id"] == "r1"
      assert p["stage"] == "jack_verifikation"
    end

    test "ohne Kontext fehlen die Keys, statt null zu behaupten" do
      Pipeline.notify_status("c1", "jack_verifikation", "started", nil)

      assert_receive {:pipeline_stage, p}
      refute Map.has_key?(p, "session_id")
      refute Map.has_key?(p, "run_id")
    end
  end
end
