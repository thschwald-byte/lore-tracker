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

  # Pipeline orchestration. Payload carries a `scope` ("session_pipeline"
  # today; future kinds e.g. "epos_only") and a target id. No state change
  # in Mnesia — the Materializer no-ops; consumer is Worker.Recording.Pipeline.
  def regenerate_requested, do: "RegenerateRequested"

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
  def probelauf_started, do: "ProbelaufStarted"
  def probelauf_finished, do: "ProbelaufFinished"
end
