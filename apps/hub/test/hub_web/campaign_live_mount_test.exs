defmodule HubWeb.CampaignLiveMountTest do
  @moduledoc """
  Issue #66: erster echter LiveView-Mount-Test für den Hub (vorher: 0). Beweist
  das Harness — `ReaderStub` (Snapshot ohne Worker), `log_in/2` (Session-User
  passiert den :require_user-Plug), `Fixtures.snapshot/1`.

  Issue #607: der mount lädt den Snapshot async (kein blockierender Worker-
  Roundtrip mehr). Der Erst-Render zeigt den Lade-Zustand, die Daten kommen
  nach dem `start_async` — daher `render_async/1`. forbidden?/not_found?
  redirecten aus `handle_async`, nicht mehr aus dem mount.
  """

  use HubWeb.ConnCase, async: false

  test "Spieler-Member mountet CampaignLive — async geladen, Kampagnenname rendert", %{conn: conn} do
    snap =
      Fixtures.snapshot(
        campaign_id: "c-mount",
        name: "Mount Demo Kampagne",
        members: [Fixtures.member("did-sp", "spieler")]
      )

    stub_reader!(snap)
    user = Fixtures.user(discord_id: "did-sp", display_name: "Spieler", campaign_role: :spieler)

    {:ok, lv, html} =
      conn
      |> log_in(user)
      |> live("/campaigns/c-mount")

    # Issue #607: mount blockiert NICHT auf dem Worker — der Erst-Render zeigt
    # den Lade-Zustand, der Kampagnenname kommt erst nach dem async Snapshot.
    refute html =~ "Mount Demo Kampagne"
    assert render_async(lv) =~ "Mount Demo Kampagne"
  end

  test "ohne Session-User redirected der :require_user-Plug zu /auth/discord", %{conn: conn} do
    # kein log_in → Plug muss bouncen, LV wird gar nicht erst gemountet.
    assert {:error, {:redirect, %{to: "/auth/discord"}}} = live(conn, "/campaigns/c-mount")
  end

  test "forbidden-Snapshot → Redirect zu / (aus handle_async, Issue #607)", %{conn: conn} do
    stub_reader!(%{"forbidden" => true})
    user = Fixtures.user(discord_id: "did-x", display_name: "X", campaign_role: nil)

    {:ok, lv, _html} = conn |> log_in(user) |> live("/campaigns/c-forbidden")

    assert_redirect(lv, "/")
  end

  test "not_found-Snapshot → Redirect zu / (aus handle_async, Issue #607)", %{conn: conn} do
    stub_reader!(%{"not_found" => true})
    user = Fixtures.user(discord_id: "did-x", display_name: "X", campaign_role: nil)

    {:ok, lv, _html} = conn |> log_in(user) |> live("/campaigns/c-missing")

    assert_redirect(lv, "/")
  end
end
