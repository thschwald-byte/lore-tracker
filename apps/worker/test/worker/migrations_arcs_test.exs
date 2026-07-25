defmodule Worker.MigrationsArcsTest do
  @moduledoc """
  Issue #905: die Add-Column-Migration `merged_into` auf `worker_arcs`.
  Gepinnt: der 8→9-Transform eines Bestands-Workers (0.136.0-Form, Alt-Rows
  bekommen trailing nil) UND der No-op-Guard (frischer 9-Spalten-Boot).
  Der Test baut die Tabelle bewusst auf die Alt-Form zurück und stellt sie
  über die Migration selbst wieder her (Endzustand = Bootstrap-Form).
  """

  use ExUnit.Case, async: false

  alias Worker.Schema.Migrations.Arcs, as: Migration
  alias Worker.Schema.Mnesia, as: S

  @alt_attrs [
    :arc_id,
    :campaign_id,
    :seed_raw_labels,
    :leitfrage_draft,
    :act_kind,
    :act_grund,
    :act_wasserlinie,
    :leitfrage_kuratiert
  ]

  test "8→9-Transform (Bestands-Worker) + No-op-Guard (frischer Boot)" do
    tbl = S.arcs()

    # Bestands-Form simulieren: 0.136.0 hatte 8 Spalten.
    {:atomic, :ok} = :mnesia.delete_table(tbl)

    :ok =
      Shared.Mnesia.ensure_table!(tbl, attributes: @alt_attrs, type: :set, index: [:campaign_id])

    :ok = :mnesia.dirty_write({tbl, "arc_mig", "c-mig", ["l"], "D?", "closed", "geloest", 3, nil})

    :ok = Migration.migrate_add_merged_into!()

    assert :merged_into in :mnesia.table_info(tbl, :attributes)
    # Alt-Row trägt trailing nil, alle Bestandsfelder unverändert.
    assert [{^tbl, "arc_mig", "c-mig", ["l"], "D?", "closed", "geloest", 3, nil, nil}] =
             :mnesia.dirty_read(tbl, "arc_mig")

    # No-op-Guard: zweiter Lauf (bzw. frischer 9-Spalten-Boot) tut nichts.
    :ok = Migration.migrate_add_merged_into!()
    assert length(:mnesia.table_info(tbl, :attributes)) == 9

    # Aufräumen (Endzustand = Bootstrap-Form, Row weg).
    :mnesia.dirty_delete(tbl, "arc_mig")
  end
end
