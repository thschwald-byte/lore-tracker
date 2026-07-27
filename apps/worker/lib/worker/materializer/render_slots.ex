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

  @epos_fields ~w(id campaign_id parent_id content_md updated_at source_refs
    epos_backend epos_model
    generated_md generated_version_id curated_md curated_event_id
    released_version_id release_event_id)a

  @doc "Fold-Namen der Summary-Slots (für die Cascade-Aufräumung)."
  def summary_folds, do: [:summary_generated, :summary_curated, :summary_release]

  @doc "Fold-Namen der Epos-Slots (für die Cascade-Aufräumung)."
  def epos_folds, do: [:epos_generated, :epos_curated, :epos_release]

  @doc "Fold-Namen der Chronik-Overlay-Slots (für die Cascade-Aufräumung)."
  def chronik_folds, do: [:chronik_curated, :chronik_release]

  # ─── Chronik: kuratiert-Overlay (separates Table, id-geschlüsselt) ────
  # Der manuelle Chronik-Edit (ChronikEntryChanged mit source="manual") schreibt
  # NICHT in die generation-geleerte chronik_entries-Row, sondern in dieses
  # Overlay. Der Read-Merge (`Repo.Artifacts.list_chronik_entries`) wendet
  # `Render.displayed/1` an: generated_md = entry.summary, generated_version_id
  # = entry.generation → ein Regenerate (neue generation) macht eine Freigabe
  # stale und lässt die kuratierte Fassung wieder erscheinen.
  def chronik_curated(payload, meta) do
    entry_id = payload["id"]
    eid = Map.get(meta, :event_id)

    if is_binary(entry_id) and
         Materializer.fold_supersedes?(S.chronik_overrides(), entry_id, :chronik_curated, eid) do
      row =
        read_chronik_ov(entry_id)
        |> ensure_chronik_ov(entry_id, payload["campaign_id"])
        |> Map.merge(%{
          campaign_id: payload["campaign_id"] || read_chronik_cid(entry_id),
          curated_md: payload["markdown_body"] || "",
          curated_event_id: eid
        })

      write_chronik_ov(row)
      Materializer.record_fold_winner!(S.chronik_overrides(), entry_id, :chronik_curated, eid)
    end

    :ok
  end

  defp chronik_release(payload, meta) do
    entry_id = payload["artifact_key"]
    eid = Map.get(meta, :event_id)

    cond do
      is_nil(read_chronik_ov(entry_id)) ->
        :ok

      not Materializer.fold_supersedes?(S.chronik_overrides(), entry_id, :chronik_release, eid) ->
        :ok

      true ->
        row =
          read_chronik_ov(entry_id)
          |> Map.merge(%{released_version_id: payload["version_id"], release_event_id: eid})

        write_chronik_ov(row)
        Materializer.record_fold_winner!(S.chronik_overrides(), entry_id, :chronik_release, eid)
    end
  end

  @chronik_ov_fields ~w(entry_id campaign_id curated_md curated_event_id
    released_version_id release_event_id)a

  defp read_chronik_ov(entry_id) when is_binary(entry_id) do
    case :mnesia.read(S.chronik_overrides(), entry_id) do
      [row] -> row |> Tuple.to_list() |> tl() |> then(&Map.new(Enum.zip(@chronik_ov_fields, &1)))
      [] -> nil
    end
  end

  defp read_chronik_ov(_), do: nil

  defp read_chronik_cid(entry_id) do
    case read_chronik_ov(entry_id) do
      %{campaign_id: cid} -> cid
      _ -> nil
    end
  end

  defp ensure_chronik_ov(nil, entry_id, cid),
    do: %{Map.new(@chronik_ov_fields, &{&1, nil}) | entry_id: entry_id, campaign_id: cid}

  defp ensure_chronik_ov(row, _entry_id, _cid), do: row

  defp write_chronik_ov(map) do
    vals = Enum.map(@chronik_ov_fields, &Map.get(map, &1))
    :ok = :mnesia.write(List.to_tuple([S.chronik_overrides() | vals]))
  end

  # ─── Epos: Content-Write (source-geroutet) ───────────────────────────
  # Aufgerufen aus dem EposEntryEdited-Fold NACH source_refs/Provenance-
  # Berechnung; der History-Append bleibt im apply2-Fold. `attrs` trägt
  # entry_id/campaign_id/parent_id/new_md/source/source_refs/epos_backend/
  # epos_model/ts.
  def epos_content(attrs, meta) do
    entry_id = attrs.entry_id
    eid = Map.get(meta, :event_id)

    {slot_fold, slot_updates} =
      if attrs.source == :manual do
        {:epos_curated, %{curated_md: attrs.new_md, curated_event_id: eid}}
      else
        {:epos_generated, %{generated_md: attrs.new_md, generated_version_id: eid}}
      end

    if Materializer.fold_supersedes?(S.epos_entries(), entry_id, slot_fold, eid) do
      row =
        read_epos(entry_id)
        |> ensure_epos(entry_id, attrs)
        |> Map.merge(%{
          campaign_id: attrs.campaign_id,
          parent_id: attrs.parent_id,
          updated_at: attrs.ts,
          source_refs: attrs.source_refs,
          epos_backend: attrs.epos_backend,
          epos_model: attrs.epos_model
        })
        |> Map.merge(slot_updates)

      write_epos(recompute_content(row))
      Materializer.record_fold_winner!(S.epos_entries(), entry_id, slot_fold, eid)
    end

    :ok
  end

  defp epos_release(payload, meta) do
    entry_id = payload["artifact_key"]
    eid = Map.get(meta, :event_id)

    cond do
      is_nil(read_epos(entry_id)) ->
        :ok

      not Materializer.fold_supersedes?(S.epos_entries(), entry_id, :epos_release, eid) ->
        :ok

      true ->
        row =
          read_epos(entry_id)
          |> Map.merge(%{released_version_id: payload["version_id"], release_event_id: eid})

        write_epos(recompute_content(row))
        Materializer.record_fold_winner!(S.epos_entries(), entry_id, :epos_release, eid)
    end
  end

  defp read_epos(entry_id) when is_binary(entry_id) do
    case :mnesia.read(S.epos_entries(), entry_id) do
      [row] -> row |> Tuple.to_list() |> tl() |> then(&Map.new(Enum.zip(@epos_fields, &1)))
      [] -> nil
    end
  end

  defp read_epos(_), do: nil

  defp ensure_epos(nil, entry_id, attrs) do
    base = Map.new(@epos_fields, fn f -> {f, nil} end)
    %{base | id: entry_id, campaign_id: attrs.campaign_id, source_refs: []}
  end

  defp ensure_epos(row, _entry_id, _attrs), do: row

  defp write_epos(map) do
    vals = Enum.map(@epos_fields, &Map.get(map, &1))
    :ok = :mnesia.write(List.to_tuple([S.epos_entries() | vals]))
  end

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
      "epos" -> epos_release(payload, meta)
      "chronik" -> chronik_release(payload, meta)
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
  # echte Generat-Herkunft (generated_source). Nur Summary hat eine
  # source-Spalte.
  defp recompute(map) do
    d = Render.displayed(map)
    src = if d.source == :kuratiert, do: :manual, else: map[:generated_source] || :llm
    %{map | content_md: d.content_md, source: src}
  end

  # Epos/Chronik: nur content_md materialisieren (keine source-Spalte).
  defp recompute_content(map), do: %{map | content_md: Render.displayed(map).content_md}
end
