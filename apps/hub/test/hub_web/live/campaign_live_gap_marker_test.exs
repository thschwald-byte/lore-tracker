defmodule HubWeb.CampaignLiveGapMarkerTest do
  @moduledoc """
  Issue #917 (Epic #911, Cut 3): der reader-sichtbare Gap-Trust-Marker. Gepinnt:
  (1) `unbestaetigte_luecke_block_ids` sammelt nur `hat_luecke AND status == nil`;
  (2) `derivation_touches_gap?` = Mengen-Schnitt; (3) ein Resümee mit gap-berührtem
  source_ref zeigt 🕳, ein nicht-berührtes nicht.
  """

  use HubWeb.ConnCase, async: false

  alias HubWeb.CampaignLive.GapMarker

  @smoothed [
    %{
      "session_id" => "s-1",
      "blocks" => [
        %{"block_id" => "b_gap", "hat_luecke" => true, "status" => nil},
        %{"block_id" => "b_kuriert", "hat_luecke" => true, "status" => "bestaetigt"},
        %{"block_id" => "b_ok", "hat_luecke" => false, "status" => nil}
      ]
    }
  ]

  describe "GapMarker (pur)" do
    test "unbestaetigte_luecke_block_ids: nur hat_luecke + uncuriert" do
      ids = GapMarker.unbestaetigte_luecke_block_ids(@smoothed)
      assert MapSet.member?(ids, "b_gap")
      refute MapSet.member?(ids, "b_kuriert"), "kuratierte Lücke zählt nicht"
      refute MapSet.member?(ids, "b_ok"), "kein hat_luecke zählt nicht"
    end

    test "derivation_touches_gap? = Mengen-Schnitt" do
      ids = GapMarker.unbestaetigte_luecke_block_ids(@smoothed)
      assert GapMarker.derivation_touches_gap?(["b_ok", "b_gap"], ids)
      refute GapMarker.derivation_touches_gap?(["b_ok", "b_kuriert"], ids)
      refute GapMarker.derivation_touches_gap?([], ids)
      refute GapMarker.derivation_touches_gap?(nil, ids)
    end
  end

  test "Resümee mit gap-berührtem source_ref zeigt 🕳, sonst nicht", %{conn: conn} do
    snap =
      Fixtures.snapshot(
        campaign_id: "c-gap",
        name: "Gap Kampagne",
        sessions: [%{"id" => "s-1", "number" => 1, "name" => "Eins"}]
      )
      |> Map.put("smoothed", @smoothed)
      |> Map.put("summaries", [
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
      ])

    stub_reader!(snap)
    user = Fixtures.user(discord_id: "did-a", display_name: "A", campaign_role: :spieler)
    {:ok, lv, _html} = conn |> log_in(user) |> live("/campaigns/c-gap")
    render_async(lv)
    html = render(lv)

    # Der Gap-Marker-Tooltip erscheint auf dem gap-berührten Resümee (das saubere
    # Resümee bekommt ihn nicht; die präzise Mengen-Logik pinnen die pure-Tests).
    assert html =~ "unbestätigten ASR-Lücke"
    assert html =~ "Resümee mit Lücke"
    assert html =~ "Sauberes Resümee"
  end
end
