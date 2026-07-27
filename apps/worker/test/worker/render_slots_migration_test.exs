defmodule Worker.Schema.Migrations.RenderSlotsMigrationTest do
  @moduledoc """
  Issue #919: Regression gegen den `transform_table`-Arity-Off-by-one in den
  Cut-0-Slot-Migrationen (#914).

  Die Convergence-Tests (`render_slots_convergence_test.exs`) migrieren LEERE
  Tabellen → die `transform`-fn läuft dort NIE → der Bug (Epos-Output 13 statt
  14 Felder gegen 14 `target_attrs`) blieb bis zum ersten `worker_prod`-Boot
  mit echten Epos-Rows unentdeckt (`:mnesia.transform_table` → `:bad_type`,
  `bootstrap_storage!` crasht). Dieser Test baut die VOR-Cut-0-Arity nach,
  schreibt eine Bestands-Row und migriert sie — die `transform`-fn wird also
  garantiert exerziert.
  """
  use ExUnit.Case, async: false

  alias Worker.Repo.Render
  alias Worker.Schema.Migrations.RenderSlots
  alias Worker.Schema.Mnesia

  # ── Alte Arities (Zustand direkt vor #914) ──────────────────────────
  @epos_old_attrs [
    :id,
    :campaign_id,
    :parent_id,
    :content_md,
    :updated_at,
    :source_refs,
    :epos_backend,
    :epos_model
  ]

  @summary_old_attrs [
    :session_id,
    :campaign_id,
    :content_md,
    :generated_at,
    :source,
    :source_refs,
    :flagged_claims,
    :render_backend,
    :render_model
  ]

  defp recreate!(table, attrs) do
    :mnesia.delete_table(table)

    {:atomic, :ok} =
      :mnesia.create_table(table,
        attributes: attrs,
        type: :set,
        index: [:campaign_id],
        disc_copies: [node()]
      )

    :ok
  end

  test "Epos: nicht-leere Alt-Arity-Tabelle migriert ohne :bad_type (Regression #919)" do
    recreate!(Mnesia.epos_entries(), @epos_old_attrs)

    {:atomic, :ok} =
      :mnesia.transaction(fn ->
        # 8-Feld-Bestands-Row (9-Tupel inkl. Tabellen-Tag), keine History.
        :mnesia.write(
          {Mnesia.epos_entries(), "c-1", "c-1", "c-1", "Alt-Epos", DateTime.utc_now(), [], nil,
           nil}
        )
      end)

    assert :ok == RenderSlots.migrate_epos_entries_add_render_slots!()

    [row] = :mnesia.dirty_read(Mnesia.epos_entries(), "c-1")
    # tbl + 14 Felder = 15-Tupel. Der Off-by-one produzierte 14 → :bad_type.
    assert tuple_size(row) == 15
    assert elem(row, 9) == "Alt-Epos", "generated_md muss die Bestands-content_md tragen"
    assert elem(row, 4) == "Alt-Epos", "content_md-Anzeige wird neu materialisiert"

    d = Render.displayed(%{generated_md: elem(row, 9), curated_md: elem(row, 11)})
    assert d.content_md == "Alt-Epos"
    assert d.source == :generiert
  after
    # Tabelle bleibt in NEUER Arity (post-migration) → konsistent für Folge-Tests.
    :mnesia.clear_table(Mnesia.epos_entries())
  end

  test "Resümee (:llm): nicht-leere Alt-Arity-Tabelle migriert in generiert-Slot" do
    recreate!(Mnesia.session_summaries(), @summary_old_attrs)

    {:atomic, :ok} =
      :mnesia.transaction(fn ->
        :mnesia.write(
          {Mnesia.session_summaries(), "s-1", "c-1", "Alt-Resümee", DateTime.utc_now(), :llm, [],
           [], nil, nil}
        )
      end)

    assert :ok == RenderSlots.migrate_session_summaries_add_render_slots!()

    [row] = :mnesia.dirty_read(Mnesia.session_summaries(), "s-1")
    # tbl + 16 Felder = 17-Tupel.
    assert tuple_size(row) == 17
    assert elem(row, 10) == "Alt-Resümee", "generated_md"
    assert elem(row, 12) == :llm, "generated_source konserviert die echte Herkunft"
    assert elem(row, 13) == nil, "curated_md leer für generierte Row"
  after
    :mnesia.clear_table(Mnesia.session_summaries())
  end

  test "Resümee (:manual): Hand-Edit-Row landet im kuratiert-Slot" do
    recreate!(Mnesia.session_summaries(), @summary_old_attrs)

    {:atomic, :ok} =
      :mnesia.transaction(fn ->
        :mnesia.write(
          {Mnesia.session_summaries(), "s-2", "c-1", "Hand-Edit", DateTime.utc_now(), :manual, [],
           [], nil, nil}
        )
      end)

    assert :ok == RenderSlots.migrate_session_summaries_add_render_slots!()

    [row] = :mnesia.dirty_read(Mnesia.session_summaries(), "s-2")
    assert elem(row, 10) == nil, "generated_md leer — Hand-Edit ist keine Generierung"
    assert elem(row, 13) == "Hand-Edit", "curated_md trägt den Edit (überlebt Rebuilds)"

    d = Render.displayed(%{curated_md: elem(row, 13), curated_event_id: nil})
    assert d.source == :kuratiert
  after
    :mnesia.clear_table(Mnesia.session_summaries())
  end
end
