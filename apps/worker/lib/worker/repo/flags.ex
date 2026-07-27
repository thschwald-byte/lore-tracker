defmodule Worker.Repo.Flags do
  @moduledoc """
  Issue #915 (Epic #911, Cut 1): Lesepfad der Falsifikations-Flags.

  Der **effektive** Status wird zur LESEZEIT berechnet, nie geschrieben —
  insbesondere das AUTO-RESOLVE für Fakt-Flags: zeigt ein `raised`-Flag auf eine
  fact-content-id, die nicht mehr im aktuellen Fakt-Bestand existiert (der Fakt
  wurde weg-regeneriert), gilt es als `auto_resolved`. Reine Mengen-/Existenz-
  Prüfung über die replizierte Mnesia → multi-worker-deterministisch, kein Write
  (exakt das `luecken`-`verwaist`-Muster). session-/arc-Flags haben KEIN
  Auto-Resolve — sie bleiben bis zum expliziten Schließen (FlagResolved/Dismissed).
  """

  alias Worker.Schema.Mnesia, as: S

  import Worker.Repo, only: [transaction: 1, list_campaign_facts: 1]

  @doc """
  Alle Flags einer Kampagne mit abgeleitetem `"effective_status"`. Die aktuelle
  fact-content-id-Menge UND die abgedeckte Utterance-Menge werden intern aus
  `list_campaign_facts/1` gezogen (die Fakten tragen seit #916 `quell_utterance_ids`).
  """
  @spec flags_effective(String.t()) :: [map()]
  def flags_effective(campaign_id) when is_binary(campaign_id) do
    facts = list_campaign_facts(campaign_id)
    fact_ids = MapSet.new(facts, & &1["id"])
    covered_utts = facts |> Enum.flat_map(&(&1["quell_utterance_ids"] || [])) |> MapSet.new()
    flags_effective(campaign_id, fact_ids, covered_utts)
  end

  @doc """
  Wie `flags_effective/1`, aber mit vorberechneter fact-content-id-`MapSet` +
  abgedeckter Utterance-`MapSet` (spart den Fakt-Reader; Test-Einstieg).

  Auto-Resolve (Read-Zeit, nie geschrieben): ein `raised` **fact**-Flag, dessen
  content-id nicht mehr existiert; ein `raised` **span**-Flag (#916), dessen
  Utterance-Menge KEINE aktuelle Fakt-Utterance mehr berührt (`disjoint?`).
  session/arc-Flags haben kein Auto-Resolve.
  """
  @spec flags_effective(String.t(), MapSet.t(), MapSet.t()) :: [map()]
  def flags_effective(campaign_id, %MapSet{} = current_fact_ids, %MapSet{} = covered_utts)
      when is_binary(campaign_id) do
    transaction(fn -> :mnesia.index_read(S.flags(), campaign_id, :campaign_id) end)
    |> Enum.map(fn {_, key, _cid, tk, tid, rb, note, status, ev} ->
      effective = effective_status(status, tk, tid, current_fact_ids, covered_utts)

      %{
        "flag_key" => key,
        "target_kind" => tk,
        "target_id" => tid,
        "raised_by" => rb,
        "note" => note,
        "status" => status,
        "effective_status" => effective,
        "event_id" => ev
      }
    end)
    |> Enum.sort_by(& &1["event_id"])
  end

  @doc """
  Nur die effektiv OFFENEN Flags (`effective_status == "raised"`) — das, was die
  ⚠-Marker + die Kurator-Queue brauchen. Auto-resolvte/gelöste/verworfene fallen
  raus.
  """
  @spec open_flags(String.t()) :: [map()]
  def open_flags(campaign_id) when is_binary(campaign_id) do
    campaign_id
    |> flags_effective()
    |> Enum.filter(&(&1["effective_status"] == "raised"))
  end

  # Read-Zeit-Auto-Resolve. fact-Flag: content-id weg. span-Flag (#916): die
  # gemeldete Utterance-Menge berührt keine aktuelle Fakt-Utterance mehr
  # (disjoint) → der Span ist nicht mehr repräsentiert. session/arc: nie auto.
  defp effective_status("raised", "fact", tid, fact_ids, _covered) do
    if MapSet.member?(fact_ids, tid), do: "raised", else: "auto_resolved"
  end

  defp effective_status("raised", "span", tid, _fact_ids, covered) do
    span_utts = tid |> String.split(",", trim: true) |> MapSet.new()
    if MapSet.disjoint?(span_utts, covered), do: "auto_resolved", else: "raised"
  end

  defp effective_status(status, _tk, _tid, _fact_ids, _covered), do: status
end
