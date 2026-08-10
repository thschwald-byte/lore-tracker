defmodule HubWeb.CampaignLive.StageEditsDiscordConfigTest do
  @moduledoc """
  Issue #985 Slice 1: discord_config_edit_save/3 nutzt Publisher.publish/2
  (Credo-Check raw_event_bridge_publish) und ist GM-only (:edit_discord_config).
  Bare-Socket-Transform-Stil, analog stage_edits_vocab_test.exs. Reine
  Metadaten-Verwaltung, keine funktionale Wirkung (der Bot existiert noch nicht).
  """
  use ExUnit.Case, async: true

  alias HubWeb.CampaignLive.StageEdits

  defp socket(campaign_role) do
    %Phoenix.LiveView.Socket{
      assigns:
        %{
          current_user: %{discord_id: "did-me"},
          perm_user: %{
            discord_id: "did-me",
            role: :spieler,
            campaign_role: campaign_role,
            is_member?: campaign_role != nil
          },
          campaign: %{"id" => "camp-1"},
          campaign_id: "camp-1",
          flash: %{},
          open_tab: "discord"
        }
        |> Map.put(:__changed__, %{})
    }
  end

  describe "discord_config_edit_save/3 — :edit_discord_config-Gate + Publisher-Pfad" do
    test "GM: Publish-Pfad schließt den Tab (open_tab: nil)" do
      {:noreply, s} = StageEdits.discord_config_edit_save(socket(:spielleiter), "111", "222")
      assert s.assigns.open_tab == nil
    end

    test "Spieler-Member wird abgewiesen (Flash, kein State-Reset)" do
      {:noreply, s} = StageEdits.discord_config_edit_save(socket(:spieler), "999", "888")
      assert s.assigns.flash["error"] =~ "Keine Berechtigung"
      assert s.assigns.open_tab == "discord"
    end

    test "Nicht-Member (campaign_role nil) wird abgewiesen" do
      {:noreply, s} = StageEdits.discord_config_edit_save(socket(nil), "999", "888")
      assert s.assigns.flash["error"] =~ "Keine Berechtigung"
    end
  end
end
