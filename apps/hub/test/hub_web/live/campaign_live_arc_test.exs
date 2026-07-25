defmodule HubWeb.CampaignLiveArcTest do
  @moduledoc """
  Issue #903 (Epic #900 S2): Arc-Akte im Fäden-Panel. Gepinnt: Stränge MIT
  Arc-Objekt zeigen Close-geloest/-versandet bzw. Reopen statt des
  Legacy-resolve (EINE Schließ-Wahrheit); arc-lose Stränge behalten den
  Legacy-Pfad (Regression); Leitfragen-Zeile + Inline-Edit; die
  Wasserlinien-Berechnung zur Schreibzeit (Unit); Klick-Pfade crashen ohne
  Worker nicht (Publish → bridge-Fail → Flash, kein Exception-Pfad).
  """

  use HubWeb.ConnCase, async: false

  alias HubWeb.CampaignLive.StageEdits

  defp thread(canonical, opts \\ []) do
    %{
      "canonical" => canonical,
      "key_canonical" => canonical,
      "kind" => Keyword.get(opts, :kind, "arc"),
      "status" => Keyword.get(opts, :status, "offen"),
      "dismissed?" => false,
      "curated?" => false,
      "identity_action" => nil,
      "lifecycle_action" => nil,
      "kind_action" => nil,
      "resolution_suggested?" => false,
      "entities" => [],
      "fact_count" => 3,
      "opened_in_session" => 1,
      "last_touched_session" => Keyword.get(opts, :last_touched, 2),
      "sessions_touched" => [1, 2],
      "arc_id" => Keyword.get(opts, :arc_id),
      "arc_status" => Keyword.get(opts, :arc_status),
      "arc_grund" => Keyword.get(opts, :arc_grund),
      "leitfrage" => Keyword.get(opts, :leitfrage),
      "leitfrage_kuratiert?" => Keyword.get(opts, :kuratiert?, false)
    }
  end

  defp mount_panel(conn, threads) do
    snap =
      Fixtures.snapshot(
        campaign_id: "c-arc-903",
        name: "Arc Kampagne",
        sessions: [%{"id" => "s-1", "number" => 1, "name" => "Eins"}],
        campaign_threads: threads,
        members: [Fixtures.member("did-sp", "spieler")]
      )

    stub_reader!(snap)
    user = Fixtures.user(discord_id: "did-sp", display_name: "Spieler", campaign_role: :spieler)
    {:ok, lv, _html} = conn |> log_in(user) |> live("/campaigns/c-arc-903")
    render_async(lv)
    render_click(lv, "toggle_threads_panel", %{})
    lv
  end

  test "offener Arc: auflösen + versandet statt Legacy-resolve; Leitfrage sichtbar", %{
    conn: conn
  } do
    lv =
      mount_panel(conn, [
        thread("der Auftrag",
          arc_id: "arc_a",
          arc_status: "offen",
          leitfrage: "Erledigen sie Romeos Auftrag?"
        )
      ])

    html = render(lv)
    assert html =~ "thread_arc_close"
    assert html =~ "auflösen"
    assert html =~ "versandet"
    refute html =~ ~s(phx-value-action="resolve")
    refute html =~ "wieder öffnen"
    assert html =~ "Erledigen sie Romeos Auftrag?"
    assert html =~ "✎ bearbeiten"
  end

  test "geschlossener Arc: wieder öffnen statt Close-Buttons", %{conn: conn} do
    lv =
      mount_panel(conn, [
        thread("der Auftrag",
          arc_id: "arc_a",
          arc_status: "geschlossen",
          arc_grund: "versandet",
          status: "aufgelöst"
        )
      ])

    html = render(lv)
    assert html =~ "wieder öffnen"
    refute html =~ "thread_arc_close"
  end

  test "arc-loser Strang behält den Legacy-resolve (Regression)", %{conn: conn} do
    lv = mount_panel(conn, [thread("der Auftrag")])

    html = render(lv)
    assert html =~ ~s(phx-value-action="resolve")
    refute html =~ "thread_arc_close"
    refute html =~ "❓"
  end

  test "Leitfragen-Edit: Form öffnet, Save published ohne Crash (kein Worker)", %{conn: conn} do
    lv =
      mount_panel(conn, [
        thread("der Auftrag", arc_id: "arc_a", arc_status: "offen", leitfrage: "Draft?")
      ])

    html =
      render_click(lv, "thread_curate_edit_start", %{
        "canonical" => "arc_a",
        "mode" => "leitfrage"
      })

    assert html =~ "thread_leitfrage_save"

    # Ohne Worker läuft der Publish in den bridge-Fail-Pfad (Flash) — kein Crash.
    html = render_submit(lv, "thread_leitfrage_save", %{"arc_id" => "arc_a", "text" => "Neu?"})
    refute html =~ "thread_leitfrage_save"
  end

  test "Close-/Reopen-Klicks crashen ohne Worker nicht", %{conn: conn} do
    lv =
      mount_panel(conn, [
        thread("der Auftrag", arc_id: "arc_a", arc_status: "offen", last_touched: 4)
      ])

    assert render_click(lv, "thread_arc_close", %{"arc_id" => "arc_a", "grund" => "geloest"})
    assert render_click(lv, "thread_arc_reopen", %{"arc_id" => "arc_a"})
  end

  test "arc_wasserlinie: max über last_touched_session, robust gegen Defekte" do
    threads = [
      %{"last_touched_session" => 2},
      %{"last_touched_session" => 5},
      %{"last_touched_session" => nil},
      %{"last_touched_session" => "kaputt"}
    ]

    assert StageEdits.arc_wasserlinie(threads) == 5
    assert StageEdits.arc_wasserlinie([]) == 0
  end
end
