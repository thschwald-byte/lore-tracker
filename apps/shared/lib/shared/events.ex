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
end
