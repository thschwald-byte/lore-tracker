defmodule HubWeb.CampaignLiveDeriveAssignsTest do
  @moduledoc """
  Issue #66: direkter Test von `HubWeb.CampaignLive.derive_assigns/2` — die
  geteilte Snapshot→Permission-Ableitung, die LV-Mount UND DebugController
  benutzen. Kein LiveView-Mount, kein Worker nötig; Fixtures via
  `HubWeb.Fixtures.snapshot/1` + `member/2`.
  """

  use ExUnit.Case, async: true

  alias HubWeb.CampaignLive
  alias HubWeb.Fixtures

  describe "derive_assigns/2" do
    test "globaler :admin (kein Member) hat volle GM-Rechte" do
      snap = Fixtures.snapshot(viewer_role: "admin")
      d = CampaignLive.derive_assigns(snap, "did-admin")

      assert d.role == :admin
      assert d.is_member? == false
      assert d.campaign_role == nil
      assert d.owner? == true
      assert d.can_edit_meta? == true
      assert d.can_regenerate_session? == true
      assert d.can_regenerate_campaign? == true
    end

    test "per-Campaign-:spielleiter (Member) ist GM, auch ohne globale Rolle" do
      snap =
        Fixtures.snapshot(
          viewer_role: "spieler",
          members: [Fixtures.member("did-gm", "spielleiter")]
        )

      d = CampaignLive.derive_assigns(snap, "did-gm")

      assert d.role == :spieler
      assert d.is_member? == true
      assert d.campaign_role == :spielleiter
      assert d.owner? == true
      assert d.can_edit_meta? == true
      assert d.can_regenerate_session? == true
    end

    test "Spieler-Member hat keine GM-Rechte, ist aber Member" do
      snap =
        Fixtures.snapshot(
          viewer_role: "spieler",
          members: [Fixtures.member("did-sp", "spieler")]
        )

      d = CampaignLive.derive_assigns(snap, "did-sp")

      assert d.is_member? == true
      assert d.campaign_role == :spieler
      assert d.owner? == false
      assert d.can_edit_meta? == false
      assert d.can_regenerate_session? == false
    end

    test "Nicht-Member sieht keine GM-Rechte und ist kein Member" do
      snap =
        Fixtures.snapshot(
          viewer_role: "spieler",
          members: [Fixtures.member("did-other", "spielleiter")]
        )

      d = CampaignLive.derive_assigns(snap, "did-outsider")

      assert d.is_member? == false
      assert d.campaign_role == nil
      assert d.owner? == false
      assert d.can_edit_meta? == false
    end

    test "Legacy-Member-Rollen (owner/player) werden auf spielleiter/spieler gemappt" do
      snap_owner = Fixtures.snapshot(members: [Fixtures.member("did-x", "owner")])
      assert CampaignLive.derive_assigns(snap_owner, "did-x").campaign_role == :spielleiter

      snap_player = Fixtures.snapshot(members: [Fixtures.member("did-y", "player")])
      assert CampaignLive.derive_assigns(snap_player, "did-y").campaign_role == :spieler
    end
  end
end
