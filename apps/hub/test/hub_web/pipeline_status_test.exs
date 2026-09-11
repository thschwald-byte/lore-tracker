defmodule HubWeb.PipelineStatusTest do
  @moduledoc """
  Issue #401: per-Campaign-PubSub-Routing. Testet die Routing-Regel (`route/1`)
  + die Isolations-Garantie am PubSub-Layer (`broadcast/1` weckt nur den
  Ziel-Topic, nie fremde Kampagnen). Unique campaign_ids pro Test → async-sicher
  (kein geteilter Topic zwischen nebenläufigen Tests).

  Seit J4 (#1207) gibt es keinen Probelauf-Sammel-Topic mehr: Meldungen ohne
  campaign_id werden verworfen, `probelauf-`-Kampagnen sind gewöhnliche
  Kampagnen-Topics.
  """
  use ExUnit.Case, async: true

  alias HubWeb.PipelineStatus

  defp uid, do: System.unique_integer([:positive])

  describe "route/1" do
    test "reale campaign_id → per-Campaign-Topic" do
      assert PipelineStatus.route(%{"campaign_id" => "cid-abc"}) == "pipeline_status:cid-abc"
    end

    test "fehlende / nil campaign_id → kein Topic" do
      assert PipelineStatus.route(%{"kind" => "pipeline_stage"}) == nil
      assert PipelineStatus.route(%{"campaign_id" => nil}) == nil
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

    test "Meldung ohne campaign_id wird verworfen, weckt keinen Kampagnen-Topic" do
      a = "iso-real-#{uid()}"
      :ok = Phoenix.PubSub.subscribe(Hub.PubSub, PipelineStatus.topic(a))

      assert :ok = PipelineStatus.broadcast(%{"kind" => "pipeline_stage", "stage" => "extract"})

      refute_receive {:pipeline_status, _}
    end
  end
end
