defmodule HubWeb.CampaignLiveFragChatTest do
  @moduledoc """
  Issue #850, Chat-Modus: der Modus-Knopf, sein Zähler und der Abbruch.

  Am **echten Mount**, nicht an der Komponente allein: Der Modus lebt in den
  Assigns, wird von einem `phx-click` umgeschaltet und von der Antwort des
  Workers heruntergezählt — drei Stellen, die einzeln grün sein können, ohne
  dass der Knopf funktioniert (die #1090-Klasse: ein fehlendes Assign erzeugt
  keinen Fehler, sondern einen toten Knopf).
  """

  use HubWeb.ConnCase, async: false

  alias HubWeb.CampaignLive.FragFenster
  alias HubWeb.PipelineStatus

  defp mounten(conn) do
    snap =
      Fixtures.snapshot(
        campaign_id: "c-chat",
        name: "Chat Kampagne",
        members: [Fixtures.member("did-sp", "spieler")]
      )

    stub_reader!(snap)
    user = Fixtures.user(discord_id: "did-sp", display_name: "Spieler", campaign_role: :spieler)

    {:ok, lv, _html} = conn |> log_in(user) |> live("/campaigns/c-chat")
    _ = render_async(lv)
    lv
  end

  defp frag(lv), do: :sys.get_state(lv.pid).socket.assigns.frag

  defp lauf_setzen(lv, id) do
    :sys.replace_state(lv.pid, fn s ->
      put_in(s.socket.assigns.frag, %{s.socket.assigns.frag | lauf: %{id: id}, offen?: true})
    end)

    PipelineStatus.subscribe_frage(id)
    id
  end

  defp antwort(lv, id, extra \\ %{}) do
    send(
      lv.pid,
      {:pipeline_status,
       Map.merge(
         %{
           "kind" => "frage_antwort",
           "frage_lauf_id" => id,
           "text" => "Eine Antwort.",
           "fakt_ids" => [],
           "kurze_ids" => [],
           "geprueft" => "gestuetzt",
           "gespraech_weiter?" => true
         },
         extra
       )}
    )

    _ = render(lv)
  end

  test "der Anfangszustand ist Einzelfrage", %{conn: conn} do
    lv = mounten(conn)
    assert frag(lv).chat == nil
    assert render(lv) =~ "Jede Frage steht für sich"
  end

  test "ein Klick schaltet auf Chat, der nächste zurück", %{conn: conn} do
    lv = mounten(conn)

    render_click(lv, "frag_modus", %{})
    chat = frag(lv).chat
    assert %{rest: rest, id: id} = chat
    assert rest == FragFenster.chat_fragen()
    assert is_binary(id)
    assert render(lv) =~ "Chat max #{FragFenster.chat_fragen()}"
    refute render(lv) =~ "Jede Frage steht für sich"

    render_click(lv, "frag_modus", %{})
    assert frag(lv).chat == nil
  end

  test "jedes Einschalten vergibt eine NEUE Gesprächs-ID", %{conn: conn} do
    # Ohne das müsste das Ausschalten beim Worker aufräumen — und ein neues
    # Gespräch säße womöglich auf einem Verlauf, den im Fenster niemand mehr
    # sieht.
    lv = mounten(conn)

    render_click(lv, "frag_modus", %{})
    erste = frag(lv).chat.id
    render_click(lv, "frag_modus", %{})
    render_click(lv, "frag_modus", %{})

    refute frag(lv).chat.id == erste
  end

  test "eine Antwort zählt den Rest herunter", %{conn: conn} do
    lv = mounten(conn)
    render_click(lv, "frag_modus", %{})
    id = lauf_setzen(lv, "lauf-1")

    antwort(lv, id)

    assert frag(lv).chat.rest == FragFenster.chat_fragen() - 1
    assert render(lv) =~ "Chat max #{FragFenster.chat_fragen() - 1}"
  end

  test "bei null schaltet das Fenster auf Einzelfrage zurück", %{conn: conn} do
    lv = mounten(conn)
    render_click(lv, "frag_modus", %{})

    for i <- 1..FragFenster.chat_fragen() do
      id = lauf_setzen(lv, "lauf-#{i}")
      antwort(lv, id)
    end

    assert frag(lv).chat == nil
    assert render(lv) =~ "Jede Frage steht für sich"
  end

  test "ein Fehlschlag verbraucht KEINE Frage", %{conn: conn} do
    # Sonst wäre eine Frage weg, die nichts in den Verlauf gelegt hat — und
    # das liesse sich niemandem erklären.
    lv = mounten(conn)
    render_click(lv, "frag_modus", %{})
    id = lauf_setzen(lv, "lauf-fehl")

    send(
      lv.pid,
      {:pipeline_status, %{"kind" => "frage_fehler", "frage_lauf_id" => id, "grund" => "kaputt"}}
    )

    _ = render(lv)

    assert frag(lv).chat.rest == FragFenster.chat_fragen()
  end

  test "der Worker kann das Gespräch beenden", %{conn: conn} do
    # `gespraech_weiter? == false` heisst: Der Verlauf trägt die Fakten nicht
    # mehr wörtlich (er wurde zusammengefasst). Weiter Folgefragen darauf zu
    # stellen hiesse, Belege auf eine Zusammenfassung zu stützen.
    lv = mounten(conn)
    render_click(lv, "frag_modus", %{})
    id = lauf_setzen(lv, "lauf-ende")

    antwort(lv, id, %{"gespraech_weiter?" => false})

    assert frag(lv).chat == nil
  end

  test "der Abbruch-Knopf beendet den Lauf und sagt es", %{conn: conn} do
    lv = mounten(conn)
    id = lauf_setzen(lv, "lauf-ab")

    render_click(lv, "frag_abbrechen", %{})

    assert frag(lv).lauf == nil
    assert List.last(frag(lv).verlauf) == %{art: :fehler, text: "Abgebrochen."}
    refute render(lv) =~ "frag-warten"
    _ = id
  end

  test "ohne Lauf tut der Abbruch nichts", %{conn: conn} do
    lv = mounten(conn)
    vorher = frag(lv)

    render_click(lv, "frag_abbrechen", %{})

    assert frag(lv) == vorher
  end
end
