defmodule HubWeb.CampaignLive.UpdatesTest do
  @moduledoc """
  Issue #442 (Stage 1): die payload-getriebenen In-Place-Updates. Bare-Socket-
  Transforms (kein LiveView-Mount/Worker), analog mic_live_test. Asserten dass
  nur die Ziel-Assigns wechseln + Perms via derive_assigns/2 korrekt re-derived.
  """
  use ExUnit.Case, async: true

  alias HubWeb.CampaignLive.Updates
  alias HubWeb.Fixtures

  # Socket mit der Assign-Oberfläche, die die Updates-Funktionen lesen.
  defp socket(assigns \\ %{}) do
    base = %{
      current_user: %{discord_id: "did-me"},
      campaign: %{"id" => "camp-1"},
      viewer_role: :spieler,
      members: [
        Fixtures.member("did-me", "spieler"),
        Fixtures.member("did-gm", "spielleiter"),
        Fixtures.member("did-other", "spieler")
      ],
      character_names: %{"did-me" => "Alt-Name"},
      speaker_assignments: %{"speaker:s1:0" => "did-other"}
    }

    %Phoenix.LiveView.Socket{
      assigns: Map.merge(base, assigns) |> Map.put(:__changed__, %{})
    }
  end

  defp role_of(members, did),
    do: Enum.find(members, &(&1["discord_id"] == did))["role"]

  describe "apply_member_role/2 (MemberRolePromoted)" do
    test "promotet einen anderen Member → dessen Rolle wechselt, Viewer-Perms unberührt" do
      s =
        Updates.apply_member_role(socket(), %{
          "discord_id" => "did-other",
          "new_role" => "spielleiter"
        })

      assert role_of(s.assigns.members, "did-other") == "spielleiter"
      # Viewer (did-me, spieler) bleibt ohne GM-Rechte.
      assert s.assigns.owner? == false
      assert s.assigns.can_edit_meta? == false
      assert s.assigns.is_member? == true
    end

    test "promotet den Viewer selbst → owner?/can_edit_meta? flippen auf true" do
      s =
        Updates.apply_member_role(socket(), %{
          "discord_id" => "did-me",
          "new_role" => "spielleiter"
        })

      assert role_of(s.assigns.members, "did-me") == "spielleiter"
      assert s.assigns.owner? == true
      assert s.assigns.can_edit_meta? == true
      assert s.assigns.perm_user.campaign_role == :spielleiter
    end

    test "demotet den Viewer (spielleiter → spieler) → GM-Rechte weg" do
      s0 = socket(%{viewer_role: :spieler, members: [Fixtures.member("did-me", "spielleiter")]})
      s = Updates.apply_member_role(s0, %{"discord_id" => "did-me", "new_role" => "spieler"})

      assert role_of(s.assigns.members, "did-me") == "spieler"
      assert s.assigns.owner? == false
      assert s.assigns.can_edit_meta? == false
    end

    test "fasst nur :members + Perm-Assigns an, nicht speaker_assignments/character_names" do
      s =
        Updates.apply_member_role(socket(), %{
          "discord_id" => "did-other",
          "new_role" => "spielleiter"
        })

      assert s.assigns.speaker_assignments == %{"speaker:s1:0" => "did-other"}
      assert s.assigns.character_names == %{"did-me" => "Alt-Name"}
    end
  end

  describe "apply_member_removed/2 (MemberRemoved, Nicht-Selbst)" do
    test "entfernt den Member aus der Liste" do
      s = Updates.apply_member_removed(socket(), %{"discord_id" => "did-other"})
      refute Enum.any?(s.assigns.members, &(&1["discord_id"] == "did-other"))
      assert length(s.assigns.members) == 2
    end
  end

  describe "apply_alias/2 (CampaignAliasSet)" do
    test "setzt Charaktername in character_names + am Member" do
      s =
        Updates.apply_alias(socket(), %{
          "discord_id" => "did-other",
          "character_name" => "Mercutio"
        })

      assert s.assigns.character_names["did-other"] == "Mercutio"

      assert Enum.find(s.assigns.members, &(&1["discord_id"] == "did-other"))["character_name"] ==
               "Mercutio"
    end

    test "leerer Name löscht den Eintrag" do
      s = Updates.apply_alias(socket(), %{"discord_id" => "did-me", "character_name" => ""})
      refute Map.has_key?(s.assigns.character_names, "did-me")
    end
  end

  describe "apply_speaker/2 (SpeakerAssigned)" do
    test "setzt eine Sprecher-Zuordnung" do
      s =
        Updates.apply_speaker(socket(), %{
          "speaker_label" => "speaker:s2:1",
          "discord_id" => "did-gm"
        })

      assert s.assigns.speaker_assignments["speaker:s2:1"] == "did-gm"
    end

    test "leere discord_id hebt die Zuordnung auf" do
      s =
        Updates.apply_speaker(socket(), %{"speaker_label" => "speaker:s1:0", "discord_id" => ""})

      refute Map.has_key?(s.assigns.speaker_assignments, "speaker:s1:0")
    end

    test "fasst nur speaker_assignments an, nicht :members" do
      s =
        Updates.apply_speaker(socket(), %{
          "speaker_label" => "speaker:s2:1",
          "discord_id" => "did-gm"
        })

      assert length(s.assigns.members) == 3
    end
  end
end
