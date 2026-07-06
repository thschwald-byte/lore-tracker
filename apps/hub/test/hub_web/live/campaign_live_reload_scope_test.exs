defmodule HubWeb.CampaignLiveReloadScopeTest do
  @moduledoc """
  Issue #710: `handle_async(:reload_scope, ...)` crashte bei JEDEM erfolgreichen
  Scoped-Reload mit BadBooleanError (`Map.get(snap, "forbidden")` → nil als
  linke Seite von `or`). Ein Tier-2-Event (z.B. EposEntryEdited) löst einen
  scoped Worker-Read aus; der saubere Snapshot (ohne error/forbidden/not_found)
  muss OHNE Crash in die Assigns gemerged werden.
  """
  use HubWeb.ConnCase, async: false

  defp mount_campaign(conn) do
    snap =
      Fixtures.snapshot(
        campaign_id: "c-scope",
        name: "Scope Kampagne",
        members: [Fixtures.member("did-sp", "spieler")]
      )

    stub_reader!(snap)
    user = Fixtures.user(discord_id: "did-sp", display_name: "Spieler", campaign_role: :spieler)
    {:ok, lv, _} = conn |> log_in(user) |> live("/campaigns/c-scope")
    render_async(lv)
    lv
  end

  defp scoped_event(kind),
    do: {:event_appended, %{payload: %{"kind" => kind, "campaign_id" => "c-scope"}}}

  test "EposEntryEdited → scoped Reload crasht den LV nicht (Issue #710)", %{conn: conn} do
    lv = mount_campaign(conn)
    ref = Process.monitor(lv.pid)

    send(lv.pid, scoped_event("EposEntryEdited"))
    render_async(lv)

    # Vor dem Fix: BadBooleanError → LV-Prozess tot. Nach dem Fix: lebt + rendert.
    refute_receive {:DOWN, ^ref, :process, _, _}, 500
    assert Process.alive?(lv.pid)
    assert render(lv) =~ "Scope Kampagne"
  end

  test "ChronikEntryChanged + CampaignFlavorSet → ebenfalls kein Crash", %{conn: conn} do
    lv = mount_campaign(conn)

    for kind <- ["ChronikEntryChanged", "CampaignFlavorSet", "SessionSummaryGenerated"] do
      send(lv.pid, scoped_event(kind))
      render_async(lv)
      assert Process.alive?(lv.pid), "LV crashte bei scoped Reload für #{kind}"
    end
  end
end
