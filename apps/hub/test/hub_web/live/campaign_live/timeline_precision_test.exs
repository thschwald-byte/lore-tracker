defmodule HubWeb.CampaignLive.TimelinePrecisionTest do
  @moduledoc "Issue #724 Slice F: Präzisions-Marker-Helfer (pur)."
  use ExUnit.Case, async: true

  alias HubWeb.CampaignLive.Components

  describe "precision_approximate?/1" do
    test "true bei grober Präzision (month/season/year/decade)" do
      for p <- ["month", "season", "year", "decade"] do
        assert Components.precision_approximate?(%{"precision" => p})
      end
    end

    test "false bei tagesgenau, nil oder Nicht-Map" do
      refute Components.precision_approximate?(%{"precision" => "day"})
      refute Components.precision_approximate?(%{"precision" => nil})
      refute Components.precision_approximate?(%{})
      refute Components.precision_approximate?(nil)
    end
  end

  describe "precision_title/1" do
    test "menschlicher Titel pro Präzision" do
      assert Components.precision_title(%{"precision" => "year"}) =~ "jahresgenau"
      assert Components.precision_title(%{"precision" => "decade"}) =~ "jahrzehntgenau"
      assert Components.precision_title(%{"precision" => "month"}) =~ "monatsgenau"
      assert Components.precision_title(%{}) =~ "ungefähr"
    end
  end
end
