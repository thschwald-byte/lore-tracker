defmodule HubWeb.CampaignLive.MembersComponentTest do
  @moduledoc """
  Issue #445: Mitspieler-Bereich als erstes LiveComponent des Hubs.

  Zwei Achsen:
  - **Flash-Bridge** (`HubWeb.CampaignLive.Members.flash/3`): im LiveComponent-
    Socket (`@myself` gesetzt) ist `put_flash/3` verboten → Self-Message
    `{:lc_flash, …}` an den Parent-LV. Im LiveView-Socket (kein `@myself`) der
    direkte `put_flash`. Bare-Socket-Transforms wie im updates_test — kein Mount.
  - **Rendering** via `render_component/2`: Pillen, Owner-Invite-Button,
    GM-Aktionen im offenen Popup.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias HubWeb.CampaignLive.{Members, MembersComponent}

  @members [
    %{"discord_id" => "111", "role" => "spielleiter"},
    %{"discord_id" => "222", "role" => "spieler"}
  ]
  @users %{
    "111" => %{"display_name" => "Erzähler"},
    "222" => %{"display_name" => "Bob"}
  }

  # Bare Socket. `myself: _` → LiveComponent-Kontext; ohne → LiveView-Kontext.
  defp socket(opts) do
    base = %{
      current_user: %{discord_id: "111"},
      campaign: %{"id" => "c1"},
      campaign_id: "c1",
      users: @users,
      character_names: %{},
      members: @members,
      can_edit_meta?: Keyword.get(opts, :can_edit_meta?, false),
      perm_user: %{
        discord_id: "111",
        role: :spieler,
        campaign_role: Keyword.get(opts, :campaign_role, nil),
        is_member?: Keyword.get(opts, :campaign_role, nil) != nil
      },
      member_popup_open_for: "222",
      flash: %{}
    }

    assigns = if opts[:component], do: Map.put(base, :myself, 1), else: base

    %Phoenix.LiveView.Socket{assigns: Map.put(assigns, :__changed__, %{})}
  end

  describe "Flash-Bridge: LiveComponent-Kontext (@myself gesetzt)" do
    test "Deny-Flash wird als {:lc_flash, …}-Self-Message gebridgt, nicht put_flash" do
      # Spieler ohne Promote-Recht → role_change verweigert mit Flash.
      {:noreply, s} = Members.promote(socket(component: true, campaign_role: nil), "222")

      assert_received {:lc_flash, :error, msg}
      assert msg =~ "Rollen ändern"
      # put_flash darf NICHT gelaufen sein — flash bleibt leer.
      assert s.assigns.flash == %{}
    end

    test "letzter Spielleiter entfernen → Fehler gebridgt, Popup zu" do
      {:noreply, s} = Members.remove_confirm(socket(component: true, can_edit_meta?: true), "111")

      assert_received {:lc_flash, :error, msg}
      assert msg =~ "letzte Spielleiter"
      assert s.assigns.member_popup_open_for == nil
      assert s.assigns.flash == %{}
    end
  end

  describe "Flash-Bridge: LiveView-Kontext (kein @myself)" do
    test "Deny-Flash landet via put_flash im Socket, keine Self-Message" do
      {:noreply, s} = Members.promote(socket(component: false, campaign_role: nil), "222")

      assert s.assigns.flash["error"] =~ "Rollen ändern"
      refute_received {:lc_flash, _, _}
    end
  end

  describe "handle_event delegiert an Members" do
    test "open_member_popup setzt member_popup_open_for" do
      s = %Phoenix.LiveView.Socket{
        assigns: %{member_popup_open_for: nil, __changed__: %{}}
      }

      {:noreply, s} =
        MembersComponent.handle_event("open_member_popup", %{"discord_id" => "222"}, s)

      assert s.assigns.member_popup_open_for == "222"
    end
  end

  describe "render_component" do
    defp render_with(opts) do
      render_component(MembersComponent,
        id: "campaign-members",
        members: @members,
        users: @users,
        character_names: %{},
        current_user: %{discord_id: "111"},
        campaign: %{"id" => "c1"},
        campaign_id: "c1",
        perm_user: %{discord_id: "111", role: :admin, campaign_role: :spielleiter},
        owner?: Keyword.get(opts, :owner?, false),
        can_edit_meta?: Keyword.get(opts, :can_edit_meta?, false),
        member_popup_open_for: Keyword.get(opts, :popup, nil),
        alias_mode: :view,
        alias_draft: ""
      )
    end

    test "rendert Mitspieler-Pillen mit Anzeigenamen" do
      html = render_with([])
      assert html =~ "Mitspieler"
      assert html =~ "Erzähler"
      assert html =~ "Bob"
    end

    test "Owner sieht den Einladungs-Button (bubblet, ohne phx-target)" do
      assert render_with(owner?: true) =~ "Einladung erstellen"
      refute render_with(owner?: false) =~ "Einladung erstellen"
    end

    test "GM sieht im offenen Popup eines Spielers Promote + Remove" do
      html = render_with(popup: "222", can_edit_meta?: true)
      assert html =~ "Zum Spielleiter befördern"
      assert html =~ "Aus Kampagne entfernen"
    end

    test "ohne offenes Popup keine Aktions-Buttons" do
      refute render_with(can_edit_meta?: true) =~ "Zum Spielleiter befördern"
    end
  end
end
