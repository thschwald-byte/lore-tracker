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

  describe "epos_edit_start/1 — Mitglieder-Gate (:edit_epos, #1082)" do
    # Issue #1082: `:edit_epos` ist Mitglieder-Recht geworden — der Mitschnitt
    # gehört dem Tisch, nicht der Spielleitung allein. Die Schranke gilt
    # weiterhin gegen Nicht-Mitglieder (s. die Save-Tests unten).
    test "Spieler-Member darf seit #1082 in den Edit-Modus" do
      {:noreply, s} = StageEdits.epos_edit_start(socket(:spieler))
      assert s.assigns.epos_mode == :edit
      assert s.assigns.epos_draft == "Bestehendes Epos"
    end

    test "GM darf in den Edit-Modus (Draft wird befüllt)" do
      {:noreply, s} = StageEdits.epos_edit_start(socket(:spielleiter))
      assert s.assigns.epos_mode == :edit
      assert s.assigns.epos_draft == "Bestehendes Epos"
    end
  end

  describe "epos_edit_save/2 — Mitglieder-Gate (:edit_epos, #1082)" do
    test "Spieler-Member darf seit #1082 speichern" do
      {:noreply, s} = StageEdits.epos_edit_save(socket(:spieler), "Ergänzung vom Mitspieler")
      refute Map.has_key?(s.assigns.flash, "error")
    end

    test "Nicht-Member wird abgewiesen" do
      {:noreply, s} = StageEdits.epos_edit_save(socket(nil), "Fremder")
      assert s.assigns.epos_mode == :view
      assert s.assigns.flash["error"] =~ "Keine Berechtigung"
    end
  end

  # Issue #753: dieselbe Permission-Achse für per-Kapitel-Edits.
  describe "chapter_edit_* — Mitglieder-Gate (:edit_epos, #1082)" do
    defp chapter_socket(campaign_role) do
      s = socket(campaign_role)

      assigns =
        s.assigns
        |> Map.put(:epos_chapters, [%{"id" => "sess-1", "content_md" => "Kapiteltext"}])
        |> Map.put(:chapter_edit_id, nil)
        |> Map.put(:chapter_draft, "")

      %{s | assigns: assigns}
    end

    test "Spieler-Member darf seit #1082 in den Kapitel-Edit-Modus" do
      {:noreply, s} = StageEdits.chapter_edit_start(chapter_socket(:spieler), "sess-1")
      assert s.assigns.chapter_edit_id == "sess-1"
      assert s.assigns.chapter_draft == "Kapiteltext"
    end

    test "GM darf in den Kapitel-Edit-Modus (Draft aus Kapitel-Row)" do
      {:noreply, s} = StageEdits.chapter_edit_start(chapter_socket(:spielleiter), "sess-1")
      assert s.assigns.chapter_edit_id == "sess-1"
      assert s.assigns.chapter_draft == "Kapiteltext"
    end

    test "Spieler-Member-Save geht seit #1082 durch" do
      {:noreply, s} =
        StageEdits.chapter_edit_save(chapter_socket(:spieler), "sess-1", "Ergänzung")

      refute Map.has_key?(s.assigns.flash, "error")
    end

    # Die Schranke bleibt: wer nicht Mitglied ist, kommt an kein Kapitel.
    test "Nicht-Mitglied-Save wird abgewiesen (Flash, kein Publish)" do
      {:noreply, s} = StageEdits.chapter_edit_save(chapter_socket(nil), "sess-1", "Fremder")
      assert s.assigns.chapter_edit_id == nil
      assert s.assigns.flash["error"] =~ "Keine Berechtigung"
    end

    test "GM-Save auf UNBEKANNTE entry_id wird abgewiesen (kein Row-Anlegen via gecraftetem id)" do
      {:noreply, s} =
        StageEdits.chapter_edit_save(chapter_socket(:spielleiter), "boese-id", "Inject")

      assert s.assigns.flash["error"] =~ "Keine Berechtigung"
    end
  end
end
