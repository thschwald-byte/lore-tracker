defmodule Shared.Events do
  @moduledoc """
  Event types that travel through `Hub.EventLog`.

  Wire format is a JSON-shaped map with a `"kind"` field plus event-specific
  fields. Worker.Materializer pattern-matches on `"kind"` to dispatch.

  Why plain maps and not structs: the Phoenix.Socket V2 serializer is JSON,
  and structs round-tripped through JSON lose their identity anyway. Once
  we have many event types and the materializer dispatch gets hairy, we
  can revisit (e.g. introduce a `from_wire/1`/`to_wire/1` per kind module).

  This module just collects the kind constants so producers and the
  materializer agree on the strings.

  Issue #539: zusätzlich das Compile-Zeit-Makro `k/1` — expandiert
  `k(:session_ended)` zum Literal `"SessionEnded"` und ist damit auch in
  CONSUMER-Pattern-Heads nutzbar (Funktions-Calls sind dort syntaktisch
  verboten, Literale nicht). Unbekannter Kind → Compile-Fehler am Call-Site.
  """

  @doc """
  Issue #539: Compile-Zeit-Makro für Event-Kinds. `k(:utterance_appended)`
  expandiert zum Wire-Literal `"UtteranceAppended"` — Pattern-Head-tauglich
  für Producer UND Consumer. Validiert zur Expansionszeit gegen die 0-arity-
  Konstanten dieses Moduls (dieselbe SSoT wie `all/0`, keine Zweitliste):
  ein Tippfehler oder ein Rename bricht ÜBERALL laut zur Compile-Zeit.

  Caller-Konvention: `alias Shared.Events, as: Events` + `require Events`,
  dann `Events.k(:session_ended)` in Emit und Match.
  """
  defmacro k(kind) when is_atom(kind) do
    if kind == :all or not function_exported?(__MODULE__, kind, 0) do
      raise ArgumentError,
            "Shared.Events.k/1: unbekannter Event-Kind #{inspect(kind)} — " <>
              "keine 0-arity-Konstante in Shared.Events (Tippfehler? Rename?)"
    end

    str = apply(__MODULE__, kind, [])

    unless is_binary(str) and str =~ ~r/^[A-Z][A-Za-z0-9]+$/ do
      raise ArgumentError,
            "Shared.Events.k/1: #{inspect(kind)} liefert keinen Wire-Kind-String"
    end

    quote do: unquote(str)
  end

  defmacro k(other) do
    raise ArgumentError,
          "Shared.Events.k/1 erwartet ein Atom-Literal (z.B. k(:session_ended)), " <>
            "bekam: #{Macro.to_string(other)}"
  end

  # Campaigns
  def campaign_created, do: "CampaignCreated"
  def campaign_updated, do: "CampaignUpdated"
  def campaign_vocab_updated, do: "CampaignVocabUpdated"
  # Issue #394: per-Kampagne, ob die LLM-Pipeline live- oder batch(confirmed)-
  # Utterances als Quelle nutzt ("live" | "confirmed").
  def campaign_transcript_source_updated, do: "CampaignTranscriptSourceUpdated"

  # Sessions
  def session_scheduled, do: "SessionScheduled"
  def session_started, do: "SessionStarted"
  def session_ended, do: "SessionEnded"

  # Invites & members
  def invite_created, do: "InviteCreated"
  def invite_revoked, do: "InviteRevoked"
  def invite_redeemed, do: "InviteRedeemed"
  def member_removed, do: "MemberRemoved"

  # Per-Campaign-Rolle ändern (Issue #140): Spielleiter befördert einen
  # :spieler-Member zu :spielleiter (Co-GM), oder demoted zurück.
  # Payload: `%{campaign_id, discord_id, new_role, promoted_by}` mit
  # `new_role ∈ "spielleiter" | "spieler"`. Materializer updated
  # `campaign_members.role` für die `discord_id`. Permission liegt am LV
  # (Promote-Button nur sichtbar wenn caller bereits per-Campaign-:spielleiter).
  def member_role_promoted, do: "MemberRolePromoted"

  # Recording / transcript
  def recording_state_changed, do: "RecordingStateChanged"
  def utterance_appended, do: "UtteranceAppended"
  # Manuelle Korrektur einer Utterance (Issue #3). Payload:
  # `%{id, session_id, new_text, edited_by}`. Materializer überschreibt
  # text + setzt status: :edited.
  def utterance_edited, do: "UtteranceEdited"
  # Manuelle Löschung einer Utterance. Payload `%{id, session_id, deleted_by}`.
  # Materializer löscht die Row hart — Audit ist im EventLog.
  def utterance_deleted, do: "UtteranceDeleted"
  # Issue #19: Sprecher-Zuordnung für Single-Source-Aufnahmen. Payload:
  # `%{session_id, speaker_label, discord_id, assigned_by}`. `speaker_label`
  # ist das Pseudo-Label `speaker:<session_id>:<n>` das die Diarisierung
  # vergeben hat. `discord_id` non-nil → Zuordnung; nil/leer → Aufhebung.
  # Materializer pflegt die `worker_speaker_assignments`-Tabelle; Utterances
  # behalten ihr Pseudo-Label, Auflösung passiert beim Lesen.
  def speaker_assigned, do: "SpeakerAssigned"
  def marker_added, do: "MarkerAdded"

  # Epos
  # Issue #114: Payload trägt optional `source_refs: [utterance_id, ...]` —
  # die Liste der Utterances die in diesen Epos-Eintrag eingeflossen sind
  # (über die Stage-2-Summaries verkettet). Backward-kompat: fehlend = [].
  def epos_entry_edited, do: "EposEntryEdited"

  # Summary / Chronik (Stages 2 + 4 of the LLM pipeline; also manually editable)
  # Issue #114: Payload trägt optional `source_refs: [utterance_id, ...]` —
  # die Stage-2-LLM emittiert sie pro Resümee aus der Liste der Utterances,
  # die ihm im JSON-Mode-Prompt zur Verfügung gestellt wurden. Backward-
  # kompat: fehlend = [].
  def session_summary_generated, do: "SessionSummaryGenerated"
  def session_summary_edited, do: "SessionSummaryEdited"

  # Issue #914 (Cut 0): Freigabe einer generierten Prosa-Fassung durch den
  # Kurator. Payload: `%{artifact_type, artifact_key, version_id, set_by}` —
  # `artifact_type` ∈ "summary"|"epos"|"chronik", `artifact_key` = session_id
  # bzw. entry_id, `version_id` = die `version_id` (event_id des erzeugenden
  # Generated-Events) der freigegebenen generierten Fassung. Die Anzeige-
  # Ableitung (`Repo.Render`-Slots) zeigt die generierte Fassung nur, solange
  # eine Freigabe für GENAU die aktuell vorliegende `version_id` der jüngste
  # Kurator-Akt ist — ein neuer Rebuild vergibt eine neue version_id → die
  # Freigabe greift nicht mehr → „übernehmen?"-Prompt erscheint wieder.
  # Einmal-Zustimmung ist damit strukturell die einzige darstellbare Form
  # (nie „alle künftigen Rebuilds vorab akzeptiert"). event_id-LWW, KEIN
  # updated_at (order-insensitiv, #781-Muster).
  def render_release_set, do: "RenderReleaseSet"
  # Issue #114: Payload trägt optional `source_refs: [utterance_id, ...]` —
  # Stage 4 emittiert die utterance_ids pro Chronik-Eintrag aus dem Epos-
  # Kontext + der verfügbaren Utterance-Liste der Session. Backward-kompat:
  # fehlend = [].
  def chronik_entry_changed, do: "ChronikEntryChanged"

  # Issue #227: Stage-4-Re-Run-Cleanup. Vor jedem Stage-4-Publish einer
  # Session emittiert die Pipeline diesen Event, damit alle alten Chronik-
  # Rows mit derselben session_id idempotent gelöscht werden. So
  # akkumulieren sich Halluzinationen nicht über Re-Runs hinweg.
  # Payload: `%{campaign_id, session_id, cleared_by}` mit
  # cleared_by ∈ "llm" | "manual".
  def chronik_cleared_for_session, do: "ChronikClearedForSession"

  # Faithfulness-Metrik (Issue #11 Phase 2): NLI-Sidecar bewertet jeden Claim
  # des generierten Resümees gegen das Quell-Transkript.
  # Payload: `%{session_id, campaign_id, score: 0.0..1.0,
  # claims: [%{text, span, label}], scored_at}`.
  # Wird von Worker.LLM.Faithfulness nach Stage 2 publiziert; graceful skip
  # wenn Sidecar nicht erreichbar (kein Event → score bleibt nil in der UI).
  def session_faithfulness_scored, do: "SessionFaithfulnessScored"

  # Issue #651 (Wahrheitsbild, Phase A): der EINE gegatete Generativschritt
  # extrahiert aus den Original-Utterances einer Session strukturierte Fakten
  # (quell-erhaltend, keine Prosa-Paraphrase). Resümee/Epos/Timeline rendern
  # später als Geschwister daraus, statt die Prosa der Vorstufe zu konsumieren.
  # Payload: `%{session_id, campaign_id, extracted_at,
  #   facts: [%{id, claim, entity_id, character_alias, in_game_date | nil,
  #             source_refs: [utterance_id], verified?}]}`.
  # `entity_id` = kanonische Identität über Gestalten/Sessions (alias→entity-
  # Registry, Phase B); `character_alias` = Oberflächenform; `verified?` wird
  # im Phase-B-Verify-Gate gesetzt (Flag, nicht Drop). Set-Semantik pro
  # session_id → Re-Extraktion überschreibt.
  def session_facts_extracted, do: "SessionFactsExtracted"

  # Issue #832 (Epic #829 Slice C): campaign-weite Handlungsbogen-Cluster-Map.
  # Die ThreadRegistry clustert die rohen `thread`-Labels (#831) aller Fakten
  # einer Kampagne zu kanonischen Strängen. Payload:
  # `%{campaign_id, cluster_map}` — cluster_map = `%{roh_label => canonical}`.
  # **Whole-Snapshot**: die Payload trägt IMMER die komplette Map (nie ein Delta)
  # → LWW-per-Kampagne konvergiert (Voll-Ersatz, kein Feld-Merge). Anders als
  # SessionFactsExtracted re-keyt das die Fakten NICHT — die Map lebt als eigenes
  # 1-Row-Artefakt (`worker_thread_registry`), der Reader wendet sie zur Lesezeit
  # an.
  def thread_registry_computed, do: "ThreadRegistryComputed"

  # Issue #836 (Epic #829 Slice D2): Member-Kuration eines Handlungsstrangs im
  # Offene-Fäden-Panel. Payload: `%{campaign_id, canonical, action, new_name?,
  # merge_into?, set_by}`. `action` ∈ `rename`|`merge`|`clear_identity` (Identitäts-
  # Dimension) | `resolve`|`dismiss`|`reactivate` (Lebenszyklus-Dimension). Beide
  # Dimensionen sind unabhängige Whole-Snapshot-LWW-Overlays (verschiedene Zeilen)
  # → „umbenennen UND auflösen" koexistiert, „resolve dann dismiss" ersetzt LWW.
  # Overlay am Read, KEIN Fakt-Rewrite (Muster SessionFactDateSet/Overrides).
  # Kuration ist Member-Recht (nicht GM-only) — kollaborative Recall-Pflege.
  def thread_override_set, do: "ThreadOverrideSet"

  # ─── Arcs (Epic #900 S2, Issue #903) ─────────────────────────────────
  # Der Arc ist das erstklassige Handlungsbogen-Objekt der Wahrheitsbasis.
  # Sein Status wird NIE geschrieben, sondern am Reader ABGELEITET (LWW über
  # die menschlichen Akte + Lesezeit-Max über Fakt-Sessions) — Modell in #900.

  # Maschinelle Arc-Geburt im resolve-Schritt (erbt elected?, best-effort):
  # für jeden arc-kind-Kanon-Strang ohne paarenden Arc. arc_id ist CONTENT-
  # adressiert über campaign_id + sortierte normalisierte Seed-Roh-Labels
  # (Cross-Campaign-disambiguiert — gleiche Labels in zwei Kampagnen sind
  # zwei Arcs). leitfrage_draft = :generiert-Klasse (deterministisch, kein
  # LLM in S2). LWW auf dem :arc_created-Fold; fasst act-/leitfrage-Felder
  # der Row NIE an (getrennte Fold-Gruppen).
  # Payload: %{arc_id, campaign_id, leitfrage_draft, seed_raw_labels}.
  def arc_created, do: "ArcCreated"

  # Menschlicher Schließ-Akt (Member-Recht :curate_threads). grund ∈
  # "geloest" (Leitfrage beantwortet — Erfolg ODER Misserfolg; nie Auto-
  # Reopen, Folge-Fakten sind Nachwirkung) | "versandet" (nie beantwortet,
  # bewusst aufgegeben; Reopen automatisch bei neuer Evidenz).
  # wasserlinie_session = höchste dem SCHREIBENDEN Hub-LV bekannte
  # Fakt-Session (max last_touched_session der campaign_threads) — ZUR
  # SCHREIBZEIT bestimmt, nie am Apply abgeleitet: Republish-Fakten tragen
  # frische event_ids, nur die Payload-Wasserlinie macht das versandet-
  # Reopen-Gate reorder-fest (#900-Divergenz-Gegenbeispiel). Konkurriert
  # mit ArcReopened um den GETEILTEN :arc_act-Fold (LWW-by-event_id).
  # Payload: %{arc_id, campaign_id, grund, wasserlinie_session, set_by}.
  def arc_closed, do: "ArcClosed"

  # Manueller Wieder-Öffnen-Akt (Korrekturpfad; deckt auch den bewussten
  # Reopen eines gelösten Bogens). Whole-Snapshot der :arc_act-Gruppe:
  # der Fold nil-t grund + wasserlinie explizit mit (kein Partial-Payload —
  # sonst Reorder-Divergenz). Payload: %{arc_id, campaign_id, set_by}.
  def arc_reopened, do: "ArcReopened"

  # Kuratierte Leitfrage (:kuratiert-Klasse, Gap-Fill-Template #865):
  # überstimmt den leitfrage_draft am Reader dauerhaft. LWW auf dem
  # :arc_leitfrage-Fold, nie delete (leerer Text = Undo → Draft gilt).
  # Payload: %{arc_id, campaign_id, text, set_by}.
  def leitfrage_set, do: "LeitfrageSet"

  # Issue #905 (Epic #900 S3): Arc-Zusammenführung als READ-ZEIT-REDIRECT
  # (Spiegel des Thread-Merge #836) — heilt Duplikat-Arcs aus Cross-Worker-
  # Seed-Drift. arc_id = QUELLE, merge_into = Ziel-arc_id; "" = Undo (reguläre
  # Row, nie delete). Persistiert als merged_into-Spalte der Quell-Row,
  # eigene Fold-Gruppe :arc_merge (LWW). Redirect-Invariante am READER:
  # wirksam gdw. Ziel-Row existiert UND Ziel selbst un-gemerged (Ein-Level —
  # Zyklen/Ketten degradieren zu wirkungslos-aber-sichtbar, nie zu
  # verstecktem Zustand). Self-Merge wird am Fold gedroppt.
  # Payload: %{arc_id, campaign_id, merge_into, set_by}.
  def arc_merge_set, do: "ArcMergeSet"

  # Issue #905 (Epic #900 S3): Fakt→Arc-Zuordnungs-Override — „die Maschine
  # entscheidet eindeutig, der Mensch entscheidet mehrdeutig" (Epic #900).
  # v1: EIN Override pro Fakt (set/clear); arc_id = Ziel-Arc, "" = Undo →
  # die Label-Kette gilt wieder. Add/Remove-MULTI-Zuordnung ist markierter
  # Erweiterungspunkt, nicht gebaut. fact_id ist die content-adressierte
  # Fakt-ID (#864) → re-key-immun per Konstruktion. Fold :fact_arc_set
  # (LWW-Row in worker_fact_arc_overrides, thread_overrides-Muster).
  # Override auf (noch) nicht-existenten Arc ist am Reader wirkungslos.
  # Payload: %{campaign_id, fact_id, arc_id, set_by}.
  def fact_arc_set, do: "FactArcSet"

  # Issue #915 (Epic #911, Cut 1): Falsifikations-Flag — der EINZIGE erlaubte
  # Spieler-Signal-Pfad („stimmt nicht", meldet, korrigiert nicht). Ein Member
  # flaggt ein Objekt, ein Kurator löst/verwirft. Ziel = rebuild-STABILER
  # Objekt-Anker (NICHT ein gerenderter Span): `target_kind ∈ {"session",
  # "arc", "fact"}`, `target_id ∈ {session_id, arc_id, fact-content-id (#864)}`.
  # Row-Key = `"<campaign_id>:<target_kind>:<target_id>"` (ein Flag pro Objekt).
  #
  # Die drei Events konkurrieren um DENSELBEN Status-Slot einer Flag-Row über
  # den GETEILTEN Fold `:flag_status` (LWW-by-event_id, exakt die :arc_act-
  # Präzedenz von ArcClosed+ArcReopened) — Re-Raise nach Resolve = legitimes
  # Wiederaufleben mit höherer event_id. Alle drei Payloads tragen
  # `%{campaign_id, target_kind, target_id, set_by}`, damit Resolve/Dismiss vor
  # dem Raise eine Stub-Row anlegen kann (order-insensitiv). Nie :mnesia.delete.
  #
  # FlagRaised zusätzlich: `note` (optionaler Kurz-Text, max Byte-Cap). Fakt-
  # Flags AUTO-RESOLVEN am Reader, wenn die fact-content-id nicht mehr existiert
  # (Read-Zeit-Berechnung wie `luecken`-`verwaist`, kein Write); session/arc-
  # Flags bleiben bis zum expliziten Schließen.
  # Payload FlagRaised: %{campaign_id, target_kind, target_id, note, set_by}.
  def flag_raised, do: "FlagRaised"

  # Issue #915: Kurator bestätigt das Flag als berechtigt + erledigt am Substrat.
  # Payload: %{campaign_id, target_kind, target_id, set_by}. Siehe flag_raised/0.
  def flag_resolved, do: "FlagResolved"

  # Issue #915: Kurator verwirft das Flag als unbegründet.
  # Payload: %{campaign_id, target_kind, target_id, set_by}. Siehe flag_raised/0.
  def flag_dismissed, do: "FlagDismissed"

  # Issue #863 (Epic #861 Slice B): geglättetes Transkript einer Session —
  # Stage-1.1-Output (deterministischer Sprecher-Merge + Dedup + Füllwort-Strip,
  # #862). Payload: `%{session_id, campaign_id, smoothed_at,
  #   blocks: [%{id, speaker_discord_id, text, quell_utterance_ids,
  #              asr_unsicher, hat_luecke, konfidenz}],
  #   ooc_verworfen: [utterance_id], rules_version, merge_gap_seconds}`.
  # Block-`id` ist CONTENT-adressiert (hash über sortierte quell_utterance_ids
  # + rules_version, #862/K1) — nicht positional. **Whole-Snapshot pro Session**
  # (immer die komplette Block-Liste, nie ein Delta) → LWW-per-Session
  # konvergiert (Voll-Ersatz, kein Merge; Muster SessionFactsExtracted).
  # rules_version + merge_gap_seconds reisen im Snapshot mit (selbst-erklärend,
  # auditierbar versionsgemischter Korpus — P2 in Epic #861).
  def transcript_smoothed, do: "TranscriptSmoothed"

  # Issue #865 (Epic #861 Slice D+E): Gemma-Füll-Vorschlag für einen Lücken-
  # Block (#862 `hat_luecke`) — SEPARATES, gepinntes :generiert-Artefakt (K2:
  # NICHT im TranscriptSmoothed-Payload, sonst wäre der Block-Rebuild nicht
  # deterministisch). Key = Block-CONTENT-ID. Payload: `%{session_id,
  # campaign_id, block_id, original, vorschlag, modell}`. LWW-by-event_id;
  # ein Rebuild ruft Gemma NICHT neu, solange die Block-ID existiert.
  # KEINE Dirty-Kante: das Eintreffen eines Vorschlags triggert NIE eine
  # Re-Extraktion (Fakten bleiben über die ANY-Klemme fail-closed geklemmt;
  # erst die menschliche Kuration triggert — festgenagelte Nicht-Kante).
  def luecken_vorschlag_generiert, do: "LueckenVorschlagGeneriert"

  # Issue #865 (Epic #861 Slice D+E): menschliche Kuration eines Lücken-Blocks
  # (:kuratiert-Layer, Zwei-Klassen-Welt). Payload: `%{session_id, campaign_id,
  # block_id (Content-ID), status, bestaetigter_text | nil,
  # quell_utterance_ids, set_by}`. status ∈ `bestaetigt` | `manuell_korrigiert`
  # | `original_bestaetigt` (Vorschlag falsch, Rohtext gilt — IST Kuration) |
  # `unbrauchbar` (nichts zu retten — Block fällt aus der Extraktions-
  # Oberfläche, F5). `bestaetigter_text` snapshottet den EXAKT bestätigten
  # Text (K3 — nie auf Text zeigen, den kein Mensch sah); `quell_utterance_ids`
  # sortiert-kanonisch gesnapshottet → Re-Attach nach Regelwechsel ist eine
  # reine Read-Zeit-Paarung (kein Migrationspfad). Member-Recht (E4), letzter
  # Schreiber sichtbar. Nie :mnesia.delete.
  def luecken_kuration_set, do: "LueckenKurationSet"

  # Issue #724 Slice F: GM-Korrektur eines einzelnen Fakts in der Review-Queue
  # (`Worker.Repo.campaign_review_facts/1` — verifizierte Fakten ohne auflösbares
  # Zeitstrahl-Datum). Payload: `%{session_id, campaign_id, fact_id,
  # extraction_event_id, in_game_date_raw, dismissed | nil, set_by}`.
  # `in_game_date_raw` (max 200 Bytes) trägt das GM-Datum; ein leerer String
  # setzt den Override auf leer zurück (Undo — KEIN Row-Delete, s. Fold-
  # Kommentar: reines Löschen wäre order-sensitiv und würde bei vertauschter
  # Sync-Reihenfolge divergieren). `dismissed: true` blendet den Fakt dauerhaft
  # aus der Queue UND aus jedem künftigen Zeitstrahl-Republish aus (nicht nur
  # aus der Review-Anzeige).
  #
  # `extraction_event_id` = das `event_id` der `SessionFactsExtracted`-Row, GEGEN
  # DIE der GM den Fakt gerade sieht (die Hub-UI liest es aus der
  # `campaign_review_facts`-Serialisierung und reicht es unverändert durch).
  # KRITISCH: Fakt-IDs sind rein positional (`"f#{i}"`, `Parsing.normalize_fact/4`)
  # — NICHT run-eindeutig. Ohne diesen Anker würde ein Override nach einem
  # Regenerate (neue Extraktion, gleiche Positions-IDs) still auf einen
  # VÖLLIG ANDEREN, neuen Fakt an derselben Position durchschlagen
  # (Cross-Contamination, nicht nur „Verwaisen"). Der Read-Merge
  # (`Worker.Repo.Artifacts.merge_override/3`) wendet den Override daher NUR
  # an, wenn `extraction_event_id` mit dem event_id der AKTUELL gespeicherten
  # `session_facts`-Row übereinstimmt — ein reiner Vergleich gegen konvergenten
  # State, bleibt also order-insensitiv (kein neuer #698-Bug).
  #
  # Fold ist ein reiner LWW-Upsert in einer eigenen Overlay-Tabelle
  # (`worker_session_fact_overrides`) — die Extraktions-Row (`SessionFactsExtracted`,
  # von `Verify.verify_session` re-publisht) bleibt unangetastet.
  def session_fact_date_set, do: "SessionFactDateSet"

  # Issue #916 (Epic #911, Cut 2): direkte L1-Kuration eines Fakts — je EIN Feld
  # (`claim | character | thread | verified | dismissed`) als LWW-Overlay-Event.
  # Overlay-only (kein In-Place-Edit): Fakt-IDs sind content-adressiert (#864,
  # `f_<hash(sorted_quell + claim)>`), ein Regenerate re-extrahiert. Anker daher
  # NICHT die Fakt-ID (der claim-Edit ändert sie), sondern die claim-UNabhängige
  # **Utterance-Menge** (`quell_utterance_ids` = ⋃ der Roh-Utterances der
  # source_refs-Blöcke). Der Read-Merge paart über die identische Menge auf die
  # neue Fakt-ID nach dem Rebuild (#866/#865-`by_quell`-Mechanik). `anchor_hash`
  # ist nur der Key-Kurzschlüssel; `quell_utterance_ids` reist kanonisch-sortiert
  # mit (Re-Attach + verwaist-Review). Undo = leerer `value` (reguläre Row, nie
  # delete — #698). Eine Row pro (Anker, Feld) → unabhängige LWW-Slots.
  # Payload: %{session_id, campaign_id, anchor_hash, quell_utterance_ids, field, value, set_by}.
  def fact_curation_set, do: "FactCurationSet"

  # Live-transcription wipe. Emitted by AudioBuffer.finalize when the
  # session ran in :live mode, before the batch re-pass. Materializer
  # deletes every utterance with the given session_id whose status == :live,
  # so Stages 2-4 see only the confirmed batch transcription.
  def live_utterances_cleared, do: "LiveUtterancesCleared"

  # User-display-name backfill. Emitted by LiveViews on mount when the
  # current viewer isn't yet in the workers' `users` table (e.g. owners
  # of campaigns created before the CampaignCreated handler was teaching
  # the owner upsert). Idempotent — Materializer preserves joined_at.
  def user_upserted, do: "UserUpserted"

  # Per-campaign character alias for a player. Payload:
  # `%{campaign_id, discord_id, character_name | nil}` — nil resets to
  # display_name fallback. Permission enforced at the LiveView (only the
  # acting user may set their own alias).
  def campaign_alias_set, do: "CampaignAliasSet"

  # Cascade-Delete einer Kampagne: löscht aus der materialisierten Worker-
  # Mnesia campaign, members, invites, sessions, utterances, markers, epos,
  # epos-history, session-summaries, chronik-entries. Owner-gated im LV mit
  # Namens-Bestätigung. Im Event-Log bleibt der Eintrag — beim Replay
  # cascade-löscht der Materializer erneut, Lifecycle bleibt deterministisch.
  # Payload: `%{campaign_id, deleted_by}`.
  def campaign_deleted, do: "CampaignDeleted"

  # Issue #294: Einzelne Session unwiderruflich löschen — analog zu
  # CampaignDeleted, aber auf eine session_id begrenzt. Materializer
  # cascade-löscht Utterances, Marker, Speaker-Zuordnungen, Resümee,
  # Faithfulness-Score, Chronik-Einträge dieser Session und die Session-Row.
  # Die Kampagne und ihre anderen Sessions bleiben unberührt.
  # Payload: `%{session_id, campaign_id, deleted_by}`.
  def session_deleted, do: "SessionDeleted"

  # Per-campaign LLM-Stilanweisung pro Slot. Wird in den Stage-2/3/4-Prompts
  # als Preamble injiziert (Base + slot-spezifischer Voice kombiniert).
  # Payload: `%{campaign_id, slot, flavor | nil, edited_by}` mit
  # `slot ∈ "base" | "summary" | "epos" | "chronik"`.
  # Backward-Compat: alte Events ohne `slot` werden als `slot="base"`
  # interpretiert. `flavor=nil|""` löscht den Slot aus der Map.
  # Member-gated im LV.
  def campaign_flavor_set, do: "CampaignFlavorSet"

  # Issue #313: Ausgabe-Vorgabe pro Campaign × Stage — der Name wird die
  # Verlaufs-Überschrift (genre-passend: "Epos" / "Polizeiakte" / "Logbuch"),
  # die Darstellungsform schaltet den Stage-3-Prompt-Branch (Fließtext vs.
  # Stichpunkte). Payload: `%{campaign_id, stage, name | nil, darstellungsform
  # | nil, set_by}` mit `stage ∈ "summary" | "epos" | "chronik"`. name=nil ⇒
  # zurück auf Default-Name. Der Ton bleibt bei CampaignFlavorSet — eine
  # "Vorgabe wählen"-Aktion im LV feuert beide. Member-gated.
  def campaign_vorgabe_set, do: "CampaignVorgabeSet"

  # Issue #724: per-Campaign-Kalender-Definition für den Zeitstrahl. Payload:
  # `%{campaign_id, calendar: %{"months" => [%{"name","days"}], "epoch_label"},
  # set_by}`. Der Worker validiert/normalisiert via `Worker.Timeline.Calendar`
  # (kaputte Struktur → Default) und speichert kanonisches JSON in
  # @campaign_calendars. Member-gated im LV.
  def campaign_calendar_set, do: "CampaignCalendarSet"

  # Issue #724: In-Game-Datum-Anker einer Session (Bezugspunkt für relative
  # Fakt-Offsets). Payload: `%{session_id, campaign_id, in_game_date_raw, set_by}`.
  # Der Worker löst den Roh-String deterministisch gegen den Campaign-Kalender
  # auf (`Calendar.parse → to_day`) und schreibt Tageszähler + Roh-String in
  # @session_anchors; leerer Roh-String ⇒ Anker löschen. Member-gated im LV.
  def session_in_game_anchor_set, do: "SessionInGameAnchorSet"

  # Globale Rolle eines Users setzen (Issue #34, Userverwaltung).
  # Payload: `%{discord_id, role, set_by}` mit role ∈ "admin" | "spielleiter"
  # | "spieler". Beim Pairing-Flow wird der erste User pro Instance
  # automatisch zu :admin. Spätere Änderungen via /admin/users-UI (#35).
  def user_role_set, do: "UserRoleSet"

  # Admin fügt einen User direkt einer Campaign hinzu, ohne den
  # invite-link-flow (Issue #35). Payload: `%{campaign_id, discord_id,
  # added_by, display_name | nil}`. Materializer legt member-row an + upsert
  # user-record. Nur Admins dürfen das im LV triggern; Permission-Gate
  # liegt am AdminUsersLive.
  def admin_member_added, do: "AdminMemberAdded"

  # LLM-Probelauf (Issue #74): Smoke-Test der Pipeline auf einer dedizierten
  # Probelauf-Kampagne, misst pro Stage Wall-Clock + Erfolg/Fehler-Kategorie,
  # liefert Heuristik-Empfehlung für model_stage{n}.
  # Started-Payload: `%{run_id, started_by, started_at, settings_snapshot}`.
  # Finished-Payload: `%{run_id, finished_at, sessions: [%{n, utterance_count,
  # stages: %{stage2: %{duration_ms, outcome, output_bytes}, ...}}],
  # settings_snapshot}`. Materializer schreibt in `worker_probelauf_runs`.
  #
  # ProbelaufFinished kann optional `sweep_id` und `sweep_variant` tragen
  # (Phase 2, Issue #88): Wenn der Run Teil eines Sweeps ist, taggt das
  # Payload mit der gemeinsamen sweep_id + dem variierten Setting
  # (`%{stage: 3, model: "qwen2.5:7b"}`).
  def probelauf_started, do: "ProbelaufStarted"
  def probelauf_finished, do: "ProbelaufFinished"

  # Audio-Aufnahme-Consent (Issue #64). Wenn ein User das erste Mal die
  # Mikro/Listen-Aufnahme aktiviert, blendet die CampaignLive ein Modal ein,
  # das aufklärt was mit den Audio-Daten passiert. Nach Akzeptanz emittiert
  # der LV diesen Event, der Worker persistiert die Zustimmung pro
  # discord_id. Nachfolgende mic_join-Klicks überspringen das Modal.
  # Payload: `%{discord_id, version, accepted_at}` — `version` ("v1") taggt
  # das Wording-Set damit spätere Policy-Änderungen erneut zur Bestätigung
  # zwingen können.
  def audio_consent_recorded, do: "AudioConsentRecorded"

  # LLM-Probelauf-Sweep (Issue #88, Phase 2): mehrere ProbelaufFinished-
  # Runs unter einem gemeinsamen `sweep_id`. Sub-Stage-Variation —
  # pro Run wird genau eine Stage durch ein anderes Modell ersetzt,
  # die übrigen Stages bleiben auf dem Default.
  # SweepStarted-Payload: `%{sweep_id, stage, models, started_by, started_at,
  # default_model}` (default_model = das Modell, das vor dem Sweep für die
  # variierte Stage gesetzt war — wird am Ende wiederhergestellt).
  # SweepFinished-Payload: `%{sweep_id, finished_at}`. Beide Marker landen
  # in `worker_probelauf_sweeps`.
  def probelauf_sweep_started, do: "ProbelaufSweepStarted"
  def probelauf_sweep_finished, do: "ProbelaufSweepFinished"

  # Issue #177: Spend-Tracking für Cloud-LLM-Calls. Wird vom Worker nach
  # jedem erfolgreichen Anthropic/OpenAI/Google-Call publisht. Payload:
  #   %{
  #     provider: "anthropic" | "openai" | "google",
  #     model: "claude-sonnet-4-6" | …,
  #     input_tokens: integer,
  #     output_tokens: integer,
  #     cost_usd: float,
  #     requested_by_discord_id: binary | nil,
  #     session_id: binary | nil,
  #     stage: "stage2" | "stage3" | "stage4" | "probelauf" | …,
  #     duration_ms: integer
  #   }
  # Materializer schreibt nach `worker_llm_spend` für /admin/spend-Dashboard.
  def llm_call_billed, do: "LLMCallBilled"

  # Issue #178: Per-User-Spend-Cap (USD/Monat). Admin setzt via /admin/users
  # einen Cap; Worker.LLM.complete/3 checkt vor jedem Cloud-Call das
  # aktuelle Monats-Spend gegen den Cap und failt mit
  # :spend_cap_exceeded bei Überschreitung. Permission: nur :admin.
  # Payload:
  #   %{
  #     discord_id: binary,
  #     cap_usd: float | nil,      # nil = unbegrenzt
  #     changed_by: binary
  #   }
  # Materializer aktualisiert das `monthly_spend_cap_usd`-Field auf
  # `worker_users`.
  def user_spend_cap_changed, do: "UserSpendCapChanged"

  # Issue #355 Bug-Fix: SessionEnded firet SOFORT wenn der User die
  # Aufnahme stoppt — nicht erst nach der Transcribe-Stage. Damit Stage
  # 2-4 (Pipeline) weiterhin nach Transkription anlaufen, triggert die
  # Pipeline jetzt auf `UtterancesTranscribed` (vorher: SessionEnded).
  # Worker.Recording.Transcribe.run/2 + run_single_source/2 publishen
  # dieses Event am Ende. Payload: %{session_id, campaign_id, utterance_count}.
  def utterances_transcribed, do: "UtterancesTranscribed"

  # Issue #68 (Phase 1): strukturiertes Pipeline-Fehler-Log für Self-
  # Hosted-Spielleiter. Worker.Recording.Pipeline publisht den Event jedes
  # Mal, wenn `run_stages/3` mit `{:error, reason}` abbricht — Materializer
  # schreibt in worker_pipeline_errors. Payload-Shape:
  #   %{
  #     error_id: binary (UUIDv7 — zeit-geordnet),
  #     session_id: binary | nil,
  #     campaign_id: binary | nil,
  #     stage: "stage2" | "stage3" | "stage4" | nil,
  #     error_type: "empty_chronik" | "no_key_configured" | "network_error" | "upstream_auth" | … (snake_case),
  #     message: binary (kurze Beschreibung, Logger-Style),
  #     context: map (frei strukturiert: model, reason, attempt, …),
  #     occurred_at: ISO-8601-Timestamp
  #   }
  # /admin/errors-LV liest via Worker.Repo.last_n_pipeline_errors/1.
  def pipeline_error_logged, do: "PipelineErrorLogged"

  # Issue #57: User komplett von der Instance entfernen. Cascade im
  # Materializer: alle campaign_members-Rows + worker_users-Row löschen.
  # Utterances/Sessions/Markers bleiben erhalten (Audit-Trail), UI rendert
  # dangling-discord_ids als "[gelöschter User]"-Pill.
  # Pre-Delete-Checks (Hub-seitig, vor Event-Append):
  #   1. Caller ist :admin AND not-self
  #   2. Target ist nicht der letzte :admin (Lockout-Schutz)
  #   3. Last-SL-Kampagnen müssen vorher per MemberRolePromoted / CampaignArchived
  #      "resolved" werden — Hub.Commands.request_user_delete/3 returnt
  #      {:error, :unresolved_last_spielleiter, [campaign_ids]} sonst.
  # Payload:
  #   %{
  #     discord_id: binary,
  #     deleted_by: binary
  #   }
  def user_deleted, do: "UserDeleted"

  # Issue #57: Kampagne archivieren (Status -> :archived). Kommt aus dem
  # User-Delete-Flow, wenn ein User letzter Spielleiter ist und der Admin
  # "Kampagne archivieren" statt "Spieler promoten" wählt. Archivierte
  # Kampagnen werden vom Dashboard standardmäßig ausgeblendet (Toggle
  # "Archivierte zeigen" — LocalStorage-persistiert).
  # Payload:
  #   %{
  #     campaign_id: binary,
  #     archived_by: binary,
  #     reason: binary  # "owner_deleted" | "manual" | ...
  #   }
  def campaign_archived, do: "CampaignArchived"

  @doc """
  Issue #471: kanonische Liste **aller** Event-Kind-Strings. Wartungsfrei via
  Introspektion abgeleitet — jede 0-arige Funktion dieses Moduls (außer `all/0`
  selbst), die einen PascalCase-String liefert, ist ein Kind. So kann `all/0`
  nicht von den Einzelfunktionen wegdriften.

  Genutzt vom Materializer-Catch-all (unbekannter Kind ∉ all/0 → Warning statt
  stiller Ignoranz) und vom Drift-Guard-Test (jede `apply_kind`-Klausel muss
  einen Kind aus dieser Liste matchen).
  """
  @spec all() :: [String.t()]
  def all do
    __MODULE__.__info__(:functions)
    |> Enum.filter(fn {name, arity} -> arity == 0 and name != :all end)
    |> Enum.map(fn {name, _} -> apply(__MODULE__, name, []) end)
    |> Enum.filter(&(is_binary(&1) and &1 =~ ~r/^[A-Z][A-Za-z0-9]+$/))
    |> Enum.uniq()
    |> Enum.sort()
  end
end
