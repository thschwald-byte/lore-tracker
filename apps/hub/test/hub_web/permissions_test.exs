defmodule HubWeb.PermissionsTest do
  @moduledoc """
  Issue #34 + Issue #140: Rule-Table-Test für `HubWeb.Permissions`.

  Mit dem Wechsel auf per-Campaign-Rollen (#140) entscheidet ausschließlich
  `user.campaign_role` (`:spielleiter` | `:spieler` | `nil`) über GM-Rechte
  in einer Kampagne; die globale `:role` ist nur noch für `:create_campaign`
  (`:spielleiter`) und `:view_admin` (`:admin`) relevant. `:admin` ist
  weiterhin Universal-Allow.
  """

  use ExUnit.Case, async: true

  alias HubWeb.Fixtures
  alias HubWeb.Permissions

  # Issue #66: User-Maps via HubWeb.Fixtures.user/1 statt inline (is_member?
  # wird aus campaign_role abgeleitet; can?/3 matcht ohnehin nur role +
  # campaign_role, die Zusatz-Keys sind verhaltensneutral).

  # globale Rolle :admin → darf alles.
  @admin Fixtures.user(discord_id: "did-admin", role: :admin)

  # per-Campaign-Spielleiter (Ersteller oder befördert): GM-Rechte für DIESE Campaign.
  @sl_this_campaign Fixtures.user(
                      discord_id: "did-sl",
                      role: :spielleiter,
                      campaign_role: :spielleiter
                    )

  # Globaler :spielleiter, aber Spieler in dieser Campaign — kein GM-Recht.
  @sl_global_only Fixtures.user(
                    discord_id: "did-sl-other",
                    role: :spielleiter,
                    campaign_role: :spieler
                  )

  # Globaler :spielleiter, kein Member dieser Campaign — kein GM-Recht.
  @sl_no_member Fixtures.user(discord_id: "did-sl-out", role: :spielleiter, campaign_role: nil)

  # Globaler :spieler, Spieler-Member dieser Campaign.
  @spieler_member Fixtures.user(discord_id: "did-sp", role: :spieler, campaign_role: :spieler)

  # Globaler :spieler, kein Member dieser Campaign.
  @spieler_outsider Fixtures.user(discord_id: "did-out", role: :spieler, campaign_role: nil)

  @camp %{id: "c-1"}

  describe "0-arg actions" do
    test ":create_campaign — admin + globaler spielleiter ja, spieler nein" do
      assert Permissions.can?(@admin, :create_campaign)
      assert Permissions.can?(@sl_global_only, :create_campaign)
      refute Permissions.can?(@spieler_member, :create_campaign)
    end

    test ":view_admin — nur admin" do
      assert Permissions.can?(@admin, :view_admin)
      refute Permissions.can?(@sl_this_campaign, :view_admin)
      refute Permissions.can?(@spieler_member, :view_admin)
    end
  end

  describe "GM-Actions (per-Campaign :spielleiter only)" do
    for action <- [
          :delete_campaign,
          :edit_summary,
          :edit_epos,
          :edit_chronik,
          :edit_flavor,
          :add_utterance,
          :invite_to_campaign,
          :regenerate_session,
          :regenerate_campaign,
          :promote_member,
          :demote_member,
          # Issue #724 Slice F: Review-Queue-Fakt-Korrektur.
          :set_fact_date
        ] do
      @action action

      test "#{action}: admin ja, per-Campaign-:spielleiter ja, alles andere nein" do
        assert Permissions.can?(@admin, @action, @camp)
        assert Permissions.can?(@sl_this_campaign, @action, @camp)
        # Globaler :spielleiter ohne per-Campaign-Rolle = kein GM
        refute Permissions.can?(@sl_global_only, @action, @camp)
        refute Permissions.can?(@sl_no_member, @action, @camp)
        refute Permissions.can?(@spieler_member, @action, @camp)
        refute Permissions.can?(@spieler_outsider, @action, @camp)
      end
    end
  end

  describe "Member-Actions (jeder Member)" do
    for action <- [:join_mic, :set_own_alias] do
      @action action

      test "#{action}: admin ja, jeder Member (egal Rolle) ja, non-Member nein" do
        assert Permissions.can?(@admin, @action, @camp)
        assert Permissions.can?(@sl_this_campaign, @action, @camp)
        assert Permissions.can?(@sl_global_only, @action, @camp)
        assert Permissions.can?(@spieler_member, @action, @camp)
        refute Permissions.can?(@sl_no_member, @action, @camp)
        refute Permissions.can?(@spieler_outsider, @action, @camp)
      end
    end
  end

  describe "Utterance-Actions" do
    @own_utt %{discord_id: "did-sp"}
    @other_utt %{discord_id: "did-other"}

    test ":edit_utterance / :delete_utterance — admin + GM überall, Spieler nur eigene" do
      for action <- [:edit_utterance, :delete_utterance] do
        # Admin überall
        assert Permissions.can?(@admin, action, @own_utt, @camp)
        assert Permissions.can?(@admin, action, @other_utt, @camp)
        # Per-Campaign-:spielleiter überall
        assert Permissions.can?(@sl_this_campaign, action, @own_utt, @camp)
        assert Permissions.can?(@sl_this_campaign, action, @other_utt, @camp)
        # Spieler-Member: nur eigene
        assert Permissions.can?(@spieler_member, action, @own_utt, @camp)
        refute Permissions.can?(@spieler_member, action, @other_utt, @camp)
        # Outsider: gar nicht
        refute Permissions.can?(@spieler_outsider, action, @own_utt, @camp)
      end
    end
  end

  describe "unbekannte Actions" do
    test "unknown 0-arg action → false (außer admin)" do
      refute Permissions.can?(@spieler_member, :nuke_universe)
      assert Permissions.can?(@admin, :nuke_universe)
    end

    test "unknown 1-arg action → false (außer admin)" do
      refute Permissions.can?(@spieler_member, :wat, @camp)
      assert Permissions.can?(@admin, :wat, @camp)
    end
  end

  describe "Issue #140-Symptom: Vulpes' Bug" do
    test "Campaign-Ersteller mit per-Campaign-:spielleiter sieht GM-Buttons enabled" do
      # Vulpes hat die Campaign erstellt → Materializer hat sie als
      # :spielleiter-Member eingetragen. Ihre per-Campaign-Rolle ist
      # daher :spielleiter, egal welche globale Rolle sie hat.
      vulpes = %{discord_id: "vulpes", role: :spieler, campaign_role: :spielleiter}

      for action <- [
            :invite_to_campaign,
            :regenerate_session,
            :edit_summary,
            :edit_chronik,
            :add_utterance
          ] do
        assert Permissions.can?(vulpes, action, @camp),
               "Vulpes sollte #{action} dürfen — sie ist per-Campaign-Spielleiter"
      end
    end

    test "Spieler-Member sieht GM-Buttons disabled (Regression)" do
      spieler = %{discord_id: "did-sp", role: :spieler, campaign_role: :spieler}

      for action <- [
            :invite_to_campaign,
            :regenerate_session,
            :edit_summary,
            :edit_chronik,
            :add_utterance
          ] do
        refute Permissions.can?(spieler, action, @camp),
               "Spieler-Member darf #{action} nicht — kein GM-Privileg"
      end
    end
  end

  describe "admin_perm_user/3 (#720 — Admin-LV-perm_user an einer Stelle)" do
    test "baut den Shape aus User + SidebarContext-Rolle" do
      pu = Permissions.admin_perm_user(%{discord_id: "d1"}, :admin)
      assert pu == %{discord_id: "d1", role: :admin, is_member?: false}
      assert Permissions.can?(pu, :view_admin)
    end

    test "fehlende Rolle → :spieler (Least-Privilege) → view_admin verweigert" do
      pu = Permissions.admin_perm_user(%{discord_id: "d1"}, nil)
      assert pu.role == :spieler
      refute Permissions.can?(pu, :view_admin)
    end

    test "is_member?-Option (Probelauf-Sonderfall)" do
      assert Permissions.admin_perm_user(%{discord_id: "d1"}, :admin, is_member?: true).is_member?
    end
  end
end
