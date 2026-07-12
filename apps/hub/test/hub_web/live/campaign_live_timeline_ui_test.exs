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
      review_facts: Keyword.get(opts, :review_facts, []),
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

  describe "Review-Queue (#746)" do
    @rf [
      %{
        "id" => "f1",
        "session_id" => "s-1",
        "extraction_event_id" => "ext-01",
        "claim" => "Kaira verlor ihren Bruder",
        "character_alias" => "Kaira",
        "narration_time" => "flashback"
      }
    ]

    test "GM sieht das Review-Panel mit unplatzierbaren Fakten + Erzählzeit-Marker", %{conn: conn} do
      html =
        mount_as(conn, [],
          viewer_role: "spielleiter",
          members: [Fixtures.member("did-sp", "spielleiter")],
          review_facts: @rf
        )
        |> render()

      assert html =~ "ohne Zeitstrahl-Datum"
      assert html =~ "Kaira verlor ihren Bruder"
      assert html =~ "⏮"
    end

    test "Nicht-GM sieht das Review-Panel nicht", %{conn: conn} do
      html = conn |> mount_as([campaign_role: :spieler], review_facts: @rf) |> render()
      refute html =~ "ohne Zeitstrahl-Datum"
    end

    test "leere Review-Queue → kein Panel", %{conn: conn} do
      html =
        mount_as(conn, [],
          viewer_role: "spielleiter",
          members: [Fixtures.member("did-sp", "spielleiter")]
        )
        |> render()

      refute html =~ "ohne Zeitstrahl-Datum"
    end

    test "GM sieht ✎/✕ pro Fakt; Klick auf ✎ öffnet die Datum-Form", %{conn: conn} do
      lv =
        mount_as(conn, [],
          viewer_role: "spielleiter",
          members: [Fixtures.member("did-sp", "spielleiter")],
          review_facts: @rf
        )

      assert has_element?(lv, "[phx-click='fact_date_edit_start'][phx-value-fact='f1']")
      assert has_element?(lv, "[phx-click='fact_dismiss'][phx-value-fact='f1']")

      html =
        lv
        |> element("[phx-click='fact_date_edit_start'][phx-value-fact='f1']")
        |> render_click()

      assert html =~ "fact_date_edit_save"
      assert html =~ ~s(name="in_game_date")
      assert html =~ ~s(value="ext-01")
    end

    test "Abbrechen der Datum-Form schließt sie wieder (State geclärt)", %{conn: conn} do
      lv =
        mount_as(conn, [],
          viewer_role: "spielleiter",
          members: [Fixtures.member("did-sp", "spielleiter")],
          review_facts: @rf
        )

      lv |> element("[phx-click='fact_date_edit_start'][phx-value-fact='f1']") |> render_click()
      assert has_element?(lv, "form[phx-submit='fact_date_edit_save']")

      lv |> element("[phx-click='fact_date_edit_cancel']") |> render_click()
      refute has_element?(lv, "form[phx-submit='fact_date_edit_save']")
      assert has_element?(lv, "[phx-click='fact_date_edit_start'][phx-value-fact='f1']")
    end

    test "Nicht-GM sieht weder ✎ noch ✕ (Panel ist ohnehin unsichtbar)", %{conn: conn} do
      lv = mount_as(conn, [campaign_role: :spieler], review_facts: @rf)
      refute has_element?(lv, "[phx-click='fact_date_edit_start']")
      refute has_element?(lv, "[phx-click='fact_dismiss']")
    end

    test "date_parse_error-Flag zeigt den Nicht-auflösbar-Hinweis", %{conn: conn} do
      rf_with_error = [
        Map.merge(hd(@rf), %{"date_parse_error" => true, "in_game_date" => "32.13.1920"})
      ]

      html =
        mount_as(conn, [],
          viewer_role: "spielleiter",
          members: [Fixtures.member("did-sp", "spielleiter")],
          review_facts: rf_with_error
        )
        |> render()

      assert html =~ "nicht auflösbar"
      assert html =~ "32.13.1920"
    end
  end

  describe "Kalender-Config (Slice F2)" do
    alias HubWeb.CampaignLive.StageEdits

    test "calendar_to_text: Monate → Textarea-Zeilen, kaputte Struktur → leer" do
      cal = %{
        "months" => [%{"name" => "Mirtul", "days" => 30}, %{"name" => "Kythorn", "days" => 30}]
      }

      assert StageEdits.calendar_to_text(cal) == "Mirtul 30\nKythorn 30"
      assert StageEdits.calendar_to_text(%{}) == ""
      assert StageEdits.calendar_to_text(nil) == ""
    end

    test "GM sieht den Kalender-Tab", %{conn: conn} do
      html =
        mount_as(conn, [],
          viewer_role: "spielleiter",
          members: [Fixtures.member("did-sp", "spielleiter")]
        )
        |> render()

      assert html =~ "Kalender"
      assert html =~ ~s(phx-value-tab="kalender")
    end

    test "Nicht-GM sieht den Kalender-Tab nicht", %{conn: conn} do
      html = conn |> mount_as(campaign_role: :spieler) |> render()
      refute html =~ ~s(phx-value-tab="kalender")
    end
  end
end
