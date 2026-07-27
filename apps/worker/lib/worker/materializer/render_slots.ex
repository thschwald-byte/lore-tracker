defmodule Worker.Materializer.RenderSlots do
  @moduledoc """
  Issue #914 (Cut 0): die Fold-Schicht der kuratiert/generiert-Slots für die
  Prosa-Artefakte. Ersetzt das reine ts-LWW (`lww_accept_summary?`/
  `upsert_current?`), das manuelle Edits vom nächsten Regenerate überschrieb.

  **Alle Folds ordnen über event_id-LWW** (fold_meta-Sidecar, #766/#781) —
  KEIN `updated_at`. Drei Folds pro Artefakt, jeder mit eigenem Fold-Namen:
  `:summary_generated` (Regenerate → generiert-Slot), `:summary_curated`
  (Edit → kuratiert-Slot), `:summary_release` (`RenderReleaseSet` → Freigabe).
  Nach jedem Slot-Write wird `content_md` = `Repo.Render.displayed/1` neu
  materialisiert — Bestands-Reader lesen weiter `content_md` und bekommen
  automatisch die abgeleitete Anzeige-Fassung.

  Positions-sicher über Row↔Map (die Feldreihenfolge `@summary_fields` MUSS
  der Migration `migrate_session_summaries_add_render_slots!` entsprechen).
  """
  require Logger

  alias Worker.Materializer
  alias Worker.Repo.Render
  alias Worker.Schema.Mnesia, as: S

  @summary_fields ~w(session_id campaign_id content_md generated_at source
    source_refs flagged_claims render_backend render_model
    generated_md generated_version_id generated_source curated_md curated_event_id
    released_version_id release_event_id)a

  @doc "Fold-Namen der Summary-Slots (für die Cascade-Aufräumung)."
  def summary_folds, do: [:summary_generated, :summary_curated, :summary_release]

  # ─── Summary: Generated (Regenerate → generiert-Slot) ────────────────
  def summary_generated(payload, ts, meta) do
    sid = payload["session_id"]
    eid = Map.get(meta, :event_id)

    if is_binary(sid) and
         Materializer.fold_supersedes?(S.session_summaries(), sid, :summary_generated, eid) do
      row =
        read_summary(sid)
        |> ensure_summary(sid, payload["campaign_id"])
        |> Map.merge(%{
          campaign_id: payload["campaign_id"] || read_cid(sid),
          generated_md: payload["content_md"] || "",
          generated_version_id: eid,
          generated_source: Materializer.parse_summary_source(payload["source"]),
          generated_at: ts,
          source_refs: payload["source_refs"] || [],
          flagged_claims: payload["flagged_claims"] || [],
          render_backend: payload["render_backend"],
          render_model: payload["render_model"]
        })

      write_summary(recompute(row))
      Materializer.record_fold_winner!(S.session_summaries(), sid, :summary_generated, eid)
    end

    :ok
  end

  # ─── Summary: Edited (manueller Edit → kuratiert-Slot) ───────────────
  def summary_edited(payload, ts, meta) do
    sid = payload["session_id"]
    eid = Map.get(meta, :event_id)

    cond do
      is_nil(read_summary(sid)) ->
        Logger.warning("SessionSummaryEdited for unknown session=#{sid}")
        :ok

      not Materializer.fold_supersedes?(S.session_summaries(), sid, :summary_curated, eid) ->
        :ok

      true ->
        row =
          read_summary(sid)
          |> Map.merge(%{curated_md: payload["new_md"] || "", curated_event_id: eid})
          # #715: die Flags des generierten Gates zeigen nach dem Edit ins Leere.
          |> Map.put(:flagged_claims, [])
          |> Map.put(:generated_at, ts)

        write_summary(recompute(row))
        Materializer.record_fold_winner!(S.session_summaries(), sid, :summary_curated, eid)
    end
  end

  # ─── RenderReleaseSet (Freigabe einer generierten version_id) ────────
  def render_release(payload, _ts, meta) do
    case payload["artifact_type"] do
      "summary" -> summary_release(payload, meta)
      # epos/chronik-Routing folgt in den nächsten Cut-0-Commits.
      _ -> :ok
    end
  end

  defp summary_release(payload, meta) do
    sid = payload["artifact_key"]
    eid = Map.get(meta, :event_id)

    cond do
      is_nil(read_summary(sid)) ->
        :ok

      not Materializer.fold_supersedes?(S.session_summaries(), sid, :summary_release, eid) ->
        :ok

      true ->
        row =
          read_summary(sid)
          |> Map.merge(%{released_version_id: payload["version_id"], release_event_id: eid})

        write_summary(recompute(row))
        Materializer.record_fold_winner!(S.session_summaries(), sid, :summary_release, eid)
    end
  end

  # ─── row ↔ map (positions-sicher) ────────────────────────────────────
  defp read_summary(sid) when is_binary(sid) do
    case :mnesia.read(S.session_summaries(), sid) do
      [row] -> row |> Tuple.to_list() |> tl() |> then(&Map.new(Enum.zip(@summary_fields, &1)))
      [] -> nil
    end
  end

  defp read_summary(_), do: nil

  defp read_cid(sid) do
    case read_summary(sid) do
      %{campaign_id: cid} -> cid
      _ -> nil
    end
  end

  defp ensure_summary(nil, sid, cid) do
    base = Map.new(@summary_fields, fn f -> {f, nil} end)
    %{base | session_id: sid, campaign_id: cid, source_refs: [], flagged_claims: []}
  end

  defp ensure_summary(row, _sid, _cid), do: row

  defp write_summary(map) do
    vals = Enum.map(@summary_fields, &Map.get(map, &1))
    :ok = :mnesia.write(List.to_tuple([S.session_summaries() | vals]))
  end

  # content_md UND source = die materialisierte Anzeige-Ableitung (Bestands-
  # Reader lesen beides unverändert weiter): kuratiert → :manual, sonst die
  # echte Generat-Herkunft (generated_source).
  defp recompute(map) do
    d = Render.displayed(map)
    src = if d.source == :kuratiert, do: :manual, else: map[:generated_source] || :llm
    %{map | content_md: d.content_md, source: src}
  end
end
