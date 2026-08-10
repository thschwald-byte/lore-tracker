defmodule HubWeb.CampaignLive.LayoutToggleTabTest do
  @moduledoc """
  Issue #985 Nachtrag: `Layout.toggle_tab/2` — der generische Tab-Klick-Pfad
  (`tab_header`-Komponente → `handle_event("toggle_tab", ...)` →
  `toggle_tab/2`). Bislang KOMPLETT ungetestet — genau das ließ die fehlende
  `"discord"`-Klausel beim echten Live-Test unbemerkt durch (Stage A hatte
  nur `discord_config_edit_save/3` isoliert getestet, nie den tatsächlichen
  Tab-Öffnen-Klick über diese Funktion). Deckt jetzt ALLE bekannten Tab-IDs
  ab, nicht nur die neue — damit ein künftiger neuer Tab denselben Fehler
  nicht wiederholt, ohne dass es hier auffällt.
  """

  use ExUnit.Case, async: true

  alias HubWeb.CampaignLive.Layout

  defp socket(open_tab) do
    %Phoenix.LiveView.Socket{
      assigns:
        %{
          open_tab: open_tab,
          campaign: %{"id" => "camp-1", "flavors" => %{}},
          vocab_editing: false,
          vocab_draft: "",
          flavor_editing?: false,
          flavor_drafts: %{},
          stil_stage: nil,
          preview_segments: [],
          preview_error: nil
        }
        |> Map.put(:__changed__, %{})
    }
  end

  for {tab_str, expected_atom} <- [
        {"pipeline", :pipeline},
        {"flavor", :flavor},
        {"vocab", :vocab},
        {"kalender", :kalender},
        {"discord", :discord}
      ] do
    @tab_str tab_str
    @expected_atom expected_atom

    test "#{tab_str}: öffnet aus geschlossenem Zustand" do
      {:noreply, s} = Layout.toggle_tab(socket(nil), @tab_str)
      assert s.assigns.open_tab == @expected_atom
    end

    test "#{tab_str}: erneuter Klick auf denselben offenen Tab schließt ihn (nil)" do
      {:noreply, s} = Layout.toggle_tab(socket(@expected_atom), @tab_str)
      assert s.assigns.open_tab == nil
    end
  end

  test "unbekannter Tab-String -> nil (kein Crash, kein Fallback-Öffnen)" do
    {:noreply, s} = Layout.toggle_tab(socket(nil), "does-not-exist")
    assert s.assigns.open_tab == nil
  end
end
