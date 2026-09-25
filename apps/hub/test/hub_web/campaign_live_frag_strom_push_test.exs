defmodule HubWeb.CampaignLiveFragStromPushTest do
  @moduledoc """
  Issue #850: der Denkstrom erreicht den Browser als Ereignis `"frag_strom"`.

  Der Worker meldet gedrosselt, der Hub routet auf den Topic **dieses Laufs**,
  und die LiveView pusht ihn an den Hook — nie in die Assigns (#1146). Jedes
  Glied für sich ist anderswo geprüft; hier hängt die Kette am **echten
  Mount**, weil ein vergessenes Abonnement oder eine falsch sortierte
  `handle_info`-Klausel sonst still bliebe: Das Fenster zeigte dann einfach
  nichts, und nichts würde rot.
  """

  use HubWeb.ConnCase, async: false

  alias HubWeb.PipelineStatus

  defp mounten(conn) do
    snap =
      Fixtures.snapshot(
        campaign_id: "c-strom",
        name: "Strom Kampagne",
        members: [Fixtures.member("did-sp", "spieler")]
      )

    stub_reader!(snap)
    user = Fixtures.user(discord_id: "did-sp", display_name: "Spieler", campaign_role: :spieler)

    {:ok, lv, _html} = conn |> log_in(user) |> live("/campaigns/c-strom")
    _ = render_async(lv)
    lv
  end

  # Der Weg, den `FragFenster.starte/2` nimmt: Lauf-ID vergeben, Topic
  # abonnieren, fragen. Hier ohne Worker — geprüft wird der Rückweg.
  defp lauf_setzen(lv, id) do
    :sys.replace_state(lv.pid, fn s ->
      put_in(s.socket.assigns.frag, %{s.socket.assigns.frag | lauf: %{id: id}, offen?: true})
    end)

    PipelineStatus.subscribe_frage(id)
    id
  end

  test "ein Strom-Stück erreicht den Browser als Ereignis", %{conn: conn} do
    lv = mounten(conn)
    id = lauf_setzen(lv, "lauf-strom-1")

    # Der LiveView-Prozess muss selbst abonniert haben — `subscribe_frage` oben
    # gilt für diesen Testprozess. Deshalb direkt an die View senden, wie es
    # PubSub täte.
    send(
      lv.pid,
      {:pipeline_status,
       %{
         "kind" => "frage_strom",
         "frage_lauf_id" => id,
         "stuecke" => [%{"art" => "werkzeug", "text" => "cast()"}]
       }}
    )

    _ = render(lv)

    assert_push_event(lv, "frag_strom", %{stuecke: [%{"art" => "werkzeug", "text" => "cast()"}]})
  end

  test "der Strom landet NICHT im Verlauf — er wächst sonst im Socket (#1146)", %{conn: conn} do
    lv = mounten(conn)
    id = lauf_setzen(lv, "lauf-strom-2")

    for i <- 1..5 do
      send(
        lv.pid,
        {:pipeline_status,
         %{
           "kind" => "frage_strom",
           "frage_lauf_id" => id,
           "stuecke" => [%{"art" => "denken", "text" => "Gedanke #{i}"}]
         }}
      )
    end

    _ = render(lv)

    frag = :sys.get_state(lv.pid).socket.assigns.frag
    assert frag.verlauf == [], "der Strom darf sich nicht im Verlauf sammeln"
    assert frag.lauf == %{id: id}, "der Lauf läuft weiter"
  end

  test "die Antwort beendet den Lauf und landet im Verlauf", %{conn: conn} do
    lv = mounten(conn)
    id = lauf_setzen(lv, "lauf-strom-3")

    send(
      lv.pid,
      {:pipeline_status,
       %{
         "kind" => "frage_antwort",
         "frage_lauf_id" => id,
         "text" => "Die Antwort.",
         "kurze_ids" => ["S1-F1"],
         "fakt_ids" => ["f_eins"],
         "geprueft" => "gestuetzt"
       }}
    )

    _ = render(lv)

    frag = :sys.get_state(lv.pid).socket.assigns.frag
    assert [%{art: :antwort, text: "Die Antwort."}] = frag.verlauf
    assert frag.lauf == nil
  end

  test "ein Stück zu einem fremden Lauf erreicht den Browser nicht", %{conn: conn} do
    lv = mounten(conn)
    _ = lauf_setzen(lv, "meiner")

    send(
      lv.pid,
      {:pipeline_status,
       %{
         "kind" => "frage_strom",
         "frage_lauf_id" => "fremder",
         "stuecke" => [%{"art" => "denken", "text" => "nicht für mich"}]
       }}
    )

    _ = render(lv)

    refute_push_event(lv, "frag_strom", %{}, 100)
  end
end
