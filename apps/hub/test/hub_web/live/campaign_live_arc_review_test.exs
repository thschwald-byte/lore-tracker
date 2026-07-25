defmodule HubWeb.CampaignLiveArcReviewTest do
  @moduledoc """
  Issue #905 (Epic #900 S3): das ⚠-Arc-Review-Register (verwaiste +
  gemergte Bögen) und die Fakt-Liste mit Fakt→Arc-Umhängen. Gepinnt:
  Register-Render mit Zähler + Vorauswahl, Undo-Fläche für Gemergte
  (auch wirkungslose = ⚠), Fakt-Listen-Toggle + Select mit Label-Kette-
  Undo, Publish-ohne-Worker-kein-Crash, Merge-ohne-Ziel → Flash.
  """

  use HubWeb.ConnCase, async: false

  defp thread(canonical, opts \\ []) do
    %{
      "canonical" => canonical,
      "key_canonical" => canonical,
      "kind" => "arc",
      "status" => Keyword.get(opts, :status, "offen"),
      "dismissed?" => false,
      "curated?" => false,
      "identity_action" => nil,
      "lifecycle_action" => nil,
      "kind_action" => nil,
      "resolution_suggested?" => false,
      "entities" => [],
      "fact_count" => 1,
      "opened_in_session" => 1,
      "last_touched_session" => 2,
      "sessions_touched" => [1, 2],
      "arc_id" => Keyword.get(opts, :arc_id),
      "arc_status" => Keyword.get(opts, :arc_status, "offen"),
      "arc_grund" => nil,
      "leitfrage" => Keyword.get(opts, :leitfrage),
      "leitfrage_kuratiert?" => false,
      "fact_list" => Keyword.get(opts, :fact_list, [])
    }
  end

  defp fact_entry(id, claim, opts \\ []) do
    %{
      "id" => id,
      "claim" => claim,
      "session_number" => Keyword.get(opts, :session, 2),
      "effective_arc_id" => Keyword.get(opts, :arc_id),
      "overridden?" => Keyword.get(opts, :overridden?, false)
    }
  end

  defp mount_panel(conn, threads, review) do
    snap =
      Fixtures.snapshot(
        campaign_id: "c-arcrev-905",
        name: "Review Kampagne",
        sessions: [%{"id" => "s-1", "number" => 1, "name" => "Eins"}],
        campaign_threads: threads,
        arc_review: review,
        members: [Fixtures.member("did-sp", "spieler")]
      )

    stub_reader!(snap)
    user = Fixtures.user(discord_id: "did-sp", display_name: "Spieler", campaign_role: :spieler)
    {:ok, lv, _html} = conn |> log_in(user) |> live("/campaigns/c-arcrev-905")
    render_async(lv)
    render_click(lv, "toggle_threads_panel", %{})
    lv
  end

  test "Review-Register: Zähler zugeklappt; Toggle zeigt Verwaisten mit Vorauswahl", %{
    conn: conn
  } do
    lv =
      mount_panel(
        conn,
        [thread("der Auftrag", arc_id: "arc_ziel")],
        %{
          "verwaiste" => [
            %{
              "arc_id" => "arc_orphan",
              "leitfrage" => "Verwaiste Frage?",
              "arc_status" => "geschlossen",
              "arc_grund" => "geloest",
              "seeds" => ["altes label"],
              "vorschlag_arc_id" => "arc_ziel"
            }
          ],
          "gemergte" => []
        }
      )

    html = render(lv)
    assert html =~ "1 verwaist"
    refute html =~ "Verwaiste Frage?"

    html = render_click(lv, "thread_toggle_arc_review", %{})
    assert html =~ "Verwaiste Frage?"
    assert html =~ "altes label"
    # Vorauswahl: das Ziel-Option-Element trägt selected.
    assert html =~ ~s(selected="selected" value="arc_ziel") or
             html =~ ~s(value="arc_ziel" selected)

    assert html =~ "zusammenführen"
  end

  test "Gemergte: Undo-Fläche + ⚠ für wirkungslose Redirects", %{conn: conn} do
    lv =
      mount_panel(
        conn,
        [thread("der Auftrag", arc_id: "arc_ziel")],
        %{
          "verwaiste" => [],
          "gemergte" => [
            %{
              "arc_id" => "arc_q",
              "leitfrage" => "Quelle?",
              "merge_into" => "arc_ziel",
              "wirksam?" => true
            },
            %{
              "arc_id" => "arc_z",
              "leitfrage" => "Zyklus?",
              "merge_into" => "arc_weg",
              "wirksam?" => false
            }
          ]
        }
      )

    render_click(lv, "thread_toggle_arc_review", %{})
    html = render(lv)
    assert html =~ "2 zusammengeführt"
    assert html =~ "↩ lösen"
    assert html =~ "Zyklus?"
    assert html =~ "wirkungslos"

    # Undo-Klick published ohne Worker → kein Crash.
    assert render_click(lv, "thread_arc_unmerge", %{"arc_id" => "arc_q"})
  end

  test "Merge ohne Ziel → Flash, kein Crash; mit Ziel published", %{conn: conn} do
    lv =
      mount_panel(conn, [thread("der Auftrag", arc_id: "arc_ziel")], %{
        "verwaiste" => [
          %{
            "arc_id" => "arc_orphan",
            "leitfrage" => "V?",
            "arc_status" => "offen",
            "arc_grund" => nil,
            "seeds" => [],
            "vorschlag_arc_id" => nil
          }
        ],
        "gemergte" => []
      })

    html =
      render_submit(lv, "thread_arc_merge_save", %{"arc_id" => "arc_orphan", "merge_into" => ""})

    assert html =~ "Ziel-Bogen wählen"

    assert render_submit(lv, "thread_arc_merge_save", %{
             "arc_id" => "arc_orphan",
             "merge_into" => "arc_ziel"
           })
  end

  test "Fakt-Liste: Toggle zeigt Claims + Umhäng-Select; Change published ohne Crash", %{
    conn: conn
  } do
    lv =
      mount_panel(
        conn,
        [
          thread("der Auftrag",
            arc_id: "arc_a",
            fact_list: [
              fact_entry("f1", "Der Prinz droht.", arc_id: "arc_a"),
              fact_entry("f2", "Umgehängt.", arc_id: "arc_a", overridden?: true)
            ]
          )
        ],
        %{"verwaiste" => [], "gemergte" => []}
      )

    html = render(lv)
    assert html =~ "2 Fakten"
    refute html =~ "Der Prinz droht."

    html = render_click(lv, "thread_toggle_facts", %{"canonical" => "der Auftrag"})
    assert html =~ "Der Prinz droht."
    assert html =~ "Label-Kette"
    assert html =~ "(S2)"

    # Select-Change published FactArcSet — ohne Worker kein Crash.
    assert render_change(lv, "thread_fact_arc_save", %{"fact_id" => "f1", "arc_id" => "arc_a"})

    # Erneuter Toggle schließt.
    html = render_click(lv, "thread_toggle_facts", %{"canonical" => "der Auftrag"})
    refute html =~ "Der Prinz droht."
  end
end
