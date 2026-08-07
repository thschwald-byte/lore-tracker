defmodule Worker.Repo.ArcProgressions do
  @moduledoc """
  Issue #838: der Lese-Pfad für die Prosa-Progressionen — EIN Eintrag pro
  (Bogen × Session) in `worker_arc_progressions`, NIE nachträglich
  überschrieben (Materializer-Fold: `Worker.Materializer.ArcFolds.arc_progression_generated/3`).

  Zwei Zugriffe:

    * `get_prior_arc_entry/3` — der "vorherige Eintrag" für den Fortsetzungs-
      Prompt (Pipeline), zur LESEZEIT über die höchste `session_number`
      kleiner als die aktuelle bestimmt (NICHT über einen gespeicherten
      Zeiger) — von Natur aus reihenfolge-unabhängig, das ist die
      strukturelle Replay-Sicherheit dieses Features (siehe #838-Plan
      Design E).
    * `list_arc_progression_entries/2` — die volle Chronik eines Bogens,
      chronologisch sortiert, für die Nachlese-Anzeige.
  """

  alias Worker.Schema.Mnesia, as: S

  import Worker.Repo, only: [transaction: 1]

  @doc """
  Der Eintrag mit der größten `session_number < before_session_number` für
  diesen Bogen, oder `nil` wenn keiner existiert (Bogen komplett neu ODER
  Backfill-Fall — die Pipeline unterscheidet das über `arc.opened_in_session`,
  s. `Prompts.build_arc_progression_prompt/4`).
  """
  @spec get_prior_arc_entry(String.t(), String.t(), pos_integer()) :: map() | nil
  def get_prior_arc_entry(campaign_id, arc_id, before_session_number)
      when is_binary(campaign_id) and is_binary(arc_id) and is_integer(before_session_number) do
    campaign_id
    |> entries_for_arc(arc_id)
    |> Enum.filter(&(&1.session_number < before_session_number))
    |> Enum.max_by(& &1.session_number, fn -> nil end)
  end

  @doc "Alle Einträge eines Bogens, chronologisch nach `session_number` sortiert."
  @spec list_arc_progression_entries(String.t(), String.t()) :: [map()]
  def list_arc_progression_entries(campaign_id, arc_id)
      when is_binary(campaign_id) and is_binary(arc_id) do
    campaign_id
    |> entries_for_arc(arc_id)
    |> Enum.sort_by(& &1.session_number)
  end

  defp entries_for_arc(campaign_id, arc_id) do
    transaction(fn -> :mnesia.index_read(S.arc_progressions(), campaign_id, :campaign_id) end)
    |> Enum.filter(fn {_t, _key, aid, _cid, _sid, _sn, _md, _fc, _rb, _rm, _gen} ->
      aid == arc_id
    end)
    |> Enum.map(fn {_t, _key, _aid, _cid, session_id, session_number, content_md,
                     flagged_claims_json, render_backend, render_model, generated_at} ->
      %{
        session_id: session_id,
        session_number: session_number,
        content_md: content_md,
        flagged_claims: decode_flagged(flagged_claims_json),
        render_backend: render_backend,
        render_model: render_model,
        generated_at: generated_at
      }
    end)
  end

  defp decode_flagged(json) do
    case Jason.decode(json || "[]") do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end
end
