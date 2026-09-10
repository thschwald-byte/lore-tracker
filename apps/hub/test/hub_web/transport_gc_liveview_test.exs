defmodule HubWeb.TransportGcLiveViewTest do
  @moduledoc """
  Issue #1198: der Aufräum-Haken darf keinem Verbindungsprozess eine Nachricht
  schicken, die er nicht kennt.

  **Anlass (PR #1201, CI-Lauf 1026):** die erste Fassung schickte 1 s nach
  jedem Render `:garbage_collect` an `socket.transport_pid`. `Phoenix.Socket`
  kennt die Nachricht — der Test-Client von LiveView
  (`Phoenix.LiveViewTest.ClientProxy`) nicht: `FunctionClauseError`, der
  Test stirbt. Lokal blieb das unsichtbar, weil kaum ein Test länger als eine
  Sekunde lebt; unter `cover` in CI tat es einer. Hier lebt die Ansicht
  absichtlich länger als die Verzögerung.
  """
  use HubWeb.ConnCase, async: false

  test "eine Ansicht überlebt die Aufräum-Verzögerung", %{conn: conn} do
    snap =
      Fixtures.snapshot(
        campaign_id: "c-gc-1198",
        name: "Aufräum Kampagne",
        sessions: [%{"id" => "s-1", "number" => 1, "name" => "Eins"}],
        members: [Fixtures.member("did-gc", "spieler")]
      )

    stub_reader!(snap)
    user = Fixtures.user(discord_id: "did-gc", display_name: "GC", campaign_role: :spieler)
    {:ok, lv, _html} = conn |> log_in(user) |> live("/campaigns/c-gc-1198")
    render_async(lv)

    Process.sleep(HubWeb.TransportGc.verzoegerung_ms() + 400)

    # Lebt der Test-Client noch, antwortet er; sonst stirbt der Test hier.
    assert render(lv) =~ "Aufräum Kampagne"
  end
end
