defmodule Worker.Repo.FaktenFenster do
  @moduledoc """
  Issue #1204: zwei Fakten-Listen, die der Hub bis hierhin vollständig bekam,
  obwohl er sie nicht oder nur zum Teil zeigt. An seattleV4 auf einer Teststage
  mit echtem Browser gemessen (Zahlen in #1204): beim ersten Aufbau im
  Bearbeiten-Modus machten beide zusammen gut die Hälfte dessen aus, was die
  Kampagnenseite rendert.

  1. **Die Review-Liste** (`campaign_review_facts/1`, Fakten ohne
     Zeitstrahl-Datum) reiste im Haupt-Snapshot zu **jedem** Betrachter — an
     seattleV4 567 Einträge, 1,15 MB im LiveView-Heap, auch im Lesen-Modus und
     bei Mitgliedern, denen die Liste nie gezeigt wird. Mit
     `"review_facts" => "anzahl"` im `campaign`-Scope geht nur die Zahl
     (`review_facts_count`); die Liste holt der Hub über
     `campaign_review_facts`, sobald jemand sie aufklappt.
  2. **Die Fakten-Spalte** (`campaign_facts`) bekam alle Fakten aller Sessions
     (an seattleV4 860, 1,64 MB Assigns, ~3 MB HTML). Mit `"fakten_tail" => n`
     liefert der Scope je Session nur ein Fenster — den Tail `n` oder, wo der
     Betrachter geblättert hat, `from`/`count` aus `"fakten_fenster"` — und dazu
     `fakten_fenster` (`%{session_id => %{"total", "from"}}`), damit der Hub
     „ältere/neuere anzeigen" zählen kann. Dasselbe Muster wie die
     Geglättet-Ansicht (#1198): der Worker hält die Liste, der Hub bekommt, was
     er zeigt.

  **Ohne Flag ist jede Antwort byte-identisch** — ein zurückgerollter Hub merkt
  nichts. Ein neuer Hub vor dem Worker-Update bekommt die volle Liste ohne
  `fakten_fenster` und zeigt sie wie bisher.

  **Ehrliche Grenze:** das Fenster gilt je Session, wie bei Protokoll und
  Geglättet — bei 20 Sessions sind es 1.000 Fakten.
  """

  import Worker.Repo, only: [campaign_review_facts: 1, list_campaign_facts_curation: 1]

  # Harte Obergrenze eines Fensters, wie `Components.window_max/0` im Hub und
  # `Worker.Repo.GlattAnsicht`: ein Hub-Fehler, der „alles" verlangt, bekommt
  # trotzdem nur 200.
  @max 200

  @doc """
  Die Review-Liste an die `campaign`-Antwort hängen: als Zahl, wenn der Hub
  danach fragt, sonst wie bisher als Liste. `serialize` ist die Funktion aus
  `Worker.Repo.Snapshots` — sie ist dort privat, und nur so bleibt die Antwort
  ohne Flag byte-identisch.
  """
  @spec review(map(), map(), String.t(), (map() -> map())) :: map()
  def review(antwort, %{"review_facts" => "anzahl"}, id, _serialize),
    do: Map.put(antwort, "review_facts_count", length(campaign_review_facts(id)))

  def review(antwort, _scope, id, serialize),
    do: Map.put(antwort, "review_facts", Enum.map(campaign_review_facts(id), serialize))

  @doc "Antwort des `campaign_facts`-Scopes (Mitgliedschaft prüft der Aufrufer)."
  @spec fakten(String.t(), map()) :: map()
  def fakten(id, %{"fakten_tail" => tail} = scope) when is_integer(tail) do
    wuensche = if is_map(scope["fakten_fenster"]), do: scope["fakten_fenster"], else: %{}

    # `list_campaign_facts_curation/1` sortiert nach Sessionnummer und hält die
    # Fakten einer Session zusammen — `chunk_by` ergibt genau eine Gruppe je
    # Session, in Anzeige-Reihenfolge.
    {facts, fenster} =
      id
      |> list_campaign_facts_curation()
      |> Enum.chunk_by(& &1["session_id"])
      |> Enum.flat_map_reduce(%{}, fn [erster | _] = gruppe, acc ->
        sid = erster["session_id"]
        total = length(gruppe)
        {from, count} = schnitt(Map.get(wuensche, sid), total, tail)
        {Enum.slice(gruppe, from, count), Map.put(acc, sid, %{"total" => total, "from" => from})}
      end)

    %{"facts" => facts, "fakten_fenster" => fenster}
  end

  def fakten(id, _scope), do: %{"facts" => list_campaign_facts_curation(id)}

  @doc """
  Das Fenster einer Session als `{from, count}` (pur). Ein Wunsch
  `%{"from", "count"}` wird auf die Liste und den Deckel geklemmt; alles
  andere (kein Wunsch, falscher Typ) bekommt den Tail, statt zu crashen.
  """
  @spec schnitt(term(), non_neg_integer(), integer()) :: {non_neg_integer(), non_neg_integer()}
  def schnitt(%{"from" => f, "count" => c}, total, _tail) when is_integer(f) and is_integer(c) do
    from = f |> max(0) |> min(total)
    {from, c |> max(0) |> min(@max) |> min(total - from)}
  end

  def schnitt(_wunsch, total, tail) do
    from = max(0, total - (tail |> max(0) |> min(@max)))
    {from, total - from}
  end
end
