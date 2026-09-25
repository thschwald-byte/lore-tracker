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
  alias Worker.Timeline.{Ausdruck, Kette, Linie}

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
  #
  # **Die Liste steht als ATOME da, und die Übersetzung geht über eine Map.**
  # Der erste Wurf schrieb sie als Strings und rief `String.to_existing_atom/1`
  # — eine Absicherung, die sich selbst nicht trägt: Eine String-Whitelist
  # erzeugt die Atome nicht, sie entstehen nur, wenn irgendein geladenes Modul
  # sie literal nennt. Am 25.09.2026 an einem frisch gestarteten Worker
  # aufgeschlagen: `:beleg` existierte noch nicht, `anker/1` warf `:badarg`,
  # und damit fiel der EINZIGE Leser der Anker aus — für den Zeit-Jack und für
  # die Zeitlinie der Chronik (Z3). Dieselbe Klasse wie #646 (Materializer)
  # und #611 (Hub-Icons), beide dort schon mit Begründung notiert. `~w(…)a`
  # legt die Atome zur Compile-Zeit an; danach ist „existiert" keine Frage
  # mehr, und die Map kennt nur diese.
  @bekannt ~w(utterance_ids art wert welt zweifel beleg quelle abgesegnet_von
              abgesegnet_am ziel richtung halbtag)a
  @bekannt_map Map.new(@bekannt, &{Atom.to_string(&1), &1})

  defp schluessel(k), do: Map.get(@bekannt_map, k, k)

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

  # ─── Die Kette ──────────────────────────────────────────────────────

  @doc """
  Die **Kette** einer Sitzung aus `worker_zeit_kette` — eine Row je Glied,
  zurückgebaut zum Zeitstrahl samt seinen Bäumen.

  Ohne `session_id` die Kette der ganzen Kampagne. Das ist kein Spezialfall,
  sondern der Normalfall für die Chronik: Geschehen hört nicht an der
  Sitzungsgrenze auf, und ein Rückblick in Sitzung 5 gehört vor Sitzung 1.
  Die Sitzungsform ist für den Lauf selbst da, der auf seinem eigenen Stand
  aufsetzt.

  **Befunde werden geloggt, nicht verschluckt** (`Kette.aus_zeilen/1`): ein
  gerissener `vorher`-Bezug ist der Preis der Kennung als Platzangabe
  (Maintainer-Entscheidung, 20.09.2026), und wer ihn nicht sieht, sucht den
  Fehler später in der Zeitrechnung.
  """
  @spec kette(String.t(), String.t() | nil) :: map()
  def kette(campaign_id, session_id \\ nil) when is_binary(campaign_id) do
    {k, befunde} = campaign_id |> ketten_zeilen(session_id) |> Kette.aus_zeilen()

    for b <- befunde do
      Logger.warning("Zeit-Kette #{campaign_id}/#{session_id || "alle"}: #{b}")
    end

    k
  end

  @doc """
  Der abgelegte Stand eines Zeit-Laufs (`worker_jack_zeit_staende`), oder `nil`.

  **Bis #1247 hatte diese Tabelle keinen Leser** — sie wurde nach jedem
  Werkzeugaufruf geschrieben und nie gelesen, ein Apparat ohne Leser (dieselbe
  Klasse wie `loesche_kettenplatz/2` im selben Ticket). Gebraucht wird er, seit
  der Zeit-Jack die Gedanken seiner früheren Läufe sehen soll: „er muss die
  Sachen, die vor vorherigen Sessions erarbeitet wurden, lesen können"
  (Maintainer, 25.09.2026).

  Liefert die Map, wie sie publiziert wurde (String-Schlüssel).
  """
  @spec jack_stand(String.t()) :: map() | nil
  def jack_stand(session_id) when is_binary(session_id) do
    transaction(fn -> :mnesia.read(S.jack_zeit_staende(), session_id) end)
    |> List.wrap()
    |> Enum.find_value(fn row ->
      with true <- tuple_size(row) >= 4,
           json when is_binary(json) <- elem(row, 3),
           {:ok, %{} = stand} <- Jason.decode(json) do
        stand
      else
        _ ->
          Logger.warning("Zeit: Jack-Stand von #{session_id} nicht lesbar — übersprungen")
          nil
      end
    end)
  end

  @doc """
  Die gespeicherten Zeilen der Kette, ohne sie zusammenzubauen — **Grabsteine
  schon entfernt**.

  Der Publizierer braucht sie, um zu sehen, was sich geändert hat: Ein
  Ereignis je Lauf und Glied, auch wo nichts anders ist, schöbe bei jedem
  Lauf die `event_id` vor, und der LWW-Vergleich im Fold verlöre seine
  Aussage (dieselbe Regel wie bei den Ankern).
  """
  @spec ketten_zeilen(String.t(), String.t() | nil) :: [map()]
  def ketten_zeilen(campaign_id, session_id \\ nil) when is_binary(campaign_id) do
    rows =
      if is_binary(session_id) do
        transaction(fn -> :mnesia.index_read(S.zeit_kette(), session_id, :session_id) end)
      else
        transaction(fn -> :mnesia.index_read(S.zeit_kette(), campaign_id, :campaign_id) end)
      end

    rows
    |> List.wrap()
    |> Enum.flat_map(&ketten_zeile/1)
    |> Enum.reject(&(&1["entfernt"] == true))
  end

  defp ketten_zeile(row) when tuple_size(row) >= 5 do
    with json when is_binary(json) <- elem(row, 4),
         {:ok, %{} = daten} <- Jason.decode(json) do
      # **Die Sitzung reist mit** (#1247, 25.09.2026). Ein Glied entsteht in
      # EINEM Lauf, aber ein späterer Lauf einer ANDEREN Sitzung liest die
      # Kette mit und schreibt geänderte Zeilen zurück. Ohne diese Spalte
      # setzte er dabei seine eigene `session_id` ein, und das Glied wanderte
      # in die falsche Sitzung — sichtbar erst daran, dass
      # `ketten_zeilen(cid, sid)` es plötzlich mitzählt.
      [daten |> Map.put("glied_id", elem(row, 1)) |> Map.put("session_id", elem(row, 3))]
    else
      _ ->
        Logger.warning("Zeit: Kettenglied #{inspect(elem(row, 1))} nicht lesbar — übersprungen")
        []
    end
  end

  defp ketten_zeile(_), do: []
end
