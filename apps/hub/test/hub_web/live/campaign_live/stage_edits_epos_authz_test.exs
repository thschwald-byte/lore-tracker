defmodule HubWeb.CampaignLive.StageEditsEposAuthzTest do
  @moduledoc """
  Issue #359: Epos-Edit ist GM-only (:edit_epos). Vorher gateten epos_edit_start
  und epos_edit_save auf `is_member?` — ein Spieler-Member konnte das
  kampagnenweite Epos via gecraftetem phx-click editieren (UI-Button war zwar
  GM-only, der Server-Handler aber nicht). Bare-Socket-Transforms wie
  updates_test (kein Mount/Worker) — wir prüfen die Deny-Richtung für Nicht-GM
  auf beiden Handlern + die Allow-Richtung am publish-freien Start-Handler.
  """
  use ExUnit.Case, async: true

  alias HubWeb.CampaignLive.StageEdits

  defp socket(campaign_role) do
    %Phoenix.LiveView.Socket{
      assigns:
        %{
          current_user: %{discord_id: "did-me"},
          campaign: %{"id" => "camp-1"},
          campaign_id: "camp-1",
          flash: %{},
          perm_user: %{
            discord_id: "did-me",
            role: :spieler,
            campaign_role: campaign_role,
            is_member?: campaign_role != nil
          },
          epos: %{"content_md" => "Bestehendes Epos"},
          epos_mode: :view,
          epos_draft: ""
        }
        |> Map.put(:__changed__, %{})
    }
  end

  describe "epos_edit_start/1 — GM-Gate (:edit_epos)" do
    test "Spieler-Member darf NICHT in den Edit-Modus" do
      {:noreply, s} = StageEdits.epos_edit_start(socket(:spieler))
      assert s.assigns.epos_mode == :view
    end

    test "GM darf in den Edit-Modus (Draft wird befüllt)" do
      {:noreply, s} = StageEdits.epos_edit_start(socket(:spielleiter))
      assert s.assigns.epos_mode == :edit
      assert s.assigns.epos_draft == "Bestehendes Epos"
    end
  end

  describe "epos_edit_save/2 — GM-Gate (:edit_epos)" do
    test "Spieler-Member wird abgewiesen (Flash + kein Edit-Modus, kein Publish)" do
      {:noreply, s} = StageEdits.epos_edit_save(socket(:spieler), "Spieler-Manipulation")
      assert s.assigns.epos_mode == :view
      assert s.assigns.flash["error"] =~ "Keine Berechtigung"
    end

    test "Nicht-Member wird abgewiesen" do
      {:noreply, s} = StageEdits.epos_edit_save(socket(nil), "Fremder")
      assert s.assigns.epos_mode == :view
      assert s.assigns.flash["error"] =~ "Keine Berechtigung"
    end
  end
end
