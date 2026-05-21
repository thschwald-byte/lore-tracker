defmodule HubWeb.PermissionsTest do
  @moduledoc """
  Issue #34: Rule-Table-Test für `HubWeb.Permissions`.
  Eine Matrix aller drei Rollen × allen Actions, plus die context-
  sensitiven Spezial-Fälle (owner-check, eigene-utterance-check).
  """

  use ExUnit.Case, async: true

  alias HubWeb.Permissions

  @admin %{discord_id: "did-admin", role: :admin, is_member?: true}
  @spielleiter_owner %{discord_id: "did-sl", role: :spielleiter, is_member?: true}
  @spielleiter_other %{discord_id: "did-sl-other", role: :spielleiter, is_member?: false}
  @spieler_member %{discord_id: "did-sp", role: :spieler, is_member?: true}
  @spieler_outsider %{discord_id: "did-sp-outsider", role: :spieler, is_member?: false}

  @camp %{owner_discord_id: "did-sl"}

  describe "0-arg actions" do
    test ":create_campaign — admin + spielleiter ja, spieler nein" do
      assert Permissions.can?(@admin, :create_campaign)
      assert Permissions.can?(@spielleiter_other, :create_campaign)
      refute Permissions.can?(@spieler_member, :create_campaign)
    end

    test ":view_admin — nur admin" do
      assert Permissions.can?(@admin, :view_admin)
      refute Permissions.can?(@spielleiter_owner, :view_admin)
      refute Permissions.can?(@spieler_member, :view_admin)
    end
  end

  describe "campaign-scoped actions (owner-or-admin only)" do
    for action <- [:delete_campaign, :edit_summary, :edit_epos, :edit_chronik, :edit_flavor, :add_utterance] do
      @action action

      test "#{action}: admin überall, spielleiter-owner ja, spielleiter-other nein, spieler nein" do
        assert Permissions.can?(@admin, @action, @camp)
        assert Permissions.can?(@spielleiter_owner, @action, @camp)
        refute Permissions.can?(@spielleiter_other, @action, @camp)
        refute Permissions.can?(@spieler_member, @action, @camp)
        refute Permissions.can?(@spieler_outsider, @action, @camp)
      end
    end
  end

  describe "campaign-scoped actions (member only)" do
    for action <- [:join_mic, :set_own_alias] do
      @action action

      test "#{action}: admin überall, member ja, non-member nein" do
        assert Permissions.can?(@admin, @action, @camp)
        assert Permissions.can?(@spielleiter_owner, @action, @camp)
        assert Permissions.can?(@spieler_member, @action, @camp)
        refute Permissions.can?(@spielleiter_other, @action, @camp)
        refute Permissions.can?(@spieler_outsider, @action, @camp)
      end
    end
  end

  describe "utterance-scoped actions" do
    @own_utt %{discord_id: "did-sp"}
    @other_utt %{discord_id: "did-sp-other"}

    test ":edit_utterance — admin überall, spielleiter-owner überall, spieler nur eigene" do
      for action <- [:edit_utterance, :delete_utterance] do
        assert Permissions.can?(@admin, action, @own_utt, @camp)
        assert Permissions.can?(@admin, action, @other_utt, @camp)
        assert Permissions.can?(@spielleiter_owner, action, @own_utt, @camp)
        assert Permissions.can?(@spielleiter_owner, action, @other_utt, @camp)
        assert Permissions.can?(@spieler_member, action, @own_utt, @camp)
        refute Permissions.can?(@spieler_member, action, @other_utt, @camp)
        refute Permissions.can?(@spielleiter_other, action, @own_utt, @camp)
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

  describe "Pipeline-Trigger (Issue #104)" do
    test ":regenerate_session — Owner JA, Spielleiter-Member JA, Spieler NEIN" do
      # Campaign-Owner (egal welche globale Rolle)
      assert Permissions.can?(@spielleiter_owner, :regenerate_session, @camp)
      # Globaler Admin sieht alles
      assert Permissions.can?(@admin, :regenerate_session, @camp)
      # Spielleiter mit Membership in fremder Campaign — darf
      spielleiter_member = %{discord_id: "sl-helper", role: :spielleiter, is_member?: true}
      assert Permissions.can?(spielleiter_member, :regenerate_session, @camp)
      # Spielleiter ohne Membership — nicht
      refute Permissions.can?(@spielleiter_other, :regenerate_session, @camp)
      # Spieler-Member — nicht (Pipeline-Trigger ist GM-Privileg)
      refute Permissions.can?(@spieler_member, :regenerate_session, @camp)
      # Outsider — niemals
      refute Permissions.can?(@spieler_outsider, :regenerate_session, @camp)
    end

    test ":regenerate_campaign — Spielleiter-Member JA, Owner-ohne-SL-Rolle NEIN" do
      # Globaler Admin: ja
      assert Permissions.can?(@admin, :regenerate_campaign, @camp)
      # Spielleiter mit Membership (auch wenn nicht Owner): ja
      spielleiter_member = %{discord_id: "sl-helper", role: :spielleiter, is_member?: true}
      assert Permissions.can?(spielleiter_member, :regenerate_campaign, @camp)
      # Spielleiter-Owner ist auch Member-of-own-campaign: ja
      assert Permissions.can?(@spielleiter_owner, :regenerate_campaign, @camp)
      # Spielleiter ohne Membership: nein
      refute Permissions.can?(@spielleiter_other, :regenerate_campaign, @camp)
      # Spieler-Member: nein (campaign-weiter Re-Run = teure Operation, GM-only)
      refute Permissions.can?(@spieler_member, :regenerate_campaign, @camp)
    end
  end
end
