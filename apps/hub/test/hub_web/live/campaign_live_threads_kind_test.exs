defmodule HubWeb.CampaignLiveThreadsKindTest do
  @moduledoc """
  Issue #885: das Fäden-Panel trennt Arcs (Handlungsbögen) von Contexten
  (Themen = zeitloses Weltwissen) — Contexte unten hinter einem Trenner, ohne
  Auflösungs-Semantik (kein „auflösen"-Button, kein 🏁), mit Umstufungs-Buttons
  in beide Richtungen.
  """

  use HubWeb.ConnCase, async: false

  defp thread(canonical, kind, opts \\ []) do
    %{
      "canonical" => canonical,
      "key_canonical" => canonical,
      "kind" => kind,
      "status" => Keyword.get(opts, :status, "offen"),
      "dismissed?" => false,
      "curated?" => false,
      "identity_action" => nil,
      "lifecycle_action" => nil,
      "kind_action" => Keyword.get(opts, :kind_action),
      "resolution_suggested?" => Keyword.get(opts, :resolution_suggested?, false),
      "entities" => [],
      "fact_count" => 3,
      "opened_in_session" => 1,
      "last_touched_session" => 2,
      "sessions_touched" => [1, 2]
    }
  end

  defp mount_panel(conn, threads) do
    snap =
      Fixtures.snapshot(
        campaign_id: "c-threads-kind",
        name: "Kind Kampagne",
        sessions: [%{"id" => "s-1", "number" => 1, "name" => "Eins"}],
        campaign_threads: threads,
        members: [Fixtures.member("did-sp", "spieler")]
      )

    stub_reader!(snap)
    user = Fixtures.user(discord_id: "did-sp", display_name: "Spieler", campaign_role: :spieler)
    {:ok, lv, _html} = conn |> log_in(user) |> live("/campaigns/c-threads-kind")
    render_async(lv)
    render_click(lv, "toggle_threads_panel", %{})
    lv
  end

  test "Header zählt Arcs und Themen getrennt; Trenner vor den Contexten", %{conn: conn} do
    lv =
      mount_panel(conn, [
        thread("der Auftrag", "arc"),
        thread("die Weltgeschichte", "context")
      ])

    html = render(lv)
    assert html =~ "1 Handlungsfäden — 1 offen"
    assert html =~ "1 Themen"
    assert html =~ "Themen — Weltwissen, schließt nie ab"
  end

  test "Context: kein aufloesen-Button, kein Abschluss-Flag; dafuer als-Faden-Umstufung", %{
    conn: conn
  } do
    lv = mount_panel(conn, [thread("die Weltgeschichte", "context", resolution_suggested?: true)])
    html = render(lv)

    refute html =~ "auflösen"
    refute html =~ "Abschluss?"
    assert html =~ "als Faden"
    refute html =~ "als Thema"
  end

  test "Arc: aufloesen + als-Thema-Umstufung vorhanden", %{conn: conn} do
    lv = mount_panel(conn, [thread("der Auftrag", "arc")])
    html = render(lv)

    assert html =~ "auflösen"
    assert html =~ "als Thema"
    refute html =~ "als Faden"
  end

  test "aktiver kind-Override zeigt Undo statt Umstufung", %{conn: conn} do
    lv = mount_panel(conn, [thread("die Heirat", "context", kind_action: "mark_context")])
    html = render(lv)

    assert html =~ "Einstufung zurücksetzen"
    refute html =~ "als Faden"
  end
end
