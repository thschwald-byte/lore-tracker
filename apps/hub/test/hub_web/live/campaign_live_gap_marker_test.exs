defmodule HubWeb.CampaignLiveGapMarkerTest do
  @moduledoc """
  Issue #917 (Epic #911, Cut 3): der reader-sichtbare Gap-Trust-Marker 🕳.

  Seit #1198 rechnet ihn der Worker (`Worker.Repo.GlattQuellen.marker/2`,
  getestet in `glatt_quellen_test.exs`) und schickt die Schlüssel der markierten
  Derivationen als `luecken_marker`. Hier gepinnt: der Hub übernimmt die Menge,
  lässt sie bei einer Antwort ohne Schlüssel stehen, und zeigt 🕳 genau dort.
  """

  use HubWeb.ConnCase, async: false

  alias HubWeb.CampaignLive.GapMarker

  defp sock(assigns),
    do: %Phoenix.LiveView.Socket{assigns: Map.put(assigns, :__changed__, %{})}

  describe "GapMarker (pur)" do
    test "uebernehmen: die Liste des Workers wird die Menge" do
      s = GapMarker.uebernehmen(sock(%{}), %{"luecken_marker" => ["summary:s-1", "chronik:c1"]})
      assert s.assigns.luecken_marker == MapSet.new(["summary:s-1", "chronik:c1"])
    end

    test "uebernehmen: eine Antwort OHNE Schlüssel ist keine Aussage — der Stand bleibt" do
      alt = MapSet.new(["summary:s-1"])
      s = GapMarker.uebernehmen(sock(%{luecken_marker: alt}), %{"chronik" => []})
      assert s.assigns.luecken_marker == alt
    end

    test "markiert?: Schlüssel aus Art und ID" do
      m = MapSet.new(["summary:s-1", "epos_chapter:s-2"])

      assert GapMarker.markiert?(m, "summary", "s-1")
      assert GapMarker.markiert?(m, "epos_chapter", "s-2")
      refute GapMarker.markiert?(m, "chronik", "s-1")
      refute GapMarker.markiert?(m, "summary", nil)
      refute GapMarker.markiert?(nil, "summary", "s-1")
    end
  end

  test "Resümee mit Marker zeigt 🕳, das andere nicht", %{conn: conn} do
    snap =
      Fixtures.snapshot(
        campaign_id: "c-gap",
        name: "Gap Kampagne",
        sessions: [%{"id" => "s-1", "number" => 1, "name" => "Eins"}],
        luecken_marker: ["summary:s-1"],
        summaries: [
          %{
            "session_id" => "s-1",
            "content_md" => "Resümee mit Lücke",
            "generated_at" => "2026-01-01T00:00:00Z",
            "source" => "llm",
            "source_refs" => ["b_gap"],
            "flagged_claims" => []
          },
          %{
            "session_id" => "s-2",
            "content_md" => "Sauberes Resümee",
            "generated_at" => "2026-01-02T00:00:00Z",
            "source" => "llm",
            "source_refs" => ["b_ok"],
            "flagged_claims" => []
          }
        ]
      )

    stub_reader!(snap)
    user = Fixtures.user(discord_id: "did-a", display_name: "A", campaign_role: :spieler)
    {:ok, lv, _html} = conn |> log_in(user) |> live("/campaigns/c-gap")
    render_async(lv)
    html = render(lv)

    assert html =~ "Resümee mit Lücke"
    assert html =~ "Sauberes Resümee"

    # Genau einmal: am markierten Resümee, nicht am sauberen.
    assert length(String.split(html, "unbestätigten ASR-Lücke")) - 1 == 1
  end
end
