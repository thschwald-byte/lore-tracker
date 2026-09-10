defmodule HubWeb.CampaignLive.FaktenFensterTest do
  @moduledoc """
  Issue #1204: die Fakten-Spalte bekommt je Session nur ein Fenster, die
  Review-Liste reist im Haupt-Snapshot nur als Zahl. Festgehalten wird, dass
  der Hub die richtigen Fragen stellt (sonst holt er still wieder alles —
  #1153-Klasse, kein Test würde rot), dass die Blätterknöpfe aus den
  Worker-Zahlen entstehen und dass ein Worker vor #1204 weiter funktioniert.
  """
  use HubWeb.ConnCase, async: false

  alias HubWeb.CampaignLive.{Components, FaktenFenster}

  describe "ergaenze/3" do
    test "campaign_facts bekommt Tail und die geblätterten Fenster" do
      assert FaktenFenster.ergaenze(%{}, "campaign_facts", %{fakten_windows: %{"s-1" => {20, 30}}}) ==
               %{
                 "fakten_tail" => FaktenFenster.tail(),
                 "fakten_fenster" => %{"s-1" => %{"from" => 20, "count" => 30}}
               }
    end

    test "ohne geblätterte Fenster: nur der Tail" do
      assert FaktenFenster.ergaenze(%{}, "campaign_facts", %{}) ==
               %{"fakten_tail" => 50, "fakten_fenster" => %{}}
    end

    test "andere Scopes bleiben unberührt" do
      assert FaktenFenster.ergaenze(%{"refs" => "aufgeloest"}, "campaign_summaries", %{
               fakten_windows: %{"s-1" => {1, 2}}
             }) == %{"refs" => "aufgeloest"}
    end
  end

  describe "verborgen/3" do
    test "davor und danach aus Gesamtzahl, Start und geladener Menge" do
      fenster = %{
        "s-1" => %{"total" => 120, "from" => 70},
        "s-2" => %{"total" => 120, "from" => 20}
      }

      assert FaktenFenster.verborgen(fenster, "s-1", 50) == {70, 0}
      assert FaktenFenster.verborgen(fenster, "s-2", 30) == {20, 70}
    end

    test "ohne Zahlen vom Worker nichts zu blättern" do
      assert FaktenFenster.verborgen(nil, "s-1", 860) == {0, 0}
      assert FaktenFenster.verborgen(%{}, "s-1", 3) == {0, 0}
    end
  end

  describe "in der Ansicht" do
    defp fakt(i) do
      %{
        "id" => "f_#{i}",
        "session_id" => "s-1",
        "claim" => "Behauptung Nummer #{i}",
        "character_alias" => "Unbekannt",
        "thread" => "",
        "verified?" => true,
        "source_refs" => [],
        "quell_utterance_ids" => ["u-#{i}"]
      }
    end

    defp haupt do
      Fixtures.snapshot(
        campaign_id: "c-fenster",
        name: "Fenster Kampagne",
        sessions: [%{"id" => "s-1", "number" => 1, "name" => "Eins"}],
        members: [Fixtures.member("did-a", "spieler")]
      )
    end

    # Der Stub antwortet je Scope und meldet jede Frage an den Test.
    defp mount(conn, fakten_antwort) do
      test_pid = self()
      haupt = haupt()

      stub_reader_fn!(fn scope ->
        send(test_pid, {:gelesen, scope})

        case scope["kind"] do
          "campaign_facts" -> {:ok, fakten_antwort}
          _ -> {:ok, haupt}
        end
      end)

      user = Fixtures.user(discord_id: "did-a", display_name: "A", campaign_role: :spieler)
      {:ok, lv, _html} = conn |> log_in(user) |> live("/campaigns/c-fenster")
      render_async(lv)
      render_click(lv, "view_mode_toggle", %{"mode" => "bearbeiten"})
      render_async(lv)
      lv
    end

    defp fragen(kind) do
      Stream.repeatedly(fn ->
        receive do
          {:gelesen, %{"kind" => ^kind} = scope} -> scope
          {:gelesen, _} -> :anderes
        after
          200 -> :ende
        end
      end)
      |> Enum.take_while(&(&1 != :ende))
      |> Enum.reject(&(&1 == :anderes))
    end

    # Alle gemeldeten Fragen bis zur Marke, in Reihenfolge.
    defp sammle(acc) do
      receive do
        {:gelesen, scope} -> sammle([scope | acc])
        :marke -> Enum.reverse(acc)
      end
    end

    defp gefenstert do
      %{
        "facts" => Enum.map(71..120, &fakt/1),
        "fakten_fenster" => %{"s-1" => %{"total" => 120, "from" => 70}}
      }
    end

    test "Haupt-Anfrage fragt nur nach der Review-Zahl, Fakten mit Tail 50", %{conn: conn} do
      test_pid = self()
      _lv = mount(conn, gefenstert())

      # Alle Fragen liegen schon im Postfach; die Marke begrenzt das Einsammeln.
      send(test_pid, :marke)
      scopes = sammle([])

      haupt = Enum.find(scopes, &(&1["kind"] == "campaign"))
      assert haupt["review_facts"] == "anzahl"

      fakten = Enum.find(scopes, &(&1["kind"] == "campaign_facts"))
      assert fakten["fakten_tail"] == 50
      assert fakten["fakten_fenster"] == %{}
    end

    test "Blätterknöpfe aus den Worker-Zahlen; ältere anzeigen fragt verschoben", %{conn: conn} do
      lv = mount(conn, gefenstert())
      html = render(lv)

      assert has_element?(lv, "[data-col='fakten'] [data-anchor-id='f_120']")
      assert has_element?(lv, "[data-col='fakten'] [data-anchor-id='f_71']")
      refute has_element?(lv, "[data-col='fakten'] [data-anchor-id='f_70']")
      assert html =~ "↑ 70 ältere anzeigen"
      refute html =~ "neuere anzeigen"

      _ = fragen("campaign_facts")

      render_click(lv, "fact_fenster", %{"session" => "s-1", "richtung" => "older"})
      render_async(lv)

      assert [scope] = fragen("campaign_facts")
      {from, count} = Components.window_older({70, 50}, 120)
      assert scope["fakten_fenster"] == %{"s-1" => %{"from" => from, "count" => count}}
      assert scope["fakten_tail"] == 50
    end

    test "unbekannte Richtung oder Session: nichts passiert", %{conn: conn} do
      lv = mount(conn, gefenstert())
      _ = fragen("campaign_facts")

      render_click(lv, "fact_fenster", %{"session" => "s-1", "richtung" => "seitwärts"})
      render_click(lv, "fact_fenster", %{"session" => "s-9", "richtung" => "older"})
      render_async(lv)

      assert fragen("campaign_facts") == []
    end

    test "Worker vor #1204 (volle Liste, keine Zahlen): alles da, keine Knöpfe", %{conn: conn} do
      lv = mount(conn, %{"facts" => Enum.map(1..120, &fakt/1)})
      html = render(lv)

      assert has_element?(lv, "[data-col='fakten'] [data-anchor-id='f_1']")
      assert has_element?(lv, "[data-col='fakten'] [data-anchor-id='f_120']")
      refute html =~ "ältere anzeigen"
    end
  end
end
