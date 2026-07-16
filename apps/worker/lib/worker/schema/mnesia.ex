defmodule Worker.Schema.Mnesia do
  @moduledoc """
  Table definitions for the worker's locally-replicated state.

  Each table is created idempotently from `bootstrap!/0`. Materializer
  writes; LiveView reads via `Worker.Repo`.

  Die idempotenten In-Place-Schema-Migrationen leben seit #606 in
  `Worker.Schema.Migrations` (aus `bootstrap!/0` pro Tabelle aufgerufen).
  """

  alias Worker.Schema.Migrations
  alias Worker.Schema.Migrations.FoldMeta

  # Singletons / known entities ─────────────────────────────────────
  @worker_state :worker_state
  @users :worker_users

  # Domain ──────────────────────────────────────────────────────────
  @campaigns :worker_campaigns
  @campaign_members :worker_campaign_members
  @campaign_invites :worker_campaign_invites
  @sessions :worker_sessions
  @utterances :worker_utterances
  @markers :worker_markers
  @epos_entries :worker_epos_entries
  @epos_history :worker_epos_history
  @session_summaries :worker_session_summaries
  @session_faithfulness_scores :worker_session_faithfulness_scores
  # Issue #651 (Wahrheitsbild, Phase A): per-Session extrahierte strukturierte
  # Fakten (eine Row/Session, `facts` = Liste von Fakt-Maps). Set-Semantik →
  # Re-Extraktion überschreibt. campaign_id-Index für list_campaign_facts.
  @session_facts :worker_session_facts
  @chronik_entries :worker_chronik_entries
  # Issue #698 (I7-Bucket-D): Clear-Watermark pro Session statt physischem Delete
  # bei ChronikClearedForSession. Ein chronik_entries-Row ist live gdw. sein
  # event_id (UUIDv7) > clear_key seiner Session → konvergent unter Umordnung
  # (kein Resurrection-Fenster mehr). Key = session_id, campaign_id-Index für
  # den Read-Filter + Cascade-Delete.
  @chronik_clear_marks :worker_chronik_clear_marks
  @probelauf_runs :worker_probelauf_runs
  @probelauf_sweeps :worker_probelauf_sweeps
  @applied_event_ids :worker_applied_event_ids
  @events_global :worker_events_global
  @audio_consents :worker_audio_consents
  @llm_spend :worker_llm_spend
  @speaker_assignments :worker_speaker_assignments
  # Issue #313: per-Campaign-per-Stage Vorgabe (Ausgabe-Name + Darstellungsform).
  # Eigene Tabelle statt trailing-Feld an @campaigns — additiv, ohne den weit
  # gematchten Campaign-Tuple anzufassen.
  @campaign_vorgaben :worker_campaign_vorgaben
  # Issue #724: per-Campaign-Kalender-Definition (calendar_json) + per-Session
  # In-Game-Datum-Anker. Beide EIGENE Tabellen statt trailing-Felder an
  # @campaigns/@sessions — dieselbe Arity-Bug-Vermeidung wie @campaign_vorgaben
  # (#313). @sessions insb. wird an vielen Stellen positional gematcht.
  @campaign_calendars :worker_campaign_calendars
  @session_anchors :worker_session_anchors
  # Issue #724 Slice F: GM-Korrektur eines einzelnen Review-Queue-Fakts (Datum
  # setzen oder dauerhaft ausblenden). EIGENE Overlay-Tabelle statt Patch am
  # session_facts-Blob — ein Read-Modify-Write des Blobs wäre order-sensitiv
  # (Cold-Replay-Divergenz) UND würde von Verify.verify_session zermahlt
  # (re-published SessionFactsExtracted mit Set-Semantik). Key = fo_key =
  # "<session_id>:<fact_id>" (dieselbe Composite-Key-Konvention wie
  # @campaign_vorgaben #313). Fakt-IDs sind rein positional (nicht run-
  # eindeutig) — `extraction_event_id` pinnt jeden Override an die
  # Extraktions-Generation, gegen die er gesetzt wurde, sonst würde er nach
  # einem Regenerate auf einen unbeteiligten Fakt an derselben Position
  # durchschlagen (Read-Merge in `Worker.Repo.Artifacts` prüft den Match).
  @session_fact_overrides :worker_session_fact_overrides
  # Issue #832 (Epic #829 Slice C): campaign-weite Handlungsbogen-Cluster-Map als
  # **Whole-Snapshot-Artefakt** — 1 Row/Kampagne, kompletter JSON-Blob pro Lauf.
  # Anders als EntityRegistry (die `entity_id` in den Fakt-Blob zurück-re-keyt)
  # hält die ThreadRegistry ihre Map separat; die Fakten behalten ihr Roh-`thread`-
  # Label, der Reader (`campaign_threads/1`, #833) wendet die Map zur Lesezeit an.
  # Vorteil: kein zweiter Fakt-Schreibpfad, Re-Cluster = 1-Row-Write, und die
  # Whole-Snapshot-Semantik macht LWW-per-Kampagne partial-payload-frei.
  @thread_registry :worker_thread_registry
  # Issue #836 (Epic #829 Slice D2): Member-Kurations-Overlay auf die abgeleiteten
  # Handlungsstränge (rename/merge/resolve/dismiss). Key = "<cid>:<norm_canonical>:
  # <identity|lifecycle>" — die zwei Dimensionen sind SEPARATE Zeilen, damit jede
  # ein reiner Whole-Snapshot-LWW-Upsert bleibt (kein order-sensitives RMW, s.
  # session_fact_overrides-#698-Lektion). Nie ein :mnesia.delete: auch Undo
  # (clear_identity/reactivate) schreibt eine reguläre Row. Overlay am Read
  # (campaign_threads/1) — die Fakten selbst bleiben unangetastet.
  @thread_overrides :worker_thread_overrides
  # Issue #863 (Epic #861 Slice B): geglättetes Transkript pro Session als
  # **Whole-Snapshot-Artefakt** (Stage 1.1, #862) — 1 Row/Session, kompletter
  # JSON-Blob (Blöcke + ooc_verworfen + rules_version + merge_gap_seconds).
  # Block-IDs sind CONTENT-adressiert (#862/K1), nicht positional. LWW über die
  # inline event_id-Spalte (Muster session_facts, kein fold_meta — der Blob
  # wird als Ganzes ersetzt, nie ge-merged).
  @smoothed_blocks :worker_smoothed_blocks
  # Issue #68 (Phase 1): strukturiertes Pipeline-Fehler-Log für /admin/errors.
  # Issue #605: Retention via `Worker.PipelineErrorLog` (Keep-last-N, Boot-
  # Hook + periodisch alle 1h durch `Worker.PipelineErrorLog.Pruner`). Key
  # = UUIDv7-error_id (zeit-geordnet → „letzte N" via Sort).
  @pipeline_errors :worker_pipeline_errors
  # Issue #766 (I7-Bucket-C, Sidecar statt N Einzel-Migrationen): generische
  # LWW-Sidecar für Folds ohne eigenen Per-Write-Anker. Key = {target_table,
  # row_key, fold} — fold ist i.d.R. das Event-Kind (snake_case), außer wenn
  # mehrere Event-Kinds um dasselbe Feld derselben Row konkurrieren (dann
  # geteilter Fold-Name, z.B. :invite_status für InviteRevoked+InviteRedeemed).
  @fold_meta :worker_fold_meta

  def worker_state, do: @worker_state
  def users, do: @users
  def campaigns, do: @campaigns
  def campaign_members, do: @campaign_members
  def campaign_invites, do: @campaign_invites
  def sessions, do: @sessions
  def utterances, do: @utterances
  def markers, do: @markers
  def epos_entries, do: @epos_entries
  def epos_history, do: @epos_history
  def session_summaries, do: @session_summaries
  def session_faithfulness_scores, do: @session_faithfulness_scores
  def session_facts, do: @session_facts
  def chronik_entries, do: @chronik_entries
  def chronik_clear_marks, do: @chronik_clear_marks
  def probelauf_runs, do: @probelauf_runs
  def probelauf_sweeps, do: @probelauf_sweeps
  def applied_event_ids, do: @applied_event_ids
  def events_global, do: @events_global
  def audio_consents, do: @audio_consents
  def llm_spend, do: @llm_spend
  def speaker_assignments, do: @speaker_assignments
  def campaign_vorgaben, do: @campaign_vorgaben
  def campaign_calendars, do: @campaign_calendars
  def session_anchors, do: @session_anchors
  def session_fact_overrides, do: @session_fact_overrides
  def thread_registry, do: @thread_registry
  def thread_overrides, do: @thread_overrides
  def smoothed_blocks, do: @smoothed_blocks
  def fold_meta, do: @fold_meta
  def pipeline_errors, do: @pipeline_errors

  def bootstrap! do
    # Issue #766: fold_meta zuerst — Backfill-Migrationen weiter unten
    # (session_facts/session_faithfulness_scores) schreiben schon hinein und
    # brauchen die Tabelle vorher angelegt.
    :ok =
      Shared.Mnesia.ensure_table!(@fold_meta,
        attributes: [:key, :event_id],
        type: :set
      )

    :ok =
      Shared.Mnesia.ensure_table!(@worker_state,
        attributes: [:key, :value],
        type: :set
      )

    :ok =
      Shared.Mnesia.ensure_table!(@users,
        attributes: [
          :discord_id,
          :display_name,
          :joined_at,
          :avatar_url,
          :role,
          :monthly_spend_cap_usd
        ],
        type: :set
      )

    :ok = Migrations.migrate_users_avatar_url!()
    :ok = Migrations.migrate_users_role!()
    :ok = Migrations.migrate_users_monthly_spend_cap_usd!()

    :ok =
      Shared.Mnesia.ensure_table!(@campaigns,
        attributes: [
          :id,
          :name,
          :icon_url,
          :theme_blurb,
          :status,
          :created_at,
          :flavors,
          :vocab_hint,
          :transcript_source
        ],
        type: :set
      )

    :ok = Migrations.migrate_campaigns_flavor!()
    :ok = Migrations.migrate_campaigns_flavors!()
    :ok = Migrations.migrate_campaigns_drop_owner_discord_id!()
    :ok = Migrations.migrate_campaigns_repair_swapped_created_at_flavors!()
    :ok = Migrations.migrate_campaigns_add_vocab_hint!()
    :ok = Migrations.migrate_campaigns_add_transcript_source!()

    # Issue #313: Vorgabe pro Campaign × Stage. vg_key = "<campaign_id>:<stage>".
    # name = Ausgabe-Überschrift ("Epos"/"Polizeiakte"/…), darstellungsform ∈
    # "fliesstext" | "stichpunkte". Fehlende Row = Default pro Stage.
    :ok =
      Shared.Mnesia.ensure_table!(@campaign_vorgaben,
        attributes: [:vg_key, :campaign_id, :stage, :name, :darstellungsform],
        type: :set,
        index: [:campaign_id]
      )

    # Issue #724: per-Campaign-Kalender-Definition. calendar_json = Jason-encoded
    # %{"months" => [...], "epoch_label" => ...}. Fehlende Row → Calendar.default/0
    # (Repo.get_campaign_calendar/1). Key = campaign_id, kein Index nötig.
    :ok =
      Shared.Mnesia.ensure_table!(@campaign_calendars,
        attributes: [:campaign_id, :calendar_json, :updated_at],
        type: :set
      )

    # Issue #832 (Epic #829 Slice C): Handlungsbogen-Cluster-Map, 1 Row/Kampagne.
    # Key = campaign_id, kein Index nötig (Reader liest per campaign_id direkt).
    # cluster_map_json = Jason-encodete `%{roh_label => canonical}`-Map.
    :ok =
      Shared.Mnesia.ensure_table!(@thread_registry,
        attributes: [:campaign_id, :cluster_map_json, :updated_at],
        type: :set
      )

    # Issue #836: Member-Kurations-Overlay. Key = "<cid>:<norm_canonical>:<dim>".
    # :campaign_id-Index für Reader-List + CampaignDeleted-Cascade. new_name/
    # merge_into nur bei der Identitäts-Dimension gesetzt, sonst nil.
    :ok =
      Shared.Mnesia.ensure_table!(@thread_overrides,
        attributes: [
          :ov_key,
          :campaign_id,
          :canonical,
          :dimension,
          :action,
          :new_name,
          :merge_into,
          :event_id
        ],
        type: :set,
        index: [:campaign_id]
      )

    # Issue #724: per-Session In-Game-Datum-Anker (Tageszähler + GM-Roh-String).
    # Eigene Tabelle statt trailing @sessions-Spalten (Arity-Fan-out-Vermeidung).
    # in_game_day = kanonischer Tageszähler (Repo.get_session_anchor_day/1);
    # in_game_date_raw = GM-Eingabe für Re-Resolve bei Kalenderänderung.
    :ok =
      Shared.Mnesia.ensure_table!(@session_anchors,
        attributes: [:session_id, :campaign_id, :in_game_day, :in_game_date_raw],
        type: :set,
        index: [:campaign_id]
      )

    # Issue #724 Slice F: Review-Queue-Fakt-Override (fo_key = "sid:fact_id").
    # event_id (UUIDv7) trailing für den LWW-Guard (Materializer.Apply2) — der
    # Fold macht IMMER einen Upsert, NIE ein Delete (auch der Undo-Fall
    # `in_game_date_raw == ""` schreibt eine reguläre Row), sonst wäre ein
    # vertauschtes Set→Undo-Paar order-sensitiv divergent (#698-Klasse).
    # `extraction_event_id` pinnt den Override an die Extraktions-Generation,
    # gegen die der GM ihn gesetzt hat — Fakt-IDs sind rein positional
    # (`"f#{i}"`, NICHT run-eindeutig), ohne diesen Anker würde ein Override
    # nach einem Regenerate auf einen unbeteiligten neuen Fakt an derselben
    # Position durchschlagen (Cross-Contamination). Der Read-Merge
    # (`Worker.Repo.Artifacts`) wendet den Override nur bei Generation-Match an.
    :ok =
      Shared.Mnesia.ensure_table!(@session_fact_overrides,
        attributes: [
          :fo_key,
          :session_id,
          :campaign_id,
          :fact_id,
          :extraction_event_id,
          :in_game_date_raw,
          :dismissed,
          :event_id
        ],
        type: :set,
        index: [:session_id, :campaign_id]
      )

    :ok =
      Shared.Mnesia.ensure_table!(@campaign_members,
        attributes: [
          :cm_key,
          :campaign_id,
          :discord_id,
          :role,
          :joined_at,
          :character_name,
          :deleted_at
        ],
        type: :set,
        index: [:campaign_id, :discord_id]
      )

    :ok = Migrations.migrate_campaign_members_character_name!()
    :ok = Migrations.migrate_campaign_members_deleted_at!()
    :ok = Migrations.migrate_campaign_members_role_rename!()

    :ok =
      Shared.Mnesia.ensure_table!(@sessions,
        attributes: [
          :id,
          :campaign_id,
          :number,
          :name,
          :status,
          :scheduled_for,
          :started_at,
          :ended_at
        ],
        type: :set,
        index: [:campaign_id]
      )

    :ok =
      Shared.Mnesia.ensure_table!(@campaign_invites,
        attributes: [
          :token,
          :campaign_id,
          :created_by_discord_id,
          :created_at,
          :expires_at,
          :status,
          :redeemed_by_discord_id
        ],
        type: :set,
        index: [:campaign_id]
      )

    :ok =
      Shared.Mnesia.ensure_table!(@utterances,
        attributes: [
          :id,
          :session_id,
          :discord_id,
          :timestamp,
          :text,
          :confidence,
          :status,
          :deleted_at
        ],
        type: :set,
        index: [:session_id]
      )

    :ok = Migrations.migrate_utterances_deleted_at!()

    :ok =
      Shared.Mnesia.ensure_table!(@markers,
        attributes: [:id, :session_id, :at_ts, :kind, :label],
        type: :set,
        index: [:session_id]
      )

    # One Epos entry per campaign for M7 (entry_id == campaign_id). The schema
    # has a parent_id slot so M7+ can add a chapter tree without a migration.
    :ok =
      Shared.Mnesia.ensure_table!(@epos_entries,
        attributes: [:id, :campaign_id, :parent_id, :content_md, :updated_at, :source_refs],
        type: :set,
        index: [:campaign_id]
      )

    :ok = Migrations.migrate_epos_entries_add_source_refs!()
    # Issue #783 Phase 2 (Nachtrag, Design E): epos_backend/epos_model-Provenance.
    :ok = Migrations.migrate_epos_entries_add_render_provenance!()

    :ok =
      Shared.Mnesia.ensure_table!(@epos_history,
        attributes: [
          :id,
          :entry_id,
          :content_md,
          :edited_at,
          :edited_by,
          :source,
          :seq
        ],
        type: :set,
        index: [:entry_id]
      )

    :ok =
      Shared.Mnesia.ensure_table!(@session_summaries,
        attributes: [
          :session_id,
          :campaign_id,
          :content_md,
          :generated_at,
          :source,
          :source_refs,
          :flagged_claims
        ],
        type: :set,
        index: [:campaign_id]
      )

    :ok = Migrations.migrate_session_summaries_add_source_refs!()
    :ok = Migrations.migrate_session_summaries_add_flagged_claims!()
    # Issue #783 Phase 2 (Design E): render_backend/render_model-Provenance.
    :ok = Migrations.migrate_session_summaries_add_render_provenance!()

    # Issue #11 Phase 2: Faithfulness-Score pro Session-Resümee.
    # claims_json = Jason-encoded List of %{text, span, label} — bleibt JSON
    # weil Mnesia-Records keine verschachtelten Listen gut handhaben.
    :ok =
      Shared.Mnesia.ensure_table!(@session_faithfulness_scores,
        attributes: [:session_id, :campaign_id, :score, :claims_json, :scored_at],
        type: :set,
        index: [:campaign_id]
      )

    # Issue #781 (I7-Bucket-C): event_id-Spalte für den LWW-Guard.
    :ok = Migrations.migrate_session_faithfulness_add_event_id!()

    # Issue #766: auf die generische fold_meta-Sidecar konsolidiert — Backfill
    # VOR dem Spalten-Rückbau (Reihenfolge bindend, siehe fold_meta oben).
    :ok = FoldMeta.backfill_session_faithfulness_fold_meta!()
    :ok = FoldMeta.migrate_session_faithfulness_drop_event_id!()

    # Issue #651 (Wahrheitsbild, Phase A): strukturierte Fakten pro Session.
    # facts_json = Jason-encoded Liste von Fakt-Maps — wie claims_json oben
    # JSON, weil Mnesia-Records verschachtelte Maps/Listen schlecht handhaben.
    :ok =
      Shared.Mnesia.ensure_table!(@session_facts,
        attributes: [:session_id, :campaign_id, :facts_json, :extracted_at],
        type: :set,
        index: [:campaign_id]
      )

    # Issue #781 (I7-Bucket-C): event_id-Spalte für den LWW-Guard.
    # Issue #766: bewusst NICHT auf die fold_meta-Sidecar migriert — die
    # Spalte hat einen zweiten Leser (Repo.Artifacts.get_session_facts/1 +
    # list_campaign_facts/1, extraction_event_id-Pinning für #724-Slice-F-
    # Fact-Overrides). Anders als session_faithfulness_scores unten, siehe
    # #816-PR.
    :ok = Migrations.SessionFacts.migrate_add_event_id!()
    # Issue #783 Phase 2 (Design E): verify_backend/verify_model-Provenance.
    :ok = Migrations.SessionFacts.migrate_add_verify_provenance!()
    # Issue #864 (Epic #861 Slice C): extraction_saw-Zeit-Adresse.
    :ok = Migrations.SessionFacts.migrate_add_extraction_saw!()

    # Issue #863 (Epic #861 Slice B): geglättetes Transkript (Stage 1.1, #862).
    # snapshot_json = Jason-encoded %{blocks, ooc_verworfen, rules_version,
    # merge_gap_seconds} — Whole-Snapshot pro Session, LWW via event_id-Spalte
    # (frische Tabelle → Spalte direkt in den Attributen, keine Migration).
    :ok =
      Shared.Mnesia.ensure_table!(@smoothed_blocks,
        attributes: [:session_id, :campaign_id, :snapshot_json, :smoothed_at, :event_id],
        type: :set,
        index: [:campaign_id]
      )

    :ok =
      Shared.Mnesia.ensure_table!(@chronik_entries,
        attributes: [
          :id,
          :campaign_id,
          :in_game_date,
          :label,
          :summary,
          :session_id,
          :source_refs,
          :markdown_body,
          :in_game_day,
          :precision
        ],
        type: :set,
        index: [:campaign_id]
      )

    :ok = Migrations.migrate_chronik_entries_drop_sort_key!()
    :ok = Migrations.migrate_chronik_entries_add_source_refs!()
    :ok = Migrations.migrate_chronik_entries_add_markdown_body!()
    :ok = Migrations.migrate_chronik_entries_add_timeline!()
    # Issue #698 (I7): generation-Spalte für den Clear-Watermark-Vergleich.
    :ok = Migrations.migrate_chronik_entries_add_generation!()

    # Issue #698 (I7-Bucket-D): Clear-Watermark pro Session. clear_key = max
    # event_id (UUIDv7) der ChronikClearedForSession-Events dieser Session.
    :ok =
      Shared.Mnesia.ensure_table!(@chronik_clear_marks,
        attributes: [:session_id, :campaign_id, :clear_key],
        type: :set,
        index: [:campaign_id]
      )

    # Issue #74: LLM-Probelauf. Pro Probelauf eine Row mit gemessenen
    # Per-Stage-Metriken und Settings-Snapshot. UI zeigt aktuell nur den
    # letzten, aber spätere Phasen können hier historisch vergleichen.
    # Issue #88 (Phase 2a): `sweep_id` + `sweep_variant` (Map oder nil)
    # taggen Runs, die Teil eines Sweep-Laufs sind.
    :ok =
      Shared.Mnesia.ensure_table!(@probelauf_runs,
        attributes: [
          :run_id,
          :started_at,
          :finished_at,
          :started_by,
          :sessions,
          :settings_snapshot,
          :sweep_id,
          :sweep_variant
        ],
        type: :set,
        index: [:sweep_id]
      )

    :ok = Migrations.migrate_probelauf_runs_sweep_tags!()

    # Issue #88 (Phase 2a): Sweep-Header. Verlinkt N probelauf_runs via
    # gemeinsamem sweep_id.
    # Issue #281: :variants ergänzt für isolated-Sweep (start_sweep_isolated/3
    # publisht ProbelaufSweepFinished mit "variants" => […] — wurde vorher
    # ignoriert).
    :ok =
      Shared.Mnesia.ensure_table!(@probelauf_sweeps,
        attributes: [
          :sweep_id,
          :started_at,
          :finished_at,
          :started_by,
          :stage,
          :models,
          :default_model,
          :variants
        ],
        type: :set
      )

    :ok = Migrations.migrate_probelauf_sweeps_add_variants!()

    # Issue #123 (Etappe 2): id-basierte Idempotenz für Worker-First-Apply.
    # Jeder applied Event landet hier mit seinem event_id (UUIDv7). Erlaubt
    # Skip beim Hub-Broadcast-Reapply nach lokalem Apply. applied_at_seq ist
    # nil für reine lokal-applied Events (Hub-Sync war :pending), wird beim
    # späteren Hub-Broadcast nachgefüllt.
    :ok =
      Shared.Mnesia.ensure_table!(@applied_event_ids,
        attributes: [:event_id, :applied_at_seq],
        type: :set
      )

    # Issue #127 (Etappe 3a): Event-Store für campaign-lose Events
    # (UserRoleSet, UserUpserted, ProbelaufStarted/Finished, ProbelaufSweep*).
    # Pro-Campaign-Stores werden dynamisch via Worker.Schema.DynamicTables
    # erzeugt — diese hier ist die statische Global-Tabelle.
    :ok =
      Shared.Mnesia.ensure_table!(@events_global,
        attributes: [:event_id, :hub_seq, :payload, :ts],
        type: :ordered_set
      )

    # Issue #64: Audio-Aufnahme-Consent pro User. version taggt das
    # Policy-Wording-Set ("v1") — wenn der Text später materiell ändert,
    # kann eine v2 die User erneut zur Bestätigung zwingen.
    :ok =
      Shared.Mnesia.ensure_table!(@audio_consents,
        attributes: [:discord_id, :version, :accepted_at],
        type: :set
      )

    # Issue #177: Spend-Tracking für Cloud-LLM-Calls. PK ist event_id
    # (UUIDv7) — chronologisch sortiert + dedupliziert über Materializer.
    # ts ist Indexed für effiziente Datums-Range-Queries im /admin/spend-LV.
    :ok =
      Shared.Mnesia.ensure_table!(@llm_spend,
        attributes: [
          :event_id,
          :ts,
          :provider,
          :model,
          :input_tokens,
          :output_tokens,
          :cost_usd,
          :requested_by_discord_id,
          :session_id,
          :stage,
          :duration_ms
        ],
        type: :set,
        index: [:ts, :provider, :requested_by_discord_id]
      )

    # Issue #19: Sprecher-Zuordnung für Single-Source-Aufnahmen. PK ist das
    # Composite {session_id, speaker_label}, damit Re-Assignment idempotent
    # überschreibt. Utterances behalten ihr Pseudo-Label; diese Tabelle
    # mappt Pseudo-Label → echte discord_id, aufgelöst beim Lesen. :session_id
    # indexed für den Snapshot-Lookup pro Kampagne.
    :ok =
      Shared.Mnesia.ensure_table!(@speaker_assignments,
        attributes: [:sa_key, :session_id, :speaker_label, :discord_id, :assigned_at],
        type: :set,
        index: [:session_id]
      )

    # Issue #68 (Phase 1): Pipeline-Fehler-Log. `error_id` ist UUIDv7 → in
    # der Praxis zeit-geordnet, „letzte N" sortiert beim Read. Issue #605:
    # Keep-last-N-Prune via `Worker.PipelineErrorLog` haelt die Tabelle nach
    # oben gedeckelt (Default 1000).
    :ok =
      Shared.Mnesia.ensure_table!(@pipeline_errors,
        attributes: [
          :error_id,
          :occurred_at,
          :session_id,
          :campaign_id,
          :stage,
          :error_type,
          :message,
          :context
        ],
        type: :set,
        index: [:session_id, :campaign_id]
      )
  end

  @doc "Composite PK helper for speaker_assignments."
  def speaker_assignment_key(session_id, speaker_label), do: {session_id, speaker_label}

  @doc "Composite PK helper for campaign_members."
  def member_key(campaign_id, discord_id), do: {campaign_id, discord_id}
end
