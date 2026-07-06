defmodule HubWeb.CampaignLiveUtteranceWindowTest do
  @moduledoc """
  Issue #709: eine lange Single-Session (2h-Aufnahme = tausende Utts) rendert
  nur ein gleitendes, HART gedeckeltes Fenster (count ≤ window_max), egal wie
  weit gescrollt wird. Load-older/-newer verschieben + evincten; focus_utterance
  holt eine evincte Zeile wieder ins Fenster; Live-Appends folgen nur im
  Tail-Modus.
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

  defp mount_big(conn, n) do
    stub_reader!(big_session_snapshot(n))
    user = Fixtures.user(discord_id: "did-sp", display_name: "Spieler", campaign_role: :spieler)
    {:ok, lv, _html} = conn |> log_in(user) |> live("/campaigns/c-window")
    render_async(lv)
    lv
  end

  test "lange Session rendert nur das Tail-Fenster + 'ältere anzeigen'", %{conn: conn} do
    n = Components.window_default() + 300
    lv = mount_big(conn, n)
    html = render(lv)

    assert count_rows(html) == Components.window_default()
    assert html =~ "ältere anzeigen"
    # neueste sichtbar, älteste nicht.
    assert html =~ "Utterance Nummer #{n}"
    refute html =~ "Utterance Nummer 1<"
  end

  test "wiederholtes 'ältere anzeigen' bleibt HART unter window_max (bis zum Anfang)", %{
    conn: conn
  } do
    lv = mount_big(conn, 2200)
    sel = "[phx-click='utterance_load_older'][phx-value-session='s-1']"

    # Bis zum Session-Anfang durchladen: solange der Auslöser da ist, klicken
    # und bei jedem Schritt die harte Obergrenze prüfen. Bounded (max 40 Iter).
    steps =
      Enum.reduce_while(1..40, 0, fn _, acc ->
        if has_element?(lv, sel) do
          html = lv |> element(sel) |> render_click()

          assert count_rows(html) <= Components.window_max(),
                 "Render überschritt window_max=#{Components.window_max()}"

          {:cont, acc + 1}
        else
          {:halt, acc}
        end
      end)

    # Am Anfang angekommen: kein "ältere anzeigen" mehr, aber Render weiter gedeckelt.
    refute has_element?(lv, sel)
    assert steps > 0
    assert count_rows(render(lv)) <= Components.window_max()
  end

  test "focus_utterance holt eine evincte Ur-Utterance ins Fenster", %{conn: conn} do
    n = 2200
    lv = mount_big(conn, n)

    # u-1 (älteste) ist im Tail-Fenster NICHT gerendert.
    refute render(lv) =~ ~s(data-utterance-id="u-1")

    html = render_hook(lv, "focus_utterance", %{"id" => "u-1"})

    assert html =~ ~s(data-utterance-id="u-1")
    assert count_rows(html) <= Components.window_max()
  end

  test "load_older dann load_newer verschiebt das Fenster + bleibt gedeckelt", %{conn: conn} do
    lv = mount_big(conn, 2200)

    older =
      lv
      |> element("[phx-click='utterance_load_older'][phx-value-session='s-1']")
      |> render_click()

    assert count_rows(older) <= Components.window_max()
    # nach dem Zurückscrollen erscheint der Bottom-Sentinel (neuere verdeckt)
    assert older =~ "neuere anzeigen"

    newer =
      lv
      |> element("[phx-click='utterance_load_newer'][phx-value-session='s-1']")
      |> render_click()

    assert count_rows(newer) <= Components.window_max()
  end

  test "Live-Append: Tail-Modus zeigt neue Utterance", %{conn: conn} do
    lv = mount_big(conn, 200)

    send(
      lv.pid,
      {:event_appended,
       %{
         payload: %{
           "kind" => Shared.Events.utterance_appended(),
           "id" => "u-live",
           "session_id" => "s-1",
           "discord_id" => "did-sp",
           "timestamp" => "2026-07-06T11:00:00Z",
           "text" => "Frische Live-Utterance",
           "confidence" => nil,
           "status" => "confirmed"
         }
       }}
    )

    assert render(lv) =~ "Frische Live-Utterance"
  end

  test "Live-Append: nach Scroll-up (explizites Fenster) NICHT im Fenster, aber Bottom-Sentinel",
       %{
         conn: conn
       } do
    lv = mount_big(conn, 2200)

    # In expliziten Modus wechseln (Scroll hoch).
    lv
    |> element("[phx-click='utterance_load_older'][phx-value-session='s-1']")
    |> render_click()

    send(
      lv.pid,
      {:event_appended,
       %{
         payload: %{
           "kind" => Shared.Events.utterance_appended(),
           "id" => "u-live2",
           "session_id" => "s-1",
           "discord_id" => "did-sp",
           "timestamp" => "2026-07-06T11:00:00Z",
           "text" => "Nicht-im-Fenster-Live",
           "confidence" => nil,
           "status" => "confirmed"
         }
       }}
    )

    html = render(lv)
    refute html =~ "Nicht-im-Fenster-Live"
    assert html =~ "neuere anzeigen"
  end

  test "kurze Session zeigt keine Sentinels", %{conn: conn} do
    lv = mount_big(conn, 20)
    html = render(lv)

    assert count_rows(html) == 20
    refute html =~ "ältere anzeigen"
    refute html =~ "neuere anzeigen"
  end
end
