defmodule HubWeb.CampaignLiveTimelineUiTest do
  @moduledoc """
  Issue #724 Slice F: Session-In-Game-Datum-Anzeige + Edit-Form (SessionInGame-
  AnchorSet) und Präzisions-Marker in der Chronik.
  """
  use HubWeb.ConnCase, async: false

  defp snap(opts) do
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
    # #915 (Cut 1): Kurations-UI lebt im Bearbeiten-Modus (Default :lesen).
    render_click(lv, "view_mode_toggle", %{"mode" => "bearbeiten"})
    lv
  end

  # Issue #1204: die Liste lädt erst beim Aufklappen (`campaign_review_facts`).
  # Der ReaderStub beantwortet diesen Read mit demselben Snapshot, der die
  # Liste trägt.
  defp aufklappen(lv) do
    render_click(lv, "fact_review_toggle", %{})
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

  # Issue #1082: `:set_session_date` ist Mitglieder-Recht geworden — der
  # Spieler sieht den Knopf jetzt. Die Schranke gegen Nicht-Mitglieder prüft
  # `permissions_test.exs` an der Autz-Wahrheit selbst.
  test "Spieler-Member sieht den Datum-Edit-Button (seit #1082)", %{conn: conn} do
    lv = mount_as(conn, campaign_role: :spieler)
    assert has_element?(lv, "[phx-click='session_date_edit_start']")
  end

  # Der Block „Review-Queue (#746)" stand hier mit sechs Tests: die
  # zugeklappte Liste zeichnet nur die Zahl, Member und GM sehen ✎ und ✕, das
  # date_parse_error-Flag zeigt seinen Hinweis, Abbrechen schließt die Form.
  #
  # Mit J7 (#1211) ist die Review-Queue abgebaut. Sie sammelte, was der
  # deterministische Zeitstrahl nicht platzieren konnte — eine Kategorie, die
  # es nicht mehr gibt: Der Chronik-Jack entscheidet selbst, was einen Eintrag
  # bekommt, und gibt die Reihenfolge an. Das Ausblenden eines Fakts kann die
  # Fakten-Spalte (#916, `curation_dismissed`).
  #
  # Das Ereignis `SessionFactDateSet`, sein Fold und die Tabelle bleiben
  # lesbar — gesetzte Daten alter Sitzungen verschwinden nicht, und der
  # Chronik-Jack darf sie als harten Anker nutzen.

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

    test "Spieler-Member sieht den Kalender-Tab (seit #1082)", %{conn: conn} do
      html = conn |> mount_as(campaign_role: :spieler) |> render()
      assert html =~ ~s(phx-value-tab="kalender")
    end
  end
end
