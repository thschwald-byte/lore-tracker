defmodule Worker.Schema.Migrations.SessionFacts do
  @moduledoc """
  Issue #864 (God-Module-Split aus `Worker.Schema.Migrations`, Muster
  `Migrations.FoldMeta`): die idempotenten In-Place-Migrationen der
  `worker_session_facts`-Tabelle — kohäsiv gebündelt, aus `Mnesia.bootstrap!/0`
  in Deklarations-Reihenfolge aufgerufen (jede transformiert vom Vorgänger-Shape).
  """

  alias Worker.Schema.Mnesia

  @session_facts Mnesia.session_facts()

  # Issue #781 (I7-Bucket-C): trailing `event_id` — Ordnungsschlüssel für den
  # LWW-Guard (Re-Extraktion gewinnt nur bei event_id > gespeichert →
  # order-insensitiv). Alt-Rows nil.
  def migrate_add_event_id! do
    current_attrs = :mnesia.table_info(@session_facts, :attributes)

    if :event_id in current_attrs do
      :ok
    else
      target_attrs = [:session_id, :campaign_id, :facts_json, :extracted_at, :event_id]
      transform = fn {tbl, sid, cid, facts, ts} -> {tbl, sid, cid, facts, ts, nil} end
      {:atomic, :ok} = :mnesia.transform_table(@session_facts, transform, target_attrs)
      :ok
    end
  end

  # Issue #783 Phase 2 (Design E, Provenance-Stempel): trailing
  # `verify_backend`/`verify_model` — mit welchem Backend+Modell das Verify-Gate
  # DIESE Fakten geprüft hat (backend_stage3 ist frei drehbar; ohne Stempel wäre
  # ein Wechsel zwischen zwei Sessions unsichtbar). Alt-Rows nil.
  def migrate_add_verify_provenance! do
    current_attrs = :mnesia.table_info(@session_facts, :attributes)

    if :verify_backend in current_attrs do
      :ok
    else
      target_attrs = [
        :session_id,
        :campaign_id,
        :facts_json,
        :extracted_at,
        :event_id,
        :verify_backend,
        :verify_model
      ]

      transform = fn {tbl, sid, cid, facts, ts, event_id} ->
        {tbl, sid, cid, facts, ts, event_id, nil, nil}
      end

      {:atomic, :ok} = :mnesia.transform_table(@session_facts, transform, target_attrs)
      :ok
    end
  end

  # Issue #864 (Epic #861 Slice C): trailing `extraction_saw_json` — die
  # Zeit-Adresse (%{block_id => effective_text_hash}) des Extraktions-Laufs.
  # Die Dirty-Weiche (Slice F) vergleicht Kurations-Texte dagegen; der
  # verify_session-Republish schleppt sie feldkonservativ mit. Alt-Rows nil
  # (Pre-Block-Extraktionen haben keine Zeit-Adresse — fail-closed: fehlender
  # Eintrag ⇒ Re-Extract, F1 Runde 6).
  def migrate_add_extraction_saw! do
    current_attrs = :mnesia.table_info(@session_facts, :attributes)

    if :extraction_saw_json in current_attrs do
      :ok
    else
      target_attrs = [
        :session_id,
        :campaign_id,
        :facts_json,
        :extracted_at,
        :event_id,
        :verify_backend,
        :verify_model,
        :extraction_saw_json
      ]

      transform = fn {tbl, sid, cid, facts, ts, event_id, vb, vm} ->
        {tbl, sid, cid, facts, ts, event_id, vb, vm, nil}
      end

      {:atomic, :ok} = :mnesia.transform_table(@session_facts, transform, target_attrs)
      :ok
    end
  end
end
