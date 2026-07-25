defmodule Worker.Schema.Migrations.Arcs do
  @moduledoc """
  Issue #905 (Epic #900 S3; Muster `Migrations.SessionFacts`): idempotente
  In-Place-Migrationen der `worker_arcs`-Tabelle — eigenes Submodul, weil
  `Worker.Schema.Migrations` am God-Module-Budget steht. Aus
  `Mnesia.bootstrap!/0` direkt nach dem `ensure_table!` aufgerufen.
  """

  alias Worker.Schema.Mnesia

  @arcs Mnesia.arcs()

  # Issue #905: trailing `merged_into` — der Arc-Merge-Redirect-Zeiger
  # (Quelle → Ziel-arc_id; nil/"" = kein Merge). Bestands-Worker 0.136.0
  # haben die 8-Spalten-Form; frische Worker booten direkt 9-spaltig →
  # der Attribut-Guard macht die Migration zum No-op. Alt-Rows nil.
  def migrate_add_merged_into! do
    current_attrs = :mnesia.table_info(@arcs, :attributes)

    if :merged_into in current_attrs do
      :ok
    else
      target_attrs = [
        :arc_id,
        :campaign_id,
        :seed_raw_labels,
        :leitfrage_draft,
        :act_kind,
        :act_grund,
        :act_wasserlinie,
        :leitfrage_kuratiert,
        :merged_into
      ]

      transform = fn {tbl, id, cid, seeds, draft, ak, ag, aw, lk} ->
        {tbl, id, cid, seeds, draft, ak, ag, aw, lk, nil}
      end

      {:atomic, :ok} = :mnesia.transform_table(@arcs, transform, target_attrs)
      :ok
    end
  end
end
