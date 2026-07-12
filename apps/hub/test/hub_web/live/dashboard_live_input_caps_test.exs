defmodule HubWeb.DashboardLiveInputCapsTest do
  @moduledoc """
  Issue #636: Server-Side-Cap-Gates in den Dashboard-Save-Handlern
  (`create_campaign`, `edit_modal_save`).

  Deny-Pfad: überlanger `name` / `theme_blurb` → Flash-Error + kein
  bridge_publish. Bare-Socket-Transform — der bridge_publish-Pfad wird gar
  nicht erst erreicht (Cap-Check greift davor), also kein EventBridge-Setup
  nötig.
  """
  use ExUnit.Case, async: true

  alias HubWeb.DashboardLive

  # Ein Byte über dem campaign_name-Cap (200).
  @overlong_name String.duplicate("N", 201)
  # Ein Byte über dem theme_blurb-Cap (4_000).
  @overlong_blurb String.duplicate("b", 4_001)

  defp socket(assigns) do
    %Phoenix.LiveView.Socket{assigns: Map.put(assigns, :__changed__, %{})}
  end

  describe "create_campaign — Cap" do
    test "überlanger Name → Flash-Error, kein Publish, Modal-State bleibt" do
      s =
        socket(%{
          current_user: %{discord_id: "did-me", display_name: "Me"},
          can_create_campaign?: true,
          show_new_modal: true,
          new_name: @overlong_name,
          flash: %{}
        })

      {:noreply, s2} =
        DashboardLive.handle_event("create_campaign", %{"name" => @overlong_name}, s)

      assert s2.assigns.flash["error"] =~ "Kampagnen-Name"
      assert s2.assigns.flash["error"] =~ "200"
      # Modal + Draft nicht zugemacht — User kürzt und speichert erneut.
      assert s2.assigns.show_new_modal == true
      assert s2.assigns.new_name == @overlong_name
    end
  end

  describe "edit_modal_save — Cap" do
    defp edit_socket(name, blurb) do
      socket(%{
        current_user: %{discord_id: "did-me", display_name: "Me", role: :admin},
        viewer_role: :admin,
        campaigns: [
          %{
            "id" => "camp-1",
            "name" => "alt",
            "theme_blurb" => "alt",
            "icon_url" => nil,
            "status" => :active,
            "members" => [%{"discord_id" => "did-me", "role" => "spielleiter"}]
          }
        ],
        edit_modal: %{
          "id" => "camp-1",
          "name" => name,
          "theme_blurb" => blurb,
          "icon_url" => ""
        },
        flash: %{}
      })
    end

    test "überlanger Name → Flash-Error, kein Publish, Modal bleibt offen" do
      s = edit_socket(@overlong_name, "kurz")

      {:noreply, s2} =
        DashboardLive.handle_event(
          "edit_modal_save",
          %{"name" => @overlong_name, "theme_blurb" => "kurz", "icon_url" => ""},
          s
        )

      assert s2.assigns.flash["error"] =~ "Kampagnen-Name"
      assert s2.assigns.flash["error"] =~ "200"
      # Modal-Draft bleibt sichtbar (nicht auf nil gesetzt) — User kürzt.
      assert s2.assigns.edit_modal["id"] == "camp-1"
    end

    test "überlanger theme_blurb → Flash-Error, kein Publish, Modal bleibt offen" do
      s = edit_socket("OK-Name", @overlong_blurb)

      {:noreply, s2} =
        DashboardLive.handle_event(
          "edit_modal_save",
          %{"name" => "OK-Name", "theme_blurb" => @overlong_blurb, "icon_url" => ""},
          s
        )

      assert s2.assigns.flash["error"] =~ "Beschreibung"
      assert s2.assigns.flash["error"] =~ "4000"
      assert s2.assigns.edit_modal["id"] == "camp-1"
    end
  end
end
