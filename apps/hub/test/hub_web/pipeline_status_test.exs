defmodule HubWeb.PipelineStatusTest do
  @moduledoc """
  Issue #401: per-Campaign-PubSub-Routing. Testet die Routing-Regel (`route/1`)
  + die Isolations-Garantie am PubSub-Layer (`broadcast/1` weckt nur den
  Ziel-Topic, nie fremde Kampagnen). Unique campaign_ids pro Test → async-sicher
  (kein geteilter Topic zwischen nebenläufigen Tests).
  """
  use ExUnit.Case, async: true

  alias HubWeb.PipelineStatus

  defp uid, do: System.unique_integer([:positive])

  describe "route/1" do
    test "reale campaign_id → per-Campaign-Topic" do
      assert PipelineStatus.route(%{"campaign_id" => "cid-abc"}) == "pipeline_status:cid-abc"
    end

    test "probelauf-präfigierte campaign_id → Probelauf-Sammel-Topic" do
      assert PipelineStatus.route(%{"campaign_id" => "probelauf-xyz"}) ==
               PipelineStatus.probelauf_topic()
    end

    test "fehlende / nil campaign_id (Sweep-Progress) → Probelauf-Sammel-Topic" do
      assert PipelineStatus.route(%{"kind" => "probelauf_sweep_progress"}) ==
               PipelineStatus.probelauf_topic()

      assert PipelineStatus.route(%{"campaign_id" => nil}) == PipelineStatus.probelauf_topic()
    end
  end

  describe "topic/1" do
    test "stabil präfigiert" do
      assert PipelineStatus.topic("cid-1") == "pipeline_status:cid-1"
    end
  end

  describe "broadcast/1 — PubSub-Layer-Isolation" do
    test "broadcast weckt nur den Ziel-Topic, nie eine fremde Kampagne" do
      a = "iso-a-#{uid()}"
      b = "iso-b-#{uid()}"
      :ok = Phoenix.PubSub.subscribe(Hub.PubSub, PipelineStatus.topic(a))

      PipelineStatus.broadcast(%{"kind" => "mic_level", "campaign_id" => a, "level" => 0.5})
      assert_receive {:pipeline_status, %{"campaign_id" => ^a, "level" => 0.5}}

      # Kern-Garantie #401: ein 5-Hz-mic_level der Nachbar-Kampagne weckt uns nicht.
      PipelineStatus.broadcast(%{"kind" => "mic_level", "campaign_id" => b, "level" => 0.9})
      refute_receive {:pipeline_status, %{"campaign_id" => ^b}}
    end

    test "Probelauf-Events erreichen keinen realen Kampagnen-Topic" do
      a = "iso-real-#{uid()}"
      pl = "probelauf-#{uid()}"
      :ok = Phoenix.PubSub.subscribe(Hub.PubSub, PipelineStatus.topic(a))

      PipelineStatus.broadcast(%{"kind" => "pipeline_stage", "campaign_id" => pl, "stage" => "extract"})
      refute_receive {:pipeline_status, _}
    end
  end

  describe "broadcast/1 — Probelauf-Sammel-Topic" do
    test "probelauf-Kampagne UND campaign_id-loser Sweep-Progress landen beide dort" do
      :ok = Phoenix.PubSub.subscribe(Hub.PubSub, PipelineStatus.probelauf_topic())

      pl = "probelauf-#{uid()}"
      PipelineStatus.broadcast(%{"kind" => "pipeline_stage", "campaign_id" => pl, "stage" => "extract"})
      assert_receive {:pipeline_status, %{"campaign_id" => ^pl}}

      tag = "sweep-#{uid()}"
      PipelineStatus.broadcast(%{"kind" => "probelauf_sweep_progress", "current_model" => tag})
      assert_receive {:pipeline_status, %{"current_model" => ^tag}}
    end
  end
end
