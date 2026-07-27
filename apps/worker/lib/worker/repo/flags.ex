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
  fact-content-id-Menge wird intern aus `list_campaign_facts/1` gezogen.
  """
  @spec flags_effective(String.t()) :: [map()]
  def flags_effective(campaign_id) when is_binary(campaign_id) do
    fact_ids = campaign_id |> list_campaign_facts() |> MapSet.new(& &1["id"])
    flags_effective(campaign_id, fact_ids)
  end

  @doc """
  Wie `flags_effective/1`, aber mit vorberechneter fact-content-id-`MapSet`
  (spart den Fakt-Reader, wenn der Aufrufer die Menge schon hat; Test-Einstieg).
  """
  @spec flags_effective(String.t(), MapSet.t()) :: [map()]
  def flags_effective(campaign_id, %MapSet{} = current_fact_ids) when is_binary(campaign_id) do
    transaction(fn -> :mnesia.index_read(S.flags(), campaign_id, :campaign_id) end)
    |> Enum.map(fn {_, key, _cid, tk, tid, rb, note, status, ev} ->
      effective =
        if status == "raised" and tk == "fact" and not MapSet.member?(current_fact_ids, tid) do
          "auto_resolved"
        else
          status
        end

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
end
