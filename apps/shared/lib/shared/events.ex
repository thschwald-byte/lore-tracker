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

  # (More kinds land in M8: chronik, llm regenerate, ...)
end
