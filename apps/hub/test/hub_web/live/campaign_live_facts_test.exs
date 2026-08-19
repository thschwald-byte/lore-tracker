defmodule HubWeb.CampaignLiveFactsTest do
  @moduledoc """
  Issue #916 (Epic #911, Cut 2): die editierbare Fakten-Spalte. Gepinnt:
  (1) :curate_facts = Member-Recht; (2) im Bearbeiten-Modus rendert die Spalte
  die Fakten + Edit-Affordances; (3) Inline-Edit öffnet ein Formular; (4) Save
  crasht ohne Worker nicht (Flash-Pfad); (5) im Lesemodus keine Fakten-Spalte.
  """

  use HubWeb.ConnCase, async: false

  alias HubWeb.Permissions

  test "curate_facts = Member-Recht" do
    member = %{role: :spieler, campaign_role: :spieler}
    fremd = %{role: :spieler, campaign_role: nil}
    assert Permissions.can?(member, :curate_facts, %{"id" => "c"})
    refute Permissions.can?(fremd, :curate_facts, %{"id" => "c"})
  end

  defp fact(id) do
    %{
      "id" => id,
      "session_id" => "s-1",
      "claim" => "Holmes untersucht den Tatort",
      "character_alias" => "Unbekannt",
      "thread" => "",
      "verified?" => true,
      "source_refs" => ["b1"],
      "quell_utterance_ids" => ["u1", "u2"]
    }
  end

  defp mount(conn) do
    snap =
      Fixtures.snapshot(
        campaign_id: "c-facts",
        name: "Fakten Kampagne",
        sessions: [%{"id" => "s-1", "number" => 1, "name" => "Eins"}],
        members: [Fixtures.member("did-a", "spieler")]
      )
      |> Map.put("facts", [fact("f_1")])

    stub_reader!(snap)
    user = Fixtures.user(discord_id: "did-a", display_name: "A", campaign_role: :spieler)
    {:ok, lv, _html} = conn |> log_in(user) |> live("/campaigns/c-facts")
    render_async(lv)
    lv
  end

  test "Lesemodus: keine Fakten-Spalte", %{conn: conn} do
    html = render(mount(conn))
    refute html =~ "Holmes untersucht den Tatort"
  end

  test "Bearbeiten-Modus: Fakten-Spalte rendert Claim + Edit-Affordance", %{conn: conn} do
    lv = mount(conn)
    render_click(lv, "view_mode_toggle", %{"mode" => "bearbeiten"})
    # Der campaign_facts-Scope lädt async → flushen.
    html = render_async(lv)
    assert html =~ "Holmes untersucht den Tatort"
    # Edit-Pencil vorhanden (character-Feld).
    assert html =~ "fact_edit_start"
  end

  # Issue #1095: die andere Hälfte des Scroll-Sync-Fehlers. Der Index allein
  # genügt nicht — der IntersectionObserver in `column_sync.js` beobachtet
  # ausschliesslich `[data-anchor-id]` bzw. `[data-utterance-id]`. Fehlt das
  # Attribut, findet er in der Spalte nichts, und sie kann weder führen noch
  # folgen. Genau das war der Zustand: die Spalte war für den Hook sichtbar
  # (`data-col="fakten"`), aber leer an Ankern.
  test "Bearbeiten-Modus: jede Fakt-Zeile trägt einen Sync-Anker", %{conn: conn} do
    lv = mount(conn)
    render_click(lv, "view_mode_toggle", %{"mode" => "bearbeiten"})
    render_async(lv)

    assert has_element?(lv, "[data-col='fakten'] [data-anchor-id='f_1']")
  end

  test "Inline-Edit öffnet ein Formular", %{conn: conn} do
    lv = mount(conn)
    render_click(lv, "view_mode_toggle", %{"mode" => "bearbeiten"})
    render_async(lv)

    html =
      render_click(lv, "fact_edit_start", %{
        "session" => "s-1",
        "fact" => "f_1",
        "field" => "claim"
      })

    assert html =~ ~s(phx-submit="fact_save")
  end

  test "Save ohne Worker crasht nicht (Flash-Pfad)", %{conn: conn} do
    lv = mount(conn)
    render_click(lv, "view_mode_toggle", %{"mode" => "bearbeiten"})
    render_async(lv)

    render_click(lv, "fact_toggle", %{
      "session" => "s-1",
      "quell" => "u1,u2",
      "field" => "verified",
      "value" => "false"
    })

    assert Process.alive?(lv.pid)
  end
end
