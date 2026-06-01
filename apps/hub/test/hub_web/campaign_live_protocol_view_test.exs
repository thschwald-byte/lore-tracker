defmodule HubWeb.CampaignLiveProtocolViewTest do
  @moduledoc """
  Issue #394: Anzeige-Filter der Protokoll-Spalte — batch + live unabhängig
  an/aus (beide/eine/keine).
  """

  use ExUnit.Case, async: true

  alias HubWeb.CampaignLive

  defp u(status), do: %{"status" => status, "text" => "x"}

  describe "show_utt?/3" do
    test "nur batch an: confirmed/edited sichtbar, live versteckt" do
      assert CampaignLive.show_utt?(u("confirmed"), true, false)
      assert CampaignLive.show_utt?(u("edited"), true, false)
      refute CampaignLive.show_utt?(u("live"), true, false)
    end

    test "nur live an: live sichtbar, batch versteckt" do
      assert CampaignLive.show_utt?(u("live"), false, true)
      refute CampaignLive.show_utt?(u("confirmed"), false, true)
    end

    test "beide an: alles sichtbar" do
      for status <- ["live", "confirmed", "edited", "manual", "pending"] do
        assert CampaignLive.show_utt?(u(status), true, true)
      end
    end

    test "beide aus: nichts sichtbar" do
      for status <- ["live", "confirmed", "edited", "manual", "pending"] do
        refute CampaignLive.show_utt?(u(status), false, false)
      end
    end
  end
end
