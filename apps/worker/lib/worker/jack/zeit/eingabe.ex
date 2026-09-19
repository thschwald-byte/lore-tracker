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
         kalender: Worker.Repo.get_campaign_calendar(campaign.id)
       }}
    end
  end

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
