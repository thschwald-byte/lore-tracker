defmodule HubWeb.CampaignLive.UpdatesScopeTest do
  @moduledoc """
  Issue #442 Stage 2: Tier-2 scoped Reloads. apply_scope/3 merged nur den
  betroffenen Bereich + baut die Sync-/Refs-Indizes neu (summaries/chronik/epos),
  fasst sie bei campaign_meta NICHT an. Bare-Socket-Transforms (kein Worker).
  """
  use ExUnit.Case, async: true

  alias HubWeb.CampaignLive.{Refs, Updates}

  # Repräsentative String-keyed Daten (Snapshot-Konvention).
  defp summaries, do: [%{"session_id" => "s1", "content_md" => "alt", "source_refs" => ["u1"]}]
  defp chronik, do: [%{"id" => "c1", "label" => "Tag 1", "source_refs" => ["u2"]}]
  defp epos, do: %{"id" => "e1", "content_md" => "Epos", "source_refs" => ["u3"]}

  defp utterances,
    do: [%{"id" => "u1", "session_id" => "s1"}, %{"id" => "u2", "session_id" => "s1"}]

  defp socket do
    %Phoenix.LiveView.Socket{
      assigns:
        %{
          campaign: %{"id" => "camp-1", "name" => "Alt"},
          current_campaign: %{"id" => "camp-1", "name" => "Alt"},
          summaries: summaries(),
          chronik: chronik(),
          epos: epos(),
          epos_history: [],
          utterances: utterances(),
          utterance_refs_index: %{},
          sync_index_json: "{}"
        }
        |> Map.put(:__changed__, %{})
    }
  end

  describe "scope_for_event/1" do
    test "mappt Tier-2-Events auf ihren Scope" do
      assert Updates.scope_for_event("SessionSummaryEdited") == "campaign_summaries"
      assert Updates.scope_for_event("SessionSummaryGenerated") == "campaign_summaries"
      assert Updates.scope_for_event("ChronikEntryChanged") == "campaign_chronik"
      assert Updates.scope_for_event("EposEntryEdited") == "campaign_epos"
      assert Updates.scope_for_event("CampaignFlavorSet") == "campaign_meta"
      assert Updates.scope_for_event("CampaignVorgabeSet") == "campaign_meta"
      assert Updates.scope_for_event("CampaignVocabUpdated") == "campaign_meta"
      # Issue #442 Final Cut: CampaignUpdated → derselbe campaign_meta-Scope.
      assert Updates.scope_for_event("CampaignUpdated") == "campaign_meta"
      # Issue #442: Member-ADD / globale User-Events.
      assert Updates.scope_for_event("InviteRedeemed") == "campaign_members"
      assert Updates.scope_for_event("AdminMemberAdded") == "campaign_members"
      assert Updates.scope_for_event("UserUpserted") == "campaign_members"
      assert Updates.scope_for_event("UserRoleSet") == "campaign_members"
    end

    test "#865/#871: Lücken-Events → campaign_luecken (ein Scope für Panel + Block-Spalte)" do
      assert Updates.scope_for_event("TranscriptSmoothed") == "campaign_luecken"
      assert Updates.scope_for_event("LueckenVorschlagGeneriert") == "campaign_luecken"
      assert Updates.scope_for_event("LueckenKurationSet") == "campaign_luecken"
    end

    test "nil für nicht-scoped Events (payload-exakte Tier-1 + Unbekannte)" do
      # MemberRolePromoted/InviteCreated/SessionScheduled laufen in-place, nicht scoped.
      assert Updates.scope_for_event("MemberRolePromoted") == nil
      assert Updates.scope_for_event("InviteCreated") == nil
      assert Updates.scope_for_event("SessionScheduled") == nil
    end
  end

  describe "apply_scope/3 — campaign_summaries" do
    test "ersetzt summaries, lässt chronik/epos/campaign unberührt" do
      new_sums = [%{"session_id" => "s1", "content_md" => "neu", "source_refs" => ["u1", "u2"]}]

      s =
        Updates.apply_scope(socket(), "campaign_summaries", %{
          "summaries" => new_sums
        })

      assert s.assigns.summaries == new_sums
      # Andere Dimensionen unberührt.
      assert s.assigns.chronik == chronik()
      assert s.assigns.epos == epos()
      assert s.assigns.campaign == %{"id" => "camp-1", "name" => "Alt"}
    end

    test "baut den Sync-Index byte-identisch zu Refs neu (kritische Invariante)" do
      new_sums = [%{"session_id" => "s1", "content_md" => "neu", "source_refs" => ["u1", "u2"]}]

      s =
        Updates.apply_scope(socket(), "campaign_summaries", %{
          "summaries" => new_sums
        })

      expected = Jason.encode!(Refs.build_sync_index(new_sums, epos(), chronik(), utterances()))
      assert s.assigns.sync_index_json == expected

      expected_refs = Refs.build_utterance_refs_index(new_sums, epos(), chronik())
      assert s.assigns.utterance_refs_index == expected_refs
    end
  end

  describe "apply_scope/3 — campaign_chronik / campaign_epos" do
    test "chronik ersetzt + Index rebuilt" do
      new_chr = [%{"id" => "c1", "label" => "Tag 2", "source_refs" => ["u1"]}]
      s = Updates.apply_scope(socket(), "campaign_chronik", %{"chronik" => new_chr})

      assert s.assigns.chronik == new_chr
      assert s.assigns.summaries == summaries()

      expected = Jason.encode!(Refs.build_sync_index(summaries(), epos(), new_chr, utterances()))
      assert s.assigns.sync_index_json == expected
    end

    test "epos + epos_history ersetzt + Index rebuilt" do
      new_epos = %{"id" => "e1", "content_md" => "Neu", "source_refs" => ["u2"]}
      hist = [%{"seq" => 1}]

      s =
        Updates.apply_scope(socket(), "campaign_epos", %{
          "epos" => new_epos,
          "epos_history" => hist
        })

      assert s.assigns.epos == new_epos
      assert s.assigns.epos_history == hist

      expected =
        Jason.encode!(Refs.build_sync_index(summaries(), new_epos, chronik(), utterances()))

      assert s.assigns.sync_index_json == expected
    end
  end

  describe "apply_scope/3 — campaign_luecken (#865 + #871)" do
    test "ersetzt smoothed (Kuration lebt inline in der Block-Spalte)" do
      smoothed = [%{"session_id" => "s1", "blocks" => [%{"block_id" => "b_1"}]}]

      base = socket()
      base = %{base | assigns: Map.merge(base.assigns, %{smoothed: []})}

      s = Updates.apply_scope(base, "campaign_luecken", %{"smoothed" => smoothed})

      assert s.assigns.smoothed == smoothed
      # Andere Dimensionen unberührt.
      assert s.assigns.summaries == summaries()
    end
  end

  describe "apply_scope/3 — campaign_meta" do
    test "ersetzt campaign, fasst den Sync-Index NICHT an" do
      before = socket()
      new_camp = %{"id" => "camp-1", "name" => "Neu", "flavor" => "düster"}

      s = Updates.apply_scope(before, "campaign_meta", %{"campaign" => new_camp})

      assert s.assigns.campaign == new_camp
      assert s.assigns.current_campaign == new_camp
      # Index unverändert (Meta speist ihn nicht).
      assert s.assigns.sync_index_json == before.assigns.sync_index_json
      assert s.assigns.summaries == summaries()
    end
  end
end
