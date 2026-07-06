defmodule HubWeb.CampaignLiveUtteranceWindowTest do
  @moduledoc """
  Issue #707: eine lange Single-Session (2h-Aufnahme = tausende Utts) darf beim
  Aufklappen nicht alle Zeilen in einem Mount-Diff rendern (Hub-OOM). Gerendert
  wird nur das neueste Fenster + ein "ältere anzeigen"-Auslöser; Klick bumpt.
  """

  use HubWeb.ConnCase, async: false

  alias HubWeb.CampaignLive.Components

  defp big_session_snapshot(n) do
    utts =
      for i <- 1..n do
        %{
          "id" => "u-#{i}",
          "session_id" => "s-1",
          "discord_id" => "did-sp",
          "timestamp" =>
            "2026-07-06T10:00:#{rem(i, 60) |> Integer.to_string() |> String.pad_leading(2, "0")}Z",
          "text" => "Utterance Nummer #{i}",
          "confidence" => nil,
          "status" => "confirmed"
        }
      end

    Fixtures.snapshot(
      campaign_id: "c-window",
      name: "Window Kampagne",
      sessions: [%{"id" => "s-1", "number" => 1, "name" => "Lange Session"}],
      utterances: utts,
      members: [Fixtures.member("did-sp", "spieler")]
    )
  end

  defp count_rows(html), do: html |> String.split("data-utterance-id=") |> length() |> Kernel.-(1)

  test "lange Session rendert nur das Fenster + 'ältere anzeigen'", %{conn: conn} do
    n = Components.utterance_window_size() + 300
    stub_reader!(big_session_snapshot(n))
    user = Fixtures.user(discord_id: "did-sp", display_name: "Spieler", campaign_role: :spieler)

    {:ok, lv, _html} = conn |> log_in(user) |> live("/campaigns/c-window")
    html = render_async(lv)

    # Nur das Fenster ist gerendert, nicht alle n Zeilen.
    assert count_rows(html) == Components.utterance_window_size()
    assert html =~ "ältere anzeigen"
    # neueste sichtbar, älteste nicht.
    assert html =~ "Utterance Nummer #{n}"
    refute html =~ "Utterance Nummer 1<"
  end

  test "'ältere anzeigen' klicken rendert ein größeres Fenster", %{conn: conn} do
    step = Components.utterance_window_size()
    n = step + 300
    stub_reader!(big_session_snapshot(n))
    user = Fixtures.user(discord_id: "did-sp", display_name: "Spieler", campaign_role: :spieler)

    {:ok, lv, _html} = conn |> log_in(user) |> live("/campaigns/c-window")
    render_async(lv)

    html =
      lv
      |> element("button[phx-click='utterance_window_more'][phx-value-session='s-1']")
      |> render_click()

    assert count_rows(html) == step * 2
  end

  test "kurze Session zeigt keinen 'ältere anzeigen'-Auslöser", %{conn: conn} do
    stub_reader!(big_session_snapshot(20))
    user = Fixtures.user(discord_id: "did-sp", display_name: "Spieler", campaign_role: :spieler)

    {:ok, lv, _html} = conn |> log_in(user) |> live("/campaigns/c-window")
    html = render_async(lv)

    assert count_rows(html) == 20
    refute html =~ "ältere anzeigen"
  end
end
