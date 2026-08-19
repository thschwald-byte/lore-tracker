defmodule HubWeb.CampaignLiveRecButtonTest do
  @moduledoc """
  Issue #1090: der Test, der von Anfang an gefehlt hat.

  Alle bisherigen Aufnahme-Tests prüften, wer den Knopf NICHT bedienen darf.
  Dass er für einen Berechtigten überhaupt **aktiv** ist, prüfte keiner — und
  genau das ging mit #1082 kaputt: `can_record?` wurde berechnet, aber nie in
  den Socket übertragen, der Knopf blieb für alle gesperrt.

  Ein toter Knopf ist kein Fehler, den irgendetwas meldet. Also braucht es einen
  Test, der ihn anfasst.
  """
  use HubWeb.ConnCase, async: false

  defp snap(opts \\ []) do
    Fixtures.snapshot(
      campaign_id: "c-rec",
      name: "Aufnahme-Kampagne",
      viewer_role: Keyword.get(opts, :viewer_role, "spieler"),
      members: Keyword.get(opts, :members, [Fixtures.member("did-me", "spieler")]),
      sessions: []
    )
  end

  defp mount_as(conn, role, snap_opts \\ []) do
    stub_reader!(snap(snap_opts))
    user = Fixtures.user(discord_id: "did-me", display_name: "Ich", campaign_role: role)
    {:ok, lv, _html} = conn |> log_in(user) |> live("/campaigns/c-rec")
    render_async(lv)
    lv
  end

  test "die Spielleitung kann die Session starten", %{conn: conn} do
    lv = mount_as(conn, :spielleiter, members: [Fixtures.member("did-me", "spielleiter")])

    assert has_element?(lv, "[phx-click='rec_start']")
    refute has_element?(lv, "[phx-click='rec_start'][disabled]")
  end

  test "ein Mitspieler kann die Session ebenfalls starten (#1082)", %{conn: conn} do
    lv = mount_as(conn, :spieler, members: [Fixtures.member("did-me", "spieler")])

    assert has_element?(lv, "[phx-click='rec_start']")
    refute has_element?(lv, "[phx-click='rec_start'][disabled]")
  end

  test "wer nicht Mitglied ist, kann nicht starten", %{conn: conn} do
    # Die verbliebene Grenze: Mitgliedschaft.
    lv = mount_as(conn, nil, members: [Fixtures.member("did-other", "spielleiter")])

    assert has_element?(lv, "[phx-click='rec_start'][disabled]")
  end
end
