defmodule HubWeb.CampaignLiveViewModeTest do
  @moduledoc """
  Issue #915 (Epic #911, Cut 1): der Lesen|Bearbeiten-Modus. Gepinnt: (1) Default
  = :lesen; (2) Palette — Protokoll (Kurations-Substrat) nur im Bearbeiten-Modus;
  (3) Kurator sieht den Toggle, ein reiner Nicht-Member nicht; (4) columns_for_mode.
  """

  use HubWeb.ConnCase, async: false

  alias HubWeb.CampaignLive.ViewMode

  describe "columns_for_mode/1 (pur)" do
    test "Lese-Palette ohne Protokoll, Bearbeiten-Palette mit Protokoll" do
      refute "protokoll" in ViewMode.columns_for_mode(:lesen)
      assert "protokoll" in ViewMode.columns_for_mode(:bearbeiten)
      # unbekannt → Lese-Default (fail-safe).
      assert ViewMode.columns_for_mode(:bogus) == ViewMode.columns_for_mode(:lesen)
    end
  end

  defp mount_lv(conn, campaign_role) do
    snap =
      Fixtures.snapshot(
        campaign_id: "c-vm-915",
        name: "Modus Kampagne",
        sessions: [%{"id" => "s-1", "number" => 1, "name" => "Eins"}],
        members: [Fixtures.member("did-a", "spieler")]
      )

    stub_reader!(snap)

    user =
      Fixtures.user(discord_id: "did-a", display_name: "A", campaign_role: campaign_role)

    {:ok, lv, _html} = conn |> log_in(user) |> live("/campaigns/c-vm-915")
    render_async(lv)
    lv
  end

  test "Default = Lesen: kein Protokoll-Header; Toggle sichtbar für Member", %{conn: conn} do
    lv = mount_lv(conn, :spieler)
    html = render(lv)

    # Toggle da (Member hat Kurationsrecht → can_edit_mode?), Default steht auf Lesen.
    assert html =~ "Bearbeiten"
    assert html =~ "Lesen"
    # Protokoll-Spalte (Kurations-Substrat) ist im Lesemodus NICHT gerendert.
    refute html =~ "protokoll-scroll"
  end

  test "Wechsel nach Bearbeiten zeigt die Protokoll-Spalte", %{conn: conn} do
    lv = mount_lv(conn, :spieler)
    html = render_click(lv, "view_mode_toggle", %{"mode" => "bearbeiten"})
    assert html =~ "protokoll-scroll"

    # Zurück nach Lesen blendet sie wieder aus.
    html2 = render_click(lv, "view_mode_toggle", %{"mode" => "lesen"})
    refute html2 =~ "protokoll-scroll"
  end

  test "Nicht-Member (kein Kurationsrecht) sieht keinen Modus-Toggle", %{conn: conn} do
    snap =
      Fixtures.snapshot(
        campaign_id: "c-vm-915b",
        name: "Modus Kampagne",
        sessions: [%{"id" => "s-1", "number" => 1, "name" => "Eins"}],
        members: [Fixtures.member("did-x", "spieler")]
      )

    stub_reader!(snap)
    # did-nobody ist NICHT in der Member-Liste → can_edit_mode? false.
    user = Fixtures.user(discord_id: "did-nobody", display_name: "Fremd", campaign_role: nil)
    {:ok, lv, _html} = conn |> log_in(user) |> live("/campaigns/c-vm-915b")
    render_async(lv)
    html = render(lv)

    refute html =~ ~s(phx-value-mode="bearbeiten")
  end
end
