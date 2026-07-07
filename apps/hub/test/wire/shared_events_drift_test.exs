defmodule HubWeb.Wire.SharedEventsDriftTest do
  @moduledoc """
  Issue #608: Drift-Guard für die Wire-Konstanten. `Shared.Events` definiert die
  Event-Kind-Strings, die Hub UND Worker im Pattern-Match nutzen. Ändert sich ein
  String unbemerkt, brechen beide Seiten gleichzeitig (silent Wire-Drift).

  Bewusst in der **Hub-Suite** platziert (nicht in apps/shared): die CI fährt nur
  `mix cmd --app hub mix test` — hier läuft der Drift-Guard also im Merge-Gate.
  Hub hängt via `{:shared, in_umbrella: true}` ohnehin von `Shared.Events` ab.
  """
  use ExUnit.Case, async: true

  alias Shared.Events

  # Golden-List: die vollständige kanonische Menge der Wire-Kinds (sortiert, wie
  # all/0 sie liefert). Ein Add/Remove/Rename bricht diesen Test → bewusste
  # Aktualisierung erzwungen, kein stiller Drift.
  @canonical ~w(
    AdminMemberAdded
    AudioConsentRecorded
    CampaignAliasSet
    CampaignArchived
    CampaignCalendarSet
    CampaignCreated
    CampaignDeleted
    CampaignFlavorSet
    CampaignTranscriptSourceUpdated
    CampaignUpdated
    CampaignVocabUpdated
    CampaignVorgabeSet
    ChronikClearedForSession
    ChronikEntryChanged
    EposEntryEdited
    InviteCreated
    InviteRedeemed
    InviteRevoked
    LLMCallBilled
    LiveUtterancesCleared
    MarkerAdded
    MemberRemoved
    MemberRolePromoted
    PipelineErrorLogged
    ProbelaufFinished
    ProbelaufStarted
    ProbelaufSweepFinished
    ProbelaufSweepStarted
    RecordingStateChanged
    SessionDeleted
    SessionEnded
    SessionFactsExtracted
    SessionFaithfulnessScored
    SessionInGameAnchorSet
    SessionScheduled
    SessionStarted
    SessionSummaryEdited
    SessionSummaryGenerated
    SpeakerAssigned
    UserDeleted
    UserRoleSet
    UserSpendCapChanged
    UserUpserted
    UtteranceAppended
    UtteranceDeleted
    UtteranceEdited
    UtterancesTranscribed
  )

  describe "all/0 — kanonische Wire-Kind-Liste" do
    test "liefert exakt die eingefrorene Golden-List" do
      assert Events.all() == @canonical
    end

    test "ist sortiert, eindeutig und nicht-leer" do
      kinds = Events.all()
      assert kinds == Enum.sort(kinds)
      assert kinds == Enum.uniq(kinds)
      assert kinds != []
    end

    test "alle Kinds sind nicht-leere PascalCase-Strings (Wire-Format)" do
      Enum.each(Events.all(), fn kind ->
        assert is_binary(kind)
        assert kind =~ ~r/^[A-Z][A-Za-z0-9]*$/
      end)
    end

    test "all/0 enthält keine :all-Selbstreferenz" do
      refute "All" in Events.all()
      refute "all" in Events.all()
    end

    test "ist konsistent mit den 0-stelligen Konstanten-Funktionen des Moduls" do
      # all/0 ist via Introspektion abgeleitet — gegencheck gegen die tatsächlich
      # exportierten 0-arity-Funktionen, die einen PascalCase-String liefern.
      from_functions =
        Events.__info__(:functions)
        |> Enum.filter(fn {name, arity} -> arity == 0 and name != :all end)
        |> Enum.map(fn {name, 0} -> apply(Events, name, []) end)
        |> Enum.filter(&(is_binary(&1) and &1 =~ ~r/^[A-Z]/))
        |> Enum.sort()
        |> Enum.uniq()

      assert Events.all() == from_functions
    end
  end

  describe "kritische Wire-Strings (cross-app Pattern-Match-Heads)" do
    test "Member-/Permission-Events" do
      assert Events.member_role_promoted() == "MemberRolePromoted"
      assert Events.member_removed() == "MemberRemoved"
      assert Events.campaign_alias_set() == "CampaignAliasSet"
      assert Events.speaker_assigned() == "SpeakerAssigned"
      assert Events.admin_member_added() == "AdminMemberAdded"
    end

    test "Session-/Recording-Events" do
      assert Events.session_started() == "SessionStarted"
      assert Events.session_ended() == "SessionEnded"
      assert Events.recording_state_changed() == "RecordingStateChanged"
      assert Events.utterance_appended() == "UtteranceAppended"
      assert Events.live_utterances_cleared() == "LiveUtterancesCleared"
    end

    test "LLM-Stage-Output-Events" do
      assert Events.session_summary_generated() == "SessionSummaryGenerated"
      assert Events.epos_entry_edited() == "EposEntryEdited"
      assert Events.chronik_entry_changed() == "ChronikEntryChanged"
    end
  end
end
