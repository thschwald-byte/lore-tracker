defmodule Worker.Jack.Zeit.Eingabe do
  @moduledoc """
  #1247 (Z2/Z4): was der Zeit-Jack zu lesen bekommt.

  **Der Mitschnitt einer Sitzung, die Anker der ganzen Kampagne.** Das ist
  die Aufteilung, die die Sache verlangt: Eingeordnet wird eine Sitzung —
  alles andere wäre bei jeder Aufnahme ein Lauf über die gesamte Kampagne —,
  aber die Linie ist kampagnenweit, und ein Anker aus Sitzung 1 muss beim
  Einordnen von Sitzung 4 sichtbar sein. Sonst könnte Jack einen Widerspruch
  zu einer früheren Festlegung gar nicht sehen.

  **Fakten gibt es hier nicht** (Maintainer, 19.09.2026). Der Gedächtnis-Lauf
  las sie bis dahin, um den Ablauf zu verstehen; sie sind aber eine andere
  Schicht mit anderer Körnung, kommen aus allen Sitzungen und stehen nicht in
  Gesprächsreihenfolge. Alle drei Läufe lesen jetzt die Äußerungen — dieselbe
  Adresse, dieselbe Ordnung, dieselbe Sitzung.

  **Die menschlich gesetzten Anker reisen mit** (`Worker.Repo.Zeit.anker/1`
  liest sie aus `SessionInGameAnchorSet` und den eigenen Rows). Jack sieht
  sie, kann sie aber nicht überschreiben — das entscheidet
  `Worker.Jack.Zeit.Setzen`, nicht dieses Modul.
  """

  alias Worker.Jack.Zeit.Mitschnitt

  @doc """
  Die Eingabe für die Läufe einer Sitzung, oder `{:error, grund}`.

  `{:error, :keine_glaettung}`, wenn die Sitzung keine gespeicherte Glättung
  hat: Ohne sie gäbe es keine Blocknummern, und Jacks Zeigefinger zeigte ins
  Leere. Das ist ein lauter Fehler und kein leerer Lauf — dieselbe Regel wie
  bei `Worker.Jack.Pipeline.gespeicherter_kontext/1`.
  """
  @spec aus_repo(String.t()) :: {:ok, map()} | {:error, term()}
  def aus_repo(session_id) when is_binary(session_id) do
    with {:ok, session} <- session(session_id),
         {:ok, campaign} <- kampagne(session.campaign_id),
         {:ok, mitschnitt} <- mitschnitt(session, campaign) do
      {:ok,
       %{
         session_id: session.id,
         campaign_id: campaign.id,
         kampagne: Map.get(campaign, :name) || campaign.id,
         mitschnitt: mitschnitt,
         anker: Worker.Repo.Zeit.anker(campaign.id),
         # **Die bestehende Kette der KAMPAGNE, nicht der Sitzung** (#1247,
         # 25.09.2026). Maintainer: „die kette ist ja persistent — jeder
         # weitere lauf soll diese kette ergänzen."
         #
         # Ohne das begann jeder Lauf leer, und weil der Speicher gegen den
         # Bestand vergleicht, bekam alles Bestehende beim ersten
         # Werkzeugaufruf einen Grabstein: Ein Regenerate löschte die Kette
         # der Sitzung, statt sie zu ergänzen. Und über Sitzungsgrenzen war
         # gar keine Ordnung möglich — der Lauf sah die Glieder der anderen
         # Sitzungen nicht und konnte nicht sagen, wo seine liegt.
         #
         # Kampagnenweit, weil Geschehen an der Sitzungsgrenze nicht aufhört
         # (dieselbe Begründung, aus der die Chronik als einziger Jack die
         # ganze Kampagne sieht).
         kette: Worker.Repo.Zeit.kette(campaign.id),
         kalender: Worker.Repo.get_campaign_calendar(campaign.id)
       }
       |> Map.merge(ueber_sitzungen(session, campaign))}
    end
  end

  # #1247: was der Lauf über die anderen Sitzungen wissen kann
  # (`Worker.Jack.Zeit.Frueher`). Maintainer, 25.09.2026: „er muss die Sachen,
  # die vor vorherigen Sessions erarbeitet wurden, lesen/bearbeiten können."
  #
  # Die Übersicht wird **vorgeladen** (vier Zahlen je Sitzung), die Mitschnitte
  # **nicht** — dafür gibt es den Lader. Bei seattleV5 wären das rund 12.000
  # Zeilen im Stand, die ein Lauf meist nie ansieht.
  defp ueber_sitzungen(session, campaign) do
    alle = campaign.id |> Worker.Repo.list_sessions() |> List.wrap()
    staende = notizen_je_sitzung(alle)

    uebersicht =
      alle
      |> Enum.map(fn s ->
        %{
          nummer: nummer(s),
          zeilen: s.id |> Worker.Repo.list_utterances(limit: :all) |> List.wrap() |> length(),
          glieder: Worker.Timeline.Kette.anzahl(Worker.Repo.Zeit.kette(campaign.id, s.id)),
          notizen?: Map.has_key?(staende, nummer(s)),
          eigene?: s.id == session.id
        }
      end)
      |> Enum.sort_by(& &1.nummer)

    %{
      sitzung_nr: nummer(session),
      sitzungen: uebersicht,
      lader: lader(campaign.id, Enum.reject(alle, &(&1.id == session.id))),
      vorige_notizen: Map.delete(staende, nummer(session))
    }
  end

  # Die Notizen früherer Zeit-Läufe, aus `JackZeitStandAbgelegt`. Ein Stand
  # ohne Notizen zählt nicht als vorhanden — sonst verspräche `sitzungen()`
  # etwas, das `vorige_gedanken()` nicht liefert.
  defp notizen_je_sitzung(alle) do
    for s <- alle,
        stand = Worker.Repo.Zeit.jack_stand(s.id),
        is_map(stand),
        notizen = Map.get(stand, "notizen") || Map.get(stand, :notizen),
        is_map(notizen) and map_size(notizen) > 0,
        into: %{},
        do: {nummer(s), notizen}
  end

  # Der Lader baut die Kontextliste einer fremden Sitzung — dieselbe Form wie
  # der eigene Mitschnitt, damit `Frueher` sie ohne Sonderfall anzeigen kann.
  defp lader(cid, andere) do
    ids = Map.new(andere, &{nummer(&1), &1.id})

    fn nr ->
      case Map.fetch(ids, nr) do
        :error ->
          {:error, :keine_sitzung}

        {:ok, sid} ->
          case Worker.Repo.get_session(sid) do
            nil -> {:error, :keine_sitzung}
            s -> mitschnitt_oder_fehler(s, cid)
          end
      end
    end
  end

  defp mitschnitt_oder_fehler(session, cid) do
    case mitschnitt(session, %{id: cid}) do
      {:ok, zeilen} -> {:ok, zeilen}
      {:error, grund} -> {:error, grund}
    end
  end

  defp nummer(s), do: Map.get(s, :number) || Map.get(s, :session_number)

  defp session(session_id) do
    case Worker.Repo.get_session(session_id) do
      nil -> {:error, {:session_fehlt, session_id}}
      s -> {:ok, s}
    end
  end

  defp kampagne(campaign_id) do
    case Worker.Repo.get_campaign(campaign_id) do
      nil -> {:error, {:kampagne_fehlt, campaign_id}}
      c -> {:ok, c}
    end
  end

  defp mitschnitt(session, campaign) do
    case Worker.Repo.get_smoothed_blocks(session.id) do
      # **Atom-Schlüssel, nicht String.** `get_smoothed_blocks/1` dekodiert
      # das JSON und baut eine Map mit Atom-Schlüsseln; der erste Wurf matchte
      # auf `"blocks"` und traf damit NIE — der Zeit-Jack hätte in jedem Lauf
      # `:keine_glaettung` gemeldet, und weil er best-effort ist, wäre das
      # niemandem aufgefallen. Gefunden vom Dialyzer, nicht von einem Test.
      %{blocks: [_ | _] = blocks} ->
        utterances = Worker.Repo.list_utterances(session.id, limit: :all)

        # **Die Kontextliste wird EINMAL gebaut** und trägt beides: den
        # wirksamen Text je Block und die Sprecher. Zweimal zu bauen hiesse,
        # zwei Wege zu haben, auf denen ein Gap-Fill-Vorschlag ankommt oder
        # eben nicht.
        kontext = kontext(session.id, blocks)
        namen = Worker.Jack.Pipeline.sprecher(campaign.id, kontext)

        {:ok, Mitschnitt.bauen(utterances, blocks, wirksam(kontext), namen)}

      _ ->
        {:error, :keine_glaettung}
    end
  end

  # Derselbe wirksame Text, den die Extraktion sieht: Gap-Fill-Vorschlag oder
  # Kuration, wo sie vom Blocktext abweichen. Zwei verschiedene Texte für
  # dieselbe Stelle wären zwei Wahrheiten.
  defp kontext(session_id, blocks) do
    vorschlaege = Worker.Repo.luecken_vorschlaege_for_session(session_id)
    %{attached: overrides} = Worker.Repo.luecken_overrides_effective(session_id, blocks)

    Worker.Recording.Pipeline.Smoothing.to_context(blocks, vorschlaege, overrides)
  end

  defp wirksam(kontext) do
    kontext
    |> Map.new(fn b -> {Map.get(b, :id), Map.get(b, :text)} end)
    |> Map.reject(fn {id, text} -> is_nil(id) or is_nil(text) end)
  end
end
