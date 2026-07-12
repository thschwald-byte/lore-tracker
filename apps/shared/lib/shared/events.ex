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
  """

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

  # Issue #724 Slice F: GM-Korrektur eines einzelnen Fakts in der Review-Queue
  # (`Worker.Repo.campaign_review_facts/1` — verifizierte Fakten ohne auflösbares
  # Zeitstrahl-Datum). Payload: `%{session_id, campaign_id, fact_id,
  # in_game_date_raw, dismissed | nil, set_by}`. `in_game_date_raw` (max 200
  # Bytes) trägt das GM-Datum; ein leerer String setzt den Override auf leer
  # zurück (Undo — KEIN Row-Delete, s. Fold-Kommentar: reines Löschen wäre
  # order-sensitiv und würde bei vertauschter Sync-Reihenfolge divergieren).
  # `dismissed: true` blendet den Fakt dauerhaft aus der Queue UND aus jedem
  # künftigen Zeitstrahl-Republish aus (nicht nur aus der Review-Anzeige).
  # Fold ist ein reiner LWW-Upsert in einer eigenen Overlay-Tabelle
  # (`worker_session_fact_overrides`) — die Extraktions-Row (`SessionFactsExtracted`,
  # von `Verify.verify_session` re-publisht) bleibt unangetastet.
  def session_fact_date_set, do: "SessionFactDateSet"

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
