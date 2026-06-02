defmodule HubWeb.CampaignLiveMountTest do
  @moduledoc """
  Issue #66: erster echter LiveView-Mount-Test für den Hub (vorher: 0). Beweist
  das Harness — `ReaderStub` (Snapshot ohne Worker), `log_in/2` (Session-User
  passiert den :require_user-Plug), `Fixtures.snapshot/1`.
  """

  use HubWeb.ConnCase, async: false

  test "Spieler-Member mountet CampaignLive — Smoke + Kampagnenname rendert", %{conn: conn} do
    snap =
      Fixtures.snapshot(
        campaign_id: "c-mount",
        name: "Mount Demo Kampagne",
        members: [Fixtures.member("did-sp", "spieler")]
      )

    stub_reader!(snap)
    user = Fixtures.user(discord_id: "did-sp", display_name: "Spieler", campaign_role: :spieler)

    {:ok, _lv, html} =
      conn
      |> log_in(user)
      |> live("/campaigns/c-mount")

    assert html =~ "Mount Demo Kampagne"
  end

  test "ohne Session-User redirected der :require_user-Plug zu /auth/discord", %{conn: conn} do
    # kein log_in → Plug muss bouncen, LV wird gar nicht erst gemountet.
    assert {:error, {:redirect, %{to: "/auth/discord"}}} = live(conn, "/campaigns/c-mount")
  end
end
