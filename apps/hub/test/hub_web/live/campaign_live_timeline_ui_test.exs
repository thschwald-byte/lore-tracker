defmodule HubWeb.CampaignLiveTimelineUiTest do
  @moduledoc """
  Issue #724 Slice F: Session-In-Game-Datum-Anzeige + Edit-Form (SessionInGame-
  AnchorSet) und Präzisions-Marker in der Chronik.
  """
  use HubWeb.ConnCase, async: false

  defp snap(opts \\ []) do
    Fixtures.snapshot(
      campaign_id: "c-tl",
      name: "Timeline Kampagne",
      viewer_role: Keyword.get(opts, :viewer_role, "spieler"),
      members: Keyword.get(opts, :members, [Fixtures.member("did-sp", "spieler")]),
      sessions: [
        %{
          "id" => "s-1",
          "number" => 1,
          "name" => "Erste Session",
          "in_game_date_raw" => Keyword.get(opts, :igd, "15. Januar 1888"),
          "in_game_day" => 689_120
        }
      ],
      utterances: [
        %{
          "id" => "u-1",
          "session_id" => "s-1",
          "discord_id" => "did-sp",
          "timestamp" => "2026-07-07T10:00:00Z",
          "text" => "Hallo",
          "confidence" => nil,
          "status" => "confirmed"
        }
      ],
      chronik: [
        %{
          "id" => "c-1",
          "in_game_date" => "1888",
          "label" => "Ereignis",
          "summary" => "Etwas geschah",
          "source_refs" => [],
          "markdown_body" => nil,
          "precision" => "year"
        }
      ]
    )
  end

  defp mount_as(conn, user_opts, snap_opts \\ []) do
    stub_reader!(snap(snap_opts))
    user = Fixtures.user(Keyword.merge([discord_id: "did-sp", display_name: "Sp"], user_opts))
    {:ok, lv, _html} = conn |> log_in(user) |> live("/campaigns/c-tl")
    render_async(lv)
    lv
  end

  test "Session-In-Game-Datum wird im Session-Header angezeigt", %{conn: conn} do
    html = conn |> mount_as(campaign_role: :spieler) |> render()
    assert html =~ "📅"
    assert html =~ "15. Januar 1888"
  end

  test "Chronik-Eintrag mit grober Präzision zeigt den ~-Marker", %{conn: conn} do
    html = conn |> mount_as(campaign_role: :spieler) |> render()
    # precision "year" → approximate → Marker mit jahres-genau-Titel.
    assert html =~ "jahresgenau"
  end

  test "GM sieht den Datum-Edit-Button; Klick öffnet die Anker-Form", %{conn: conn} do
    # campaign_role wird aus dem Member-Eintrag abgeleitet → Viewer als
    # :spielleiter-Member eintragen, damit can_edit_meta? greift.
    lv =
      mount_as(conn, [],
        viewer_role: "spielleiter",
        members: [Fixtures.member("did-sp", "spielleiter")]
      )

    assert has_element?(lv, "[phx-click='session_date_edit_start'][phx-value-session='s-1']")

    html =
      lv
      |> element("[phx-click='session_date_edit_start'][phx-value-session='s-1']")
      |> render_click()

    assert html =~ "session_date_edit_save"
    assert html =~ ~s(name="in_game_date")
  end

  test "Nicht-GM sieht keinen Datum-Edit-Button", %{conn: conn} do
    lv = mount_as(conn, campaign_role: :spieler)
    refute has_element?(lv, "[phx-click='session_date_edit_start']")
  end
end
