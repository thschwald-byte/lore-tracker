defmodule HubWeb.NachleseLiveTest do
  @moduledoc """
  Issue #907 (Epic #900 S4): die Nachlese-Seite. Gepinnt: Render aller drei
  Blöcke + Themen-Register aus dem nachlese-förmigen Snapshot, Empty-States,
  forbidden-Redirect, Zurück-Link, zugeklappte Register (geschlossene Bögen
  + Themen erst nach Toggle).
  """

  use HubWeb.ConnCase, async: false

  defp nachlese_snap(opts \\ []) do
    %{
      "campaign" => %{"name" => "Free Seattle", "id" => "c-nachlese-907"},
      "recap" => Keyword.get(opts, :recap),
      "boegen_offen" => Keyword.get(opts, :offen, []),
      "boegen_geschlossen" => Keyword.get(opts, :geschlossen, []),
      "themen" => Keyword.get(opts, :themen, []),
      "who" => Keyword.get(opts, :who, [])
    }
  end

  defp bogen(titel, opts \\ []) do
    %{
      "titel" => titel,
      "leitfrage_kuratiert?" => false,
      "canonical" => titel,
      "arc_id" => Keyword.get(opts, :arc_id, "arc_x"),
      "arc_grund" => Keyword.get(opts, :arc_grund),
      "ruht?" => Keyword.get(opts, :ruht?, false),
      "fact_count" => 3,
      "opened_in_session" => 1,
      "last_touched_session" => Keyword.get(opts, :last, 2),
      "entities" => [],
      "entries" => Keyword.get(opts, :entries, [])
    }
  end

  defp mount_nachlese(conn, snap) do
    stub_reader!(snap)
    user = Fixtures.user(discord_id: "did-sp", display_name: "Spieler", campaign_role: :spieler)
    {:ok, lv, _html} = conn |> log_in(user) |> live("/campaigns/c-nachlese-907/nachlese")
    render_async(lv)
    lv
  end

  test "rendert Recap, offene Bögen (aktiv/ruhend) und Who's-who mit PC-Marker", %{conn: conn} do
    lv =
      mount_nachlese(
        conn,
        nachlese_snap(
          recap: %{
            "content_md" => "Romeo traf Julia auf dem Fest.",
            "flagged_claims" => [],
            "session_number" => 3,
            "session_name" => "Das Fest"
          },
          offen: [
            bogen("Erledigen sie Romeos Auftrag?"),
            bogen("Was wird aus der Fehde?", ruht?: true)
          ],
          who: [
            %{
              "alias" => "Skrapnik",
              "pc?" => true,
              "fact_count" => 4,
              "threads" => ["der Auftrag"],
              "last_session" => 5
            },
            %{
              "alias" => "Romeo",
              "pc?" => false,
              "fact_count" => 2,
              "threads" => [],
              "last_session" => 3
            }
          ]
        )
      )

    html = render(lv)
    assert html =~ "📖 Nachlese"
    assert html =~ "— Free Seattle"
    assert html =~ "Was war letztes Mal?"
    assert html =~ "Sitzung 3"
    assert html =~ "Das Fest"
    assert html =~ "Romeo traf Julia"
    assert html =~ "Erledigen sie Romeos Auftrag?"
    assert html =~ "💤"
    assert html =~ "· ruht"
    assert html =~ "Skrapnik"
    assert html =~ ">PC<"
    assert html =~ "← Arbeitsansicht"
  end

  test "Empty-States: kein Recap, keine Bögen, keine Figuren", %{conn: conn} do
    lv = mount_nachlese(conn, nachlese_snap())

    html = render(lv)
    assert html =~ "Noch kein Resümee"
    assert html =~ "Noch keine offenen Bögen"
    assert html =~ "Noch keine Figuren"
    refute html =~ "Themen — Weltwissen"
  end

  test "geschlossene Bögen + Themen sind zugeklappt, Toggle öffnet", %{conn: conn} do
    lv =
      mount_nachlese(
        conn,
        nachlese_snap(
          geschlossen: [bogen("Der alte Auftrag", arc_grund: "geloest")],
          themen: [
            %{
              "titel" => "die Welt von Shadowrun",
              "fact_count" => 12,
              "last_touched_session" => 2
            }
          ]
        )
      )

    html = render(lv)
    assert html =~ "1 abgeschlossen"
    refute html =~ "Der alte Auftrag"
    assert html =~ "1 Themen"
    refute html =~ "die Welt von Shadowrun"

    html = render_click(lv, "toggle_geschlossen", %{})
    assert html =~ "Der alte Auftrag"
    assert html =~ "(geloest)"

    html = render_click(lv, "toggle_themen", %{})
    assert html =~ "die Welt von Shadowrun"
  end

  # Issue #838: pro Bogen die volle Prosa-Progressions-Chronik statt nur der
  # einzelnen "N Fakt(en)..."-Zeile (Design K), Flagged-Claims-Hervorhebung
  # wiederverwendet denselben Recap-Helper wie das Session-Resümee.
  test "Bogen mit Prosa-Progressions-Einträgen zeigt die Chronik statt der Fakt(en)-Zeile",
       %{conn: conn} do
    lv =
      mount_nachlese(
        conn,
        nachlese_snap(
          offen: [
            bogen("Erledigen sie Romeos Auftrag?",
              entries: [
                %{
                  "session_number" => 1,
                  "content_md" => "Der Auftrag beginnt.",
                  "flagged_claims" => []
                },
                %{
                  "session_number" => 2,
                  "content_md" => "Ein Drache erschien.",
                  "flagged_claims" => ["Ein Drache erschien."]
                }
              ]
            )
          ]
        )
      )

    html = render(lv)
    assert html =~ "Sitzung 1:"
    assert html =~ "Der Auftrag beginnt."
    assert html =~ "Sitzung 2:"
    assert html =~ "Ein Drache erschien."
    refute html =~ "3 Fakt(en)"

    # #1124: `flagged_claims` steht in den Fixtures weiterhin — Alt-Events
    # tragen das Feld, Events sind unveränderlich. Angezeigt wird es nicht
    # mehr: mit dem Render-Gate ist auch die Markierung entfallen.
    refute html =~ "lt-unverified"
  end

  test "Bogen ohne Prosa-Progressions-Einträge fällt weiterhin auf die Fakt(en)-Zeile zurück", %{
    conn: conn
  } do
    lv = mount_nachlese(conn, nachlese_snap(offen: [bogen("Was wird aus der Fehde?")]))

    assert render(lv) =~ "3 Fakt(en)"
  end

  test "forbidden → Flash + Redirect zum Dashboard", %{conn: conn} do
    stub_reader!(%{"forbidden" => true})
    user = Fixtures.user(discord_id: "did-fremd", display_name: "Fremd", campaign_role: nil)
    {:ok, lv, _html} = conn |> log_in(user) |> live("/campaigns/c-nachlese-907/nachlese")

    assert_redirect(lv, "/")
  end

  test "CampaignLive verlinkt zur Nachlese", %{conn: conn} do
    snap =
      Fixtures.snapshot(
        campaign_id: "c-nachlese-907",
        name: "Free Seattle",
        members: [Fixtures.member("did-sp", "spieler")]
      )

    stub_reader!(snap)
    user = Fixtures.user(discord_id: "did-sp", display_name: "Spieler", campaign_role: :spieler)
    {:ok, lv, _html} = conn |> log_in(user) |> live("/campaigns/c-nachlese-907")
    render_async(lv)

    assert render(lv) =~ "/campaigns/c-nachlese-907/nachlese"
  end
end
