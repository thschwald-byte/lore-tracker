defmodule HubWeb.CampaignLiveLaufbandTest do
  @moduledoc """
  Issue #1122: das Laufband — Ableitungen und Sichtbarkeit.

  Dazu der Fund, der beim Bauen auffiel: `start_async/3` bricht einen laufenden
  Task mit gleichem Namen ab. Beide Scope-Loads hießen `:reload_scope`, der
  zweite hat den ersten also abgeschossen — ein Bug, der im Bestand schon lag
  und erst sichtbar wurde, als überhaupt zwei Loads zusammentrafen.
  """
  use HubWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias HubWeb.CampaignLive.Laufband
  alias HubWeb.Fixtures

  defp stufe(name, status, fertig \\ 0, gesamt \\ nil) do
    %{
      "name" => name,
      "titel" => name,
      "spalte" => nil,
      "status" => status,
      "fertig" => fertig,
      "gesamt" => gesamt,
      "dauer_ms" => 0
    }
  end

  defp lauf(stufen, extra \\ %{}) do
    Map.merge(
      %{
        "aktiv" => true,
        "run_id" => "r1",
        "session_id" => "s-1",
        "campaign_id" => "c-1",
        "gestartet_vor_ms" => 1000,
        "still_seit_ms" => 0,
        "stufen" => stufen
      },
      extra
    )
  end

  describe "Schritt-Nummer" do
    test "nennt die laufende Stufe" do
      l = lauf([stufe("smooth", "fertig"), stufe("extract", "laeuft"), stufe("verify", "offen")])

      assert Laufband.schritt(l) == 2
    end

    test "ohne laufende Stufe die zuletzt erledigte — nicht 1" do
      l = lauf([stufe("smooth", "fertig"), stufe("extract", "fertig"), stufe("verify", "offen")])

      assert Laufband.schritt(l) == 2
    end
  end

  describe "Zahl an der Stufe" do
    test "vier von sieben" do
      assert Laufband.zahl(stufe("extract", "laeuft", 4, 7)) == "4/7"
    end

    test "keine Zahl, wo es nichts zu zählen gibt" do
      # Resümee/Chronik/Epos sind je ein einzelner Aufruf — „1/1" wäre eine
      # Attrappe.
      refute Laufband.zahl(stufe("render", "laeuft", 0, nil))
    end

    test "keine Zahl, solange die Gesamtzahl unbekannt ist — „3/?\" ist keine Auskunft" do
      refute Laufband.zahl(stufe("extract", "laeuft", 3, nil))
    end
  end

  describe "Sichtbarkeit" do
    test "beendeter Lauf verschwindet" do
      refute Laufband.sichtbar?(lauf([], %{"aktiv" => false}), nil)
    end

    test "ein Replay hält das Band auch zwischen zwei Sessions" do
      # Zwischen zwei Sessions gibt es kurz keinen aktiven Einzellauf. Ohne
      # diese Bedingung flackerte das Band bei jedem Sessionwechsel weg.
      assert Laufband.sichtbar?(nil, %{current: 4, total: 26})
    end

    test "ohne alles bleibt es weg" do
      refute Laufband.sichtbar?(nil, nil)
    end
  end

  describe "Stille-Warnung" do
    test "ein Lauf ohne Regung wird als solcher markiert, statt Fortschritt zu behaupten" do
      assert Laufband.still?(%{"still_seit_ms" => 11 * 60 * 1000})
      refute Laufband.still?(%{"still_seit_ms" => 30_000})
    end
  end

  describe "Scope-Loads (Fund beim Bauen)" do
    test "zwei Scope-Loads beim Mount schießen sich nicht gegenseitig ab" do
      snap =
        Fixtures.snapshot(
          campaign_id: "c-band",
          name: "Band",
          sessions: [%{"id" => "s-1", "number" => 1, "name" => "Eins"}],
          summaries: [
            %{
              "session_id" => "s-1",
              "campaign_id" => "c-band",
              "content_md" => "Resümee-Text",
              "generated_at" => "2026-01-01T00:00:00Z",
              "source" => "llm",
              "source_refs" => [],
              "flagged_claims" => []
            }
          ],
          members: [Fixtures.member("did-a", "spieler")]
        )
        |> Map.put("flags", [
          %{
            "flag_key" => "c-band:session:s-1",
            "target_kind" => "session",
            "target_id" => "s-1",
            "raised_by" => "did-a",
            "note" => "das stimmt nicht",
            "status" => "raised",
            "effective_status" => "raised",
            "event_id" => "e1"
          }
        ])

      stub_reader!(snap)
      user = Fixtures.user(discord_id: "did-a", display_name: "did-a", campaign_role: :spieler)
      {:ok, lv, _html} = conn_for(user) |> live("/campaigns/c-band")
      render_async(lv)

      # Der Flags-Load läuft beim Mount zusammen mit dem Pipeline-Load. Käme
      # nur einer durch, wäre `flags` leer und der ⚠-Marker fehlte.
      assert render(lv) =~ "⚠ gemeldet"
    end
  end

  defp conn_for(user), do: log_in(Phoenix.ConnTest.build_conn(), user)
end
