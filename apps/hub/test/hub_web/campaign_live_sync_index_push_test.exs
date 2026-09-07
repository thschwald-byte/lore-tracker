defmodule HubWeb.CampaignLiveSyncIndexPushTest do
  @moduledoc """
  Issue #1187: der ColumnSync-Index (#10) erreicht den Browser als Ereignis
  `"sync_index"`, nicht mehr als `data-sync-index`-Attribut.

  Die pure Seite (`Updates.pushe_sync_index/2`) ist in `updates_scope_test`
  gepinnt. Hier die Server-Seite am ECHTEN Mount: der async Snapshot-Load
  (#607) ruft `apply_snapshot`, das den Index baut und pusht — dieser Test
  beweist, dass das Ereignis tatsächlich den LiveView-Diff erreicht. Ohne ihn
  wäre ein vergessener `pushe_sync_index` still: die Spalten koppeln dann
  einfach nicht mehr, nichts wird rot.
  """

  use HubWeb.ConnCase, async: false

  test "nach dem async Mount wird der Sync-Index als Ereignis gepusht", %{conn: conn} do
    snap =
      Fixtures.snapshot(
        campaign_id: "c-sync",
        name: "Sync Kampagne",
        members: [Fixtures.member("did-sp", "spieler")]
      )

    stub_reader!(snap)
    user = Fixtures.user(discord_id: "did-sp", display_name: "Spieler", campaign_role: :spieler)

    {:ok, lv, html} = conn |> log_in(user) |> live("/campaigns/c-sync")
    refute html =~ "data-sync-index", "das 2,5-MB-Attribut ist zurück (#1187)"

    _ = render_async(lv)

    assert_push_event(lv, "sync_index", %{index: index})
    assert is_map(index)
    assert Map.has_key?(index, "utts_to_entries") or Map.has_key?(index, :utts_to_entries)
  end
end
