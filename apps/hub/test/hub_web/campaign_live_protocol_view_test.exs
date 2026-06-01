defmodule HubWeb.CampaignLiveProtocolViewTest do
  @moduledoc """
  Issue #394: Anzeige-Filter der Protokoll-Spalte (live | batch).
  """

  use ExUnit.Case, async: true

  alias HubWeb.CampaignLive

  defp u(status), do: %{"status" => status, "text" => "x"}

  describe "protocol_view_match?/2" do
    test ":live zeigt nur live" do
      assert CampaignLive.protocol_view_match?(u("live"), :live)
      refute CampaignLive.protocol_view_match?(u("confirmed"), :live)
      refute CampaignLive.protocol_view_match?(u("edited"), :live)
    end

    test ":batch zeigt alles außer live" do
      refute CampaignLive.protocol_view_match?(u("live"), :batch)
      assert CampaignLive.protocol_view_match?(u("confirmed"), :batch)
      assert CampaignLive.protocol_view_match?(u("edited"), :batch)
      assert CampaignLive.protocol_view_match?(u("manual"), :batch)
    end

    test "live + batch sind komplementär (eine Utterance landet in genau einer View)" do
      for status <- ["live", "confirmed", "edited", "manual", "pending"] do
        in_live = CampaignLive.protocol_view_match?(u(status), :live)
        in_batch = CampaignLive.protocol_view_match?(u(status), :batch)
        assert in_live != in_batch, "#{status} muss in genau einer View sein"
      end
    end
  end
end
