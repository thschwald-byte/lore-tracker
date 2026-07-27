defmodule Worker.Schema.Migrations.RenderSlots do
  @moduledoc """
  Issue #914 (Cut 0): die additiven kuratiert/generiert-Slot-Migrationen für
  die Prosa-Artefakte (Resümee/Epos) — ausgelagert aus `Worker.Schema.Migrations`
  (God-Module-Grenze). Aus `bootstrap!/0` nach dem jeweiligen `ensure_table!`
  aufgerufen. Split der Bestands-`content_md` in generiert-/kuratiert-Slot nach
  dem rekonstruierbaren Herkunfts-Marker; Epos zusätzlich mit History-Rückholung
  bereits-geclobberter Edits.
  """
  alias Worker.Schema.Mnesia

  @session_summaries Mnesia.session_summaries()
  @epos_entries Mnesia.epos_entries()
  @chronik_entries Mnesia.chronik_entries()
  @chronik_overrides Mnesia.chronik_overrides()

  @doc """
  Issue #914 (Cut 0): Bestands-`markdown_body`-Edits der Chronik ins
  generation-immune Overlay heben (geschlüsselt auf der content-stabilen
  Eintrags-id). Idempotent: schreibt nur, wo noch KEIN Override existiert —
  ein nach der Erst-Migration per Event gesetzter Override wird bei einem
  Worker-Restart NICHT von der (evtl. stale) Row überschrieben.
  """
  def backfill_chronik_overrides! do
    {:atomic, :ok} =
      :mnesia.transaction(fn ->
        Enum.each(:mnesia.all_keys(@chronik_entries), fn id ->
          with [row] <- :mnesia.read(@chronik_entries, id),
               md when is_binary(md) and md != "" <- elem(row, 8),
               [] <- :mnesia.read(@chronik_overrides, id) do
            :mnesia.write({@chronik_overrides, id, elem(row, 2), md, nil, nil, nil})
          else
            _ -> :ok
          end
        end)
      end)

    :ok
  end

  # Issue #914 (Cut 0): kuratiert/generiert-Slots + Freigabe an session_summaries.
  # Split der Bestands-`content_md` nach dem verifiziert-rekonstruierbaren
  # Herkunfts-Marker `source`: :manual → curated_md (der Edit überlebt künftige
  # Rebuilds), sonst (:llm/:goldstandard/nil) → generated_md. Alle version_id/
  # event_id-Anker nil (keine History für Bestandszeilen); `content_md` bleibt
  # unverändert = die materialisierte Anzeige-Fassung (Reader unverändert).
  def migrate_session_summaries_add_render_slots! do
    current_attrs = :mnesia.table_info(@session_summaries, :attributes)

    if :generated_md in current_attrs do
      :ok
    else
      target_attrs = [
        :session_id,
        :campaign_id,
        :content_md,
        :generated_at,
        :source,
        :source_refs,
        :flagged_claims,
        :render_backend,
        :render_model,
        :generated_md,
        :generated_version_id,
        :generated_source,
        :curated_md,
        :curated_event_id,
        :released_version_id,
        :release_event_id
      ]

      transform = fn {tbl, sid, cid, content, ts, src, refs, flagged, rb, rm} ->
        # :manual → kuratiert-Slot (generated_source nil); sonst generiert-Slot
        # mit der echten Generat-Herkunft (:llm/:goldstandard/:imported).
        {gen, cur, gen_src} =
          if src == :manual, do: {nil, content, nil}, else: {content, nil, src}

        {tbl, sid, cid, content, ts, src, refs, flagged, rb, rm, gen, nil, gen_src, cur, nil, nil,
         nil}
      end

      {:atomic, :ok} = :mnesia.transform_table(@session_summaries, transform, target_attrs)
      :ok
    end
  end

  # Issue #914 (Cut 0): kuratiert/generiert-Slots + Freigabe an epos_entries.
  # Epos hat KEINE source-Spalte (Herkunft lebt nur in epos_history) → der
  # Split UND die Rückholung bereits-geclobberter Edits brauchen History-
  # Lookups. Zwei Schritte: (1) transform_table hängt 6 nil-Slots an,
  # (2) `backfill_epos_render_slots!` bestimmt pro Row aus der History die
  # Slot-Belegung (aktuelle Fassung + Rückholung des letzten :manual-Eintrags).
  def migrate_epos_entries_add_render_slots! do
    current_attrs = :mnesia.table_info(@epos_entries, :attributes)

    if :generated_md in current_attrs do
      :ok
    else
      target_attrs = [
        :id,
        :campaign_id,
        :parent_id,
        :content_md,
        :updated_at,
        :source_refs,
        :epos_backend,
        :epos_model,
        :generated_md,
        :generated_version_id,
        :curated_md,
        :curated_event_id,
        :released_version_id,
        :release_event_id
      ]

      transform = fn {tbl, id, cid, parent, content, upd, refs, eb, em} ->
        # 6 nil-Slots (= length(target_attrs) - 8 Bestandsfelder). NICHT 5 —
        # ein fehlender Slot ergibt ein 13-Feld-Tupel gegen 14 target_attrs →
        # :mnesia.transform_table bricht mit :bad_type ab. Der Bug schlug NUR
        # auf nicht-leeren Tabellen zu (leere Test-Tabelle exerziert die
        # Transform-fn nie); Prod-Crash beim ersten Boot mit echten Epos-Rows.
        {tbl, id, cid, parent, content, upd, refs, eb, em, nil, nil, nil, nil, nil, nil}
      end

      {:atomic, :ok} = :mnesia.transform_table(@epos_entries, transform, target_attrs)
      backfill_epos_render_slots!()
      :ok
    end
  end

  # Belegt generated_md/curated_md aus der epos_history:
  # - aktuelle Fassung ist :manual (letzter History-Eintrag) → kuratiert-Slot =
  #   content_md, generiert-Slot = letzter :llm-Eintrag (falls vorhanden).
  # - aktuelle Fassung ist :llm, aber ein früherer :manual-Eintrag existiert →
  #   RÜCKHOLUNG: kuratiert-Slot = dieser manuelle Text (rettet den geclobberten
  #   Edit; die Anzeige zeigt danach wieder die manuelle Fassung + Rebuild-Prompt).
  # - nur generiert → generiert-Slot = content_md.
  # content_md wird als Anzeige-Ableitung neu materialisiert.
  defp backfill_epos_render_slots! do
    {:atomic, :ok} =
      :mnesia.transaction(fn ->
        Enum.each(:mnesia.all_keys(@epos_entries), fn id ->
          [row] = :mnesia.read(@epos_entries, id)
          content = elem(row, 4)

          hist =
            :mnesia.index_read(Mnesia.epos_history(), id, :entry_id)
            # epos_history: {tbl, id, entry_id, content, edited_at, edited_by, source, seq}
            |> Enum.sort_by(&elem(&1, 7), :desc)

          latest = List.first(hist)
          latest_manual = Enum.find(hist, &(elem(&1, 6) == :manual))
          latest_llm = Enum.find(hist, &(elem(&1, 6) in [:llm, :goldstandard]))

          {gen_md, cur_md} =
            cond do
              latest && elem(latest, 6) == :manual ->
                {latest_llm && elem(latest_llm, 3), content}

              latest_manual ->
                {content, elem(latest_manual, 3)}

              true ->
                {content, nil}
            end

          display =
            Worker.Repo.Render.displayed(%{
              generated_md: gen_md,
              generated_version_id: nil,
              curated_md: cur_md,
              curated_event_id: nil,
              released_version_id: nil,
              release_event_id: nil
            })

          updated =
            row
            |> put_elem(4, display.content_md)
            |> put_elem(9, gen_md)
            |> put_elem(11, cur_md)

          :mnesia.write(updated)
        end)
      end)

    :ok
  end
end
