defmodule HubWeb.CampaignLive.StageEditsVocabTest do
  @moduledoc """
  Issue #613: vocab_edit_save nutzt Publisher.publish/2 statt rohem
  EventBridge.publish — bei :no_worker_online Flash statt stillem Datenverlust.
  Bare-Socket-Transform-Stil (kein Mount/Worker), analog stage_edits_epos_authz.
  Geprüft: GM-Allow schließt das Akkordeon (Publish-Pfad), Nicht-GM wird
  abgewiesen (Flash, kein State-Reset).
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
          vocab_editing: true,
          vocab_draft: "Entwurf",
          open_tab: "vocab"
        }
        |> Map.put(:__changed__, %{})
    }
  end

  describe "vocab_edit_save/2 — :edit_vocab-Gate + Publisher-Pfad" do
    test "GM: Publish-Pfad schließt das Akkordeon (vocab_editing: false, open_tab: nil)" do
      {:noreply, s} = StageEdits.vocab_edit_save(socket(:spielleiter), "Neuer Hinweis")
      assert s.assigns.vocab_editing == false
      assert s.assigns.open_tab == nil
    end

    test "Spieler-Member wird abgewiesen (Flash, kein State-Reset)" do
      {:noreply, s} = StageEdits.vocab_edit_save(socket(:spieler), "Manipulation")
      assert s.assigns.flash["error"] =~ "Keine Berechtigung"
      assert s.assigns.vocab_editing == true
    end
  end
end
