defmodule HubWeb.CampaignLiveGlattWindowTest do
  @moduledoc """
  Die Geglättet-Spalte im Hub seit #1198: Filter, Fenster und Zähler rechnet
  der Worker (`Worker.Repo.GlattAnsicht`, dort getestet). Der Hub zeigt, was
  kommt, und schickt die richtige Frage zurück — das halten diese Tests fest:

  - Er rendert genau die gelieferten Blöcke und leitet die „ältere/neuere
    anzeigen"-Zahlen aus `from` und `gefiltert_total` ab.
  - Ein Fensterschritt fragt NUR diese Session, mit dem verschobenen Fenster.
  - Ein Ansichtswechsel schickt die gewählte Ansicht und den Tail.
  - Kennt der Worker den Scope nicht (Deploy-Fenster), steht ein Hinweis in der
    Spalte, und es folgt KEIN weiterer Voll-Read — genau die Schleife, die
    `campaign_live.ex` bei `unknown_scope` sonst drehen würde.
  """

  use HubWeb.ConnCase, async: false

  alias HubWeb.CampaignLive.Components

  defp block(i, opts \\ []) do
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

  # Eine Session so, wie sie der Worker liefert (`Worker.Repo.GlattAnsicht`).
  defp sitzung(bloecke, opts) do
    %{
      "session_id" => "s-1",
      "session_number" => 1,
      "rules_version" => 42,
      "merge_gap_seconds" => 8,
      "ooc_verworfen_count" => 0,
      "praesenz_ping_verworfen_count" => 0,
      "verwaist" => [],
      "ansicht" => Keyword.get(opts, :ansicht, "einfach"),
      "ansicht_auto" => Keyword.get(opts, :ansicht, "einfach"),
      "kuratieren_count" => Keyword.get(opts, :kuratieren_count, 0),
      "block_count" => Keyword.fetch!(opts, :block_count),
      "gefiltert_total" => Keyword.fetch!(opts, :gefiltert_total),
      "from" => Keyword.fetch!(opts, :from),
      "blocks" => bloecke
    }
  end

  defp haupt_snapshot do
    Fixtures.snapshot(
      campaign_id: "c-glatt-window",
      name: "Glatt Window Kampagne",
      sessions: [%{"id" => "s-1", "number" => 1, "name" => "Lange Session"}],
      members: [Fixtures.member("did-sp", "spieler")]
    )
  end

  # Der Stub antwortet je Scope und meldet jede Frage an den Test.
  defp mount(conn, ansicht_antwort) do
    test_pid = self()
    haupt = haupt_snapshot()

    stub_reader_fn!(fn scope ->
      send(test_pid, {:gelesen, scope})

      case scope["kind"] do
        "campaign_glatt_ansicht" -> ansicht_antwort
        _ -> {:ok, haupt}
      end
    end)

    user = Fixtures.user(discord_id: "did-sp", display_name: "Spieler", campaign_role: :spieler)
    {:ok, lv, _html} = conn |> log_in(user) |> live("/campaigns/c-glatt-window")
    # Zwei Runden: erst der Voll-Read, dessen Antwort startet den Ansicht-Read.
    render_async(lv)
    render_async(lv)
    lv
  end

  defp ansicht_ok(sitzungen),
    do: {:ok, %{"glatt_ansicht" => sitzungen, "nur" => nil, "luecken_marker" => []}}

  defp anker(html), do: html |> String.split("data-anchor-id=\"b_") |> length() |> Kernel.-(1)

  defp ansicht_fragen do
    Stream.repeatedly(fn ->
      receive do
        {:gelesen, %{"kind" => "campaign_glatt_ansicht"} = scope} -> scope
        {:gelesen, _} -> :anderes
      after
        200 -> :ende
      end
    end)
    |> Enum.take_while(&(&1 != :ende))
    |> Enum.reject(&(&1 == :anderes))
  end

  test "rendert genau die gelieferten Blöcke, Zahlen aus from/gefiltert_total", %{conn: conn} do
    bloecke = for i <- 301..450, do: block(i)

    lv =
      mount(
        conn,
        ansicht_ok([sitzung(bloecke, block_count: 450, gefiltert_total: 450, from: 300)])
      )

    html = render(lv)

    assert anker(html) == 150
    assert html =~ "300 ältere anzeigen"
    refute html =~ "neuere anzeigen"
    assert html =~ "450 Blöcke"
  end

  test "ältere anzeigen fragt NUR diese Session, mit verschobenem Fenster", %{conn: conn} do
    bloecke = for i <- 301..450, do: block(i)

    lv =
      mount(
        conn,
        ansicht_ok([sitzung(bloecke, block_count: 450, gefiltert_total: 450, from: 300)])
      )

    _ = ansicht_fragen()

    render_click(lv, "luecke_load_older", %{"session_id" => "s-1"})
    render_async(lv)

    assert [scope] = ansicht_fragen()
    assert scope["nur"] == ["s-1"]

    # window_older({300, 150}, 450): ein Schritt zurück, gedeckelt auf 200.
    {from, count} = Components.window_older({300, 150}, 450)
    assert scope["sitzungen"]["s-1"]["fenster"] == %{"from" => from, "count" => count}

    # Die Ansicht wurde nie gewählt — sie geht als nil, sonst stürbe der
    # Auto-Wechsel des Workers.
    assert scope["sitzungen"]["s-1"]["ansicht"] == nil
  end

  test "Ansichtswechsel schickt die Wahl und den Tail", %{conn: conn} do
    bloecke = for i <- 1..5, do: block(i, luecke: true)

    lv =
      mount(
        conn,
        ansicht_ok([
          sitzung(bloecke,
            ansicht: "kuratieren",
            kuratieren_count: 5,
            block_count: 300,
            gefiltert_total: 5,
            from: 0
          )
        ])
      )

    html = render(lv)
    assert html =~ "kuratieren"
    assert html =~ "(5)"
    _ = ansicht_fragen()

    render_click(lv, "luecke_view", %{"session_id" => "s-1", "view" => "alles"})
    render_async(lv)

    assert [scope] = ansicht_fragen()
    assert scope["nur"] == ["s-1"]
    assert scope["sitzungen"]["s-1"]["ansicht"] == "alles"
    assert scope["sitzungen"]["s-1"]["fenster"] == %{"tail" => Components.window_default()}
  end

  test "✓ Nichts zu kuratieren, wenn die Kuratier-Ansicht leer ist", %{conn: conn} do
    lv =
      mount(
        conn,
        ansicht_ok([
          sitzung([], ansicht: "kuratieren", block_count: 12, gefiltert_total: 0, from: 0)
        ])
      )

    assert render(lv) =~ "Nichts zu kuratieren"
  end

  test "alter Worker: Hinweis in der Spalte, KEIN weiterer Voll-Read", %{conn: conn} do
    lv = mount(conn, {:ok, %{"error" => "unknown_scope"}})

    assert render(lv) =~ "Der Worker wird gerade aktualisiert"

    # Die Fragen des Mounts abräumen — der eine Voll-Read ist gewollt.
    assert voll_reads() == 1

    # Ein zweiter Voll-Read wäre der Anfang der Schleife aus campaign_live.ex
    # (unknown_scope → schedule_reload (150 ms) → Voll-Read → Ansicht → …).
    Process.sleep(400)
    assert voll_reads() == 0, "nach unknown_scope folgte ein weiterer Voll-Read — die Schleife"
  end

  defp voll_reads do
    Stream.repeatedly(fn ->
      receive do
        {:gelesen, %{"kind" => "campaign"}} -> :voll
        {:gelesen, _} -> :anderes
      after
        0 -> :ende
      end
    end)
    |> Enum.take_while(&(&1 != :ende))
    |> Enum.count(&(&1 == :voll))
  end
end
