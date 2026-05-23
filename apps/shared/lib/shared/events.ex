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
  def marker_added, do: "MarkerAdded"

  # Epos
  def epos_entry_edited, do: "EposEntryEdited"

  # Summary / Chronik (Stages 2 + 4 of the LLM pipeline; also manually editable)
  def session_summary_generated, do: "SessionSummaryGenerated"
  def session_summary_edited, do: "SessionSummaryEdited"
  def chronik_entry_changed, do: "ChronikEntryChanged"

  # Faithfulness-Metrik (Issue #11 Phase 2): NLI-Sidecar bewertet jeden Claim
  # des generierten Resümees gegen das Quell-Transkript.
  # Payload: `%{session_id, campaign_id, score: 0.0..1.0,
  # claims: [%{text, span, label}], scored_at}`.
  # Wird von Worker.LLM.Faithfulness nach Stage 2 publiziert; graceful skip
  # wenn Sidecar nicht erreichbar (kein Event → score bleibt nil in der UI).
  def session_faithfulness_scored, do: "SessionFaithfulnessScored"

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

  # Per-campaign LLM-Stilanweisung pro Slot. Wird in den Stage-2/3/4-Prompts
  # als Preamble injiziert (Base + slot-spezifischer Voice kombiniert).
  # Payload: `%{campaign_id, slot, flavor | nil, edited_by}` mit
  # `slot ∈ "base" | "summary" | "epos" | "chronik"`.
  # Backward-Compat: alte Events ohne `slot` werden als `slot="base"`
  # interpretiert. `flavor=nil|""` löscht den Slot aus der Map.
  # Member-gated im LV.
  def campaign_flavor_set, do: "CampaignFlavorSet"

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
end
