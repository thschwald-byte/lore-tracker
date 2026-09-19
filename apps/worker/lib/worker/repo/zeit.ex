defmodule Worker.Repo.Zeit do
  @moduledoc """
  #1247 (Z1): holt zusammen, woraus `Worker.Timeline.Linie` rechnet — die
  Grundordnung der Äußerungen und die Anker. Die Linie selbst bleibt pur;
  hier liegt alles, was Mnesia, Kalender und Parser braucht.

  ## Drei Quellen für Anker, und zwei davon gab es schon

    * **`worker_zeit_anker`** — was der Zeit-Jack (Z2) oder ein Kurations-Lauf
      gesetzt hat.
    * **`SessionInGameAnchorSet`** — das 📅-Datumsfeld je Sitzung. Von Hand
      gesetzt, also **kuratiert**: `quelle: "mensch"`, `abgesegnet_am` gesetzt.
    * **`SessionFactDateSet`** — das von Hand gesetzte Datum an einem Fakt;
      die Doku führt es seit dem Abbau der Review-Liste ausdrücklich als
      „harte Anker für Jack" weiter. Ebenfalls kuratiert. **Noch nicht
      gelesen** (s.u.).

  Der Session-Anker ist der Grund, warum die harte Regel („eine abgesegnete
  Stelle überschreibt niemand") von Anfang an erreichbar ist und nicht erst,
  wenn es einen Kurations-Jack gibt. Ohne ihn wäre sie gebauter, nie
  erreichter Code — die Klasse „Apparat ohne Producer", die dieses Repo mit
  #724 und #1109 zweimal erzeugt hat.

  **Offen: `SessionFactDateSet`.** Ein Fakt-Datum hängt nicht an einer
  Äußerung, sondern an einem Fakt; der Weg dorthin geht über `source_refs` →
  Blöcke → `quell_utterance_ids`. Diese Auflösung baut Z2 ohnehin (Jack
  adressiert über Blocknummern), und sie hier ein zweites Mal zu schreiben
  hiesse, zwei Wege zu derselben Menge zu haben. Bis dahin fehlen diese Anker
  — sie sind selten (an Free Seattle 7 von 225 Fakten) und ihr Fehlen ist
  sichtbar, nicht still: ein Fakt ohne erreichbaren Anker bekommt keine Zeit.

  ## Wo der Ausdruck zur Minute wird

  Ein Anker speichert den **Ausdruck**, wie er gesprochen wurde („am 15.
  November", „zwei Stunden"). Die Minute daraus rechnet `Worker.Timeline.Ausdruck`
  über `Worker.Timeline.Parser` und den Kampagnen-Kalender — nicht die Linie,
  und nicht das Modell; dieses Modul reicht nur den Kalender der Kampagne
  hinein. Die Rechnung liegt dort und nicht hier, weil der Zeit-Jack sie
  **während** seines Laufs braucht: seine `linie()` zeigte sonst eine Reihe
  ohne eine einzige belegte Zeit. Der Parser hat seit #1213 keinen Leser mehr und bekommt
  hier wieder einen; er typisiert den Ausdruck (`:date` gegen `:duration`),
  und genau diese Unterscheidung verhindert, dass aus „Trolle werden 50 Jahre
  alt" das Jahr 50 auf dem Zeitstrahl wird.

  Ein Ausdruck, den der Parser nicht auflöst, ergibt **keine** Minute. Der
  Anker bleibt trotzdem stehen: seine Ordnung gilt weiter, nur sein Datum
  fehlt. Lieber keine Angabe als eine erfundene.
  """

  require Logger

  alias Worker.Repo.Artifacts
  alias Worker.Schema.Mnesia, as: S
  alias Worker.Timeline.{Ausdruck, Linie}

  import Worker.Repo, only: [transaction: 1]

  @doc """
  Die fertige Linie einer Kampagne. Einmal bauen, dann mehrfach fragen
  (Muster `Worker.Repo.GlattQuellen.block_index/1`) — nicht je Fakt neu.
  """
  @spec linie(String.t()) :: map()
  def linie(campaign_id) when is_binary(campaign_id) do
    Linie.bauen(stellen(campaign_id), anker(campaign_id))
  end

  @doc """
  Die Grundordnung: jede Äußerung der Kampagne mit Sitzungsnummer und
  Position. Das ist die Reihenfolge, in der gesprochen wurde — wer sie nicht
  anfasst, steht schon richtig.
  """
  @spec stellen(String.t()) :: [Linie.stelle()]
  def stellen(campaign_id) when is_binary(campaign_id) do
    campaign_id
    |> Worker.Repo.list_sessions()
    |> Enum.flat_map(fn s ->
      s.id
      |> Worker.Repo.list_utterances(limit: :all)
      |> Enum.with_index()
      |> Enum.map(fn {u, i} ->
        %{utterance_id: u.id, session_nr: s.number, pos: i}
      end)
    end)
  end

  @doc """
  Alle Anker einer Kampagne, mit aufgelösten Minuten — die eigenen und die
  beiden menschlich gesetzten Quellen.
  """
  @spec anker(String.t()) :: [map()]
  def anker(campaign_id) when is_binary(campaign_id) do
    cal = Artifacts.get_campaign_calendar(campaign_id)

    eigene(campaign_id, cal) ++ aus_session_ankern(campaign_id, cal)
  end

  # ─── Die eigenen Anker ──────────────────────────────────────────────

  defp eigene(campaign_id, cal) do
    transaction(fn -> :mnesia.index_read(S.zeit_anker(), campaign_id, :campaign_id) end)
    |> List.wrap()
    |> Enum.flat_map(&zeile_zu_anker(&1, cal))
  end

  defp zeile_zu_anker(row, cal) when tuple_size(row) >= 5 do
    with json when is_binary(json) <- elem(row, 4),
         {:ok, %{} = daten} <- Jason.decode(json) do
      [
        daten
        |> Map.new(fn {k, v} -> {schluessel(k), v} end)
        |> Map.put(:anker_id, elem(row, 1))
        |> Ausdruck.aufloesen(cal)
      ]
    else
      _ ->
        Logger.warning("Zeit: Anker #{inspect(elem(row, 1))} nicht lesbar — übersprungen")
        []
    end
  end

  defp zeile_zu_anker(_, _), do: []

  # Nur bekannte Schlüssel werden zu Atomen — die Atom-Tabelle ist endlich und
  # wird nie aufgeräumt, und die Daten kommen aus einem Ereignis.
  @bekannt ~w(utterance_ids art wert welt zweifel beleg quelle abgesegnet_von
              abgesegnet_am ziel richtung)
  defp schluessel(k) when k in @bekannt, do: String.to_existing_atom(k)
  defp schluessel(k), do: k

  # ─── Die menschlich gesetzten Anker ─────────────────────────────────

  # Das 📅-Datum einer Sitzung. Es hängt an der ERSTEN Äußerung der Sitzung —
  # das ist die Stelle, an der es ohne weitere Information gilt. Anders als
  # bisher ist das aber kein Raten mehr, sondern eine kuratierte Angabe: der
  # Zeit-Jack darf sie nicht überschreiben, und wenn er sie woanders verortet
  # sehen will, ist das ein Konflikt für die Kuration.
  defp aus_session_ankern(campaign_id, _cal) do
    campaign_id
    |> Worker.Repo.list_sessions()
    |> Enum.flat_map(fn s ->
      with %{in_game_day: tag} when is_integer(tag) <- Artifacts.get_session_anchor(s.id),
           [%{id: erste} | _] <- Worker.Repo.list_utterances(s.id, limit: 1) do
        [
          %{
            anker_id: "z_session_#{s.id}",
            art: :zeitpunkt,
            utterance_ids: [erste],
            minute: tag * Linie.minuten_pro_tag(),
            wert: "",
            quelle: "mensch",
            abgesegnet_am: gesetzt_am(s),
            abgesegnet_von: "gm"
          }
        ]
      else
        _ -> []
      end
    end)
  end

  # Der Zeitpunkt der Absegnung ist für die Linie nur ein „ja, ein Mensch war
  # das". Das Datum der Sitzung ist die beste Näherung, die ohne eine weitere
  # Spalte zu haben ist; genauer wird es, sobald die Kuration (#1243) eigene
  # Zeitstempel schreibt.
  defp gesetzt_am(%{date: d}) when is_binary(d) and d != "", do: d
  defp gesetzt_am(_), do: "gesetzt"
end
