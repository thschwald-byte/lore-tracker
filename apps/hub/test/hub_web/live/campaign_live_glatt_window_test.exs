defmodule HubWeb.CampaignLiveGlattWindowTest do
  @moduledoc """
  Issue #883: die Geglättet-Spalte rendert lange Sessions nur als gleitendes
  #709-Fenster (Tail-Default + „ältere anzeigen"), statt des früheren harten
  200er-Reader-Caps, der ältere Blöcke unerreichbar machte. Das Fenster
  gleitet über die GEFILTERTE Ansicht-Liste; ein Ansicht-Wechsel resettet es.
  """

  use HubWeb.ConnCase, async: false

  alias HubWeb.CampaignLive.Components

  defp glatt_block(i, opts \\ []) do
    %{
      "block_id" => "b_#{String.pad_leading("#{i}", 4, "0")}",
      "speaker_discord_id" => "did-sp",
      "text" => "Blocktext Nummer #{i}",
      "text_smoothed" => "Blocktext Nummer #{i}",
      "roh_text" => "Blocktext Nummer #{i}",
      "vorschlag_text" => nil,
      "vorschlag_modell" => nil,
      "quell_utterance_ids" => ["u-#{i}"],
      "hat_luecke" => Keyword.get(opts, :luecke, false),
      "override" => nil,
      "status" => Keyword.get(opts, :status)
    }
  end

  defp smoothed_session(blocks) do
    %{
      "session_id" => "s-1",
      "session_number" => 1,
      "rules_version" => 42,
      "merge_gap_seconds" => 8,
      "ooc_verworfen_count" => 0,
      "verwaist" => [],
      "blocks" => blocks
    }
  end

  defp mount_glatt(conn, blocks) do
    snap =
      Fixtures.snapshot(
        campaign_id: "c-glatt-window",
        name: "Glatt Window Kampagne",
        sessions: [%{"id" => "s-1", "number" => 1, "name" => "Lange Session"}],
        smoothed: [smoothed_session(blocks)],
        members: [Fixtures.member("did-sp", "spieler")]
      )

    stub_reader!(snap)
    user = Fixtures.user(discord_id: "did-sp", display_name: "Spieler", campaign_role: :spieler)
    {:ok, lv, _html} = conn |> log_in(user) |> live("/campaigns/c-glatt-window")
    render_async(lv)
    lv
  end

  defp count_anchors(html),
    do: html |> String.split("data-anchor-id=") |> length() |> Kernel.-(1)

  test "lange Session rendert nur das Tail-Fenster + 'ältere anzeigen'", %{conn: conn} do
    n = Components.window_default() + 300
    blocks = for i <- 1..n, do: glatt_block(i)
    lv = mount_glatt(conn, blocks)
    html = render(lv)

    assert count_anchors(html) == Components.window_default()
    assert html =~ "ältere anzeigen"
    # neuester Block sichtbar, ältester nicht (Tail-Default).
    assert html =~ ~s(data-anchor-id="b_#{String.pad_leading("#{n}", 4, "0")}")
    refute html =~ ~s(data-anchor-id="b_0001")
  end

  test "'ältere anzeigen' schiebt das Fenster; count bleibt ≤ window_max", %{conn: conn} do
    n = Components.window_max() * 3
    blocks = for i <- 1..n, do: glatt_block(i)
    lv = mount_glatt(conn, blocks)

    Enum.each(1..30, fn _ ->
      render_click(lv, "luecke_load_older", %{"session_id" => "s-1"})
    end)

    html = render(lv)
    assert count_anchors(html) <= Components.window_max()
    # Bis zum Anfang durchgeblättert: ältester Block sichtbar, Bottom-Sentinel da.
    assert html =~ ~s(data-anchor-id="b_0001")
    assert html =~ "neuere anzeigen"
  end

  test "kuratieren-Ansicht fenstert über die GEFILTERTE Liste", %{conn: conn} do
    # 300 Blöcke, davon nur 5 offene Lücken (weit vorne) → Auto-Default ist
    # kuratieren, und ALLE 5 müssen ohne Sentinel sichtbar sein (nach
    # Fensterung über die Rohliste wäre das rot: die Lücken lägen evinct).
    n = Components.window_default() + 150

    blocks =
      for i <- 1..n do
        glatt_block(i, luecke: i in 1..5)
      end

    lv = mount_glatt(conn, blocks)
    html = render(lv)

    assert count_anchors(html) == 5
    refute html =~ "ältere anzeigen"
    assert html =~ "🕳"
  end

  test "Ansicht-Wechsel resettet das Fenster auf den Tail-Default", %{conn: conn} do
    n = Components.window_default() + 300
    blocks = for i <- 1..n, do: glatt_block(i)
    lv = mount_glatt(conn, blocks)

    # Fenster nach vorn blättern, dann Ansicht wechseln → wieder Tail.
    Enum.each(1..5, fn _ ->
      render_click(lv, "luecke_load_older", %{"session_id" => "s-1"})
    end)

    render_click(lv, "luecke_view", %{"session_id" => "s-1", "view" => "alles"})
    html = render(lv)

    assert html =~ ~s(data-anchor-id="b_#{String.pad_leading("#{n}", 4, "0")}")
    assert count_anchors(html) == Components.window_default()
  end
end
