defmodule Worker.Schema.Migrations.FoldMeta do
  @moduledoc """
  Backfill-Migration für die generische I7-Bucket-C-Sidecar `@fold_meta`
  (Issue #766, God-Module-Split aus `Worker.Schema.Migrations` — der Zuwachs
  hier hätte die 1000-Zeilen-Grenze des Elternmoduls gerissen, siehe #544).

  Bewusst als eigenes Modul statt als weitere `migrate_*!/0`-Funktion im
  Eltern-Modul: die beiden Funktionen hier gehören als Backfill+Arity-Shrink-
  Paar zusammen (kein Seiteneffekt-Write im `transform_table`-Callback, daher
  zwei getrennte Schritte) und sind die einzige Stelle, die die
  `fold_meta`-Sidecar direkt beschreibt statt nur zu lesen/schreiben über
  `Worker.Materializer.fold_supersedes?/4`.
  """
  alias Worker.Schema.Mnesia

  @session_faithfulness_scores Mnesia.session_faithfulness_scores()
  @fold_meta Mnesia.fold_meta()

  # Issue #766 (I7-Bucket-C, Konsolidierung): die trailing `event_id`-Spalte
  # aus #781 an session_faithfulness_scores hat keine anderen Leser außer dem
  # eigenen Guard (verifiziert — die beiden Repo.Artifacts-Reader matchen den
  # Wert nur als `_event_id` und verwerfen ihn ungenutzt) — wird auf die
  # generische fold_meta-Sidecar migriert. `session_facts`s Pendant bleibt
  # bewusst UNMIGRIERT (Repo.Artifacts nutzt dessen event_id als
  # extraction_event_id für #724-Slice-F-Fact-Overrides — zweiter Leser,
  # siehe Kommentar an SessionFactsExtracted in apply2.ex). Zwei getrennte
  # Schritte (kein Seiteneffekt-Write im transform_table-Callback): erst
  # bestehende event_id-Werte nach fold_meta kopieren, dann die Spalte
  # droppen. Muss NACH ensure_table!(@fold_meta) laufen (siehe bootstrap!/0).
  def backfill_session_faithfulness_fold_meta! do
    if :event_id in :mnesia.table_info(@session_faithfulness_scores, :attributes) do
      {:atomic, :ok} =
        :mnesia.transaction(fn ->
          :mnesia.foldl(
            fn
              {_tbl, sid, _cid, _score, _claims, _ts, event_id}, :ok when not is_nil(event_id) ->
                :mnesia.write(
                  {@fold_meta, {@session_faithfulness_scores, sid, :session_faithfulness_scored},
                   event_id}
                )

                :ok

              _row, :ok ->
                :ok
            end,
            :ok,
            @session_faithfulness_scores
          )
        end)

      :ok
    else
      :ok
    end
  end

  def migrate_session_faithfulness_drop_event_id! do
    current_attrs = :mnesia.table_info(@session_faithfulness_scores, :attributes)

    if :event_id in current_attrs do
      target_attrs = [:session_id, :campaign_id, :score, :claims_json, :scored_at]

      transform = fn {tbl, sid, cid, score, claims, ts, _event_id} ->
        {tbl, sid, cid, score, claims, ts}
      end

      {:atomic, :ok} =
        :mnesia.transform_table(@session_faithfulness_scores, transform, target_attrs)

      :ok
    else
      :ok
    end
  end
end
