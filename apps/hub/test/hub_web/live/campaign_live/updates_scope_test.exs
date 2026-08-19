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

  # Issue #1095: Fakten ankern auf `quell_utterance_ids` (Utterance-IDs, nicht
  # Block-IDs) — sie brauchen im Sync-Index deshalb kein `expand_refs`.
  defp facts,
    do: [
      %{"id" => "f_aaa", "session_id" => "s1", "quell_utterance_ids" => ["u1"]},
      %{"id" => "f_bbb", "session_id" => "s1", "quell_utterance_ids" => ["u1", "u2"]}
    ]

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

  describe "apply_scope/3 — campaign_facts (#1095)" do
    test "Fakten landen im Sync-Index — beide Richtungen" do
      s = Updates.apply_scope(socket(), "campaign_facts", %{"facts" => facts()})

      idx = Jason.decode!(s.assigns.sync_index_json)

      # Vorwärts: Fakt → seine Quell-Utterances.
      assert idx["entries_to_utts"]["fakten:f_aaa"] == ["u1"]
      assert idx["entries_to_utts"]["fakten:f_bbb"] == ["u1", "u2"]

      # Rückwärts: Utterance → alle Einträge, die sie zitieren. Ohne diese
      # Richtung könnte das Protokoll die Fakten-Spalte nicht mitziehen.
      cols_for_u1 = idx["utts_to_entries"]["u1"] |> Enum.map(& &1["col"])
      assert "fakten" in cols_for_u1
    end

    test "der Index wird überhaupt neu gebaut (der eigentliche Fehler)" do
      # Vorher fehlte hier das `rebuild_refs()`. Die Fakten kommen über einen
      # lazy geladenen Scope, NICHT im Haupt-Snapshot — ohne Rebuild wäre der
      # Index dauerhaft faktenlos.
      before = socket().assigns.sync_index_json
      s = Updates.apply_scope(socket(), "campaign_facts", %{"facts" => facts()})

      refute s.assigns.sync_index_json == before
      assert s.assigns.facts == facts()
    end

    test "byte-identisch zu Refs.build_sync_index/6" do
      s = Updates.apply_scope(socket(), "campaign_facts", %{"facts" => facts()})

      expected =
        Jason.encode!(
          Refs.build_sync_index(summaries(), epos(), chronik(), utterances(), [], facts())
        )

      assert s.assigns.sync_index_json == expected
    end

    test "Fakten ohne quell_utterance_ids fallen raus (kein leerer Anker)" do
      ohne = [%{"id" => "f_leer", "session_id" => "s1", "quell_utterance_ids" => []}]
      s = Updates.apply_scope(socket(), "campaign_facts", %{"facts" => ohne})

      idx = Jason.decode!(s.assigns.sync_index_json)
      refute Map.has_key?(idx["entries_to_utts"], "fakten:f_leer")
    end

    test "ausgeblendete Fakten bleiben im Index" do
      # Sie sind in der Spalte sichtbar (durchgestrichen, für den Un-Dismiss).
      # Ein stummer Eintrag in einer sonst mitlaufenden Spalte verwirrt mehr
      # als einer, der mitzieht.
      dismissed = [
        %{
          "id" => "f_weg",
          "session_id" => "s1",
          "quell_utterance_ids" => ["u2"],
          "curation_dismissed" => true
        }
      ]

      s = Updates.apply_scope(socket(), "campaign_facts", %{"facts" => dismissed})

      idx = Jason.decode!(s.assigns.sync_index_json)
      assert idx["entries_to_utts"]["fakten:f_weg"] == ["u2"]
    end

    test "leere Fakten-Liste lässt die übrigen Spalten unberührt" do
      s = Updates.apply_scope(socket(), "campaign_facts", %{"facts" => []})
      idx = Jason.decode!(s.assigns.sync_index_json)

      assert Map.has_key?(idx["entries_to_utts"], "summaries:s1")
      assert Map.has_key?(idx["entries_to_utts"], "chronik:c1")
    end
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

    # Issue #985 Slice 1: eigener schmaler Scope statt campaign_meta — dessen
    # Snapshot liefert nur die worker_campaigns-Row, kein discord_config-Key.
    test "CampaignDiscordConfigSet -> campaign_discord_config (eigener Scope, NICHT campaign_meta)" do
      assert Updates.scope_for_event("CampaignDiscordConfigSet") == "campaign_discord_config"
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

  describe "apply_scope/3 — campaign_discord_config (Issue #985 Slice 1)" do
    test "ersetzt discord_config, fasst Sync-Index/andere Assigns NICHT an" do
      before = %{socket() | assigns: Map.put(socket().assigns, :discord_config, %{})}
      new_cfg = %{"guild_id" => "111", "voice_channel_id" => "222"}

      s = Updates.apply_scope(before, "campaign_discord_config", %{"discord_config" => new_cfg})

      assert s.assigns.discord_config == new_cfg
      assert s.assigns.sync_index_json == before.assigns.sync_index_json
      assert s.assigns.summaries == summaries()
    end

    test "fehlender discord_config-Key im Snapshot -> leere Map statt Crash" do
      before = %{socket() | assigns: Map.put(socket().assigns, :discord_config, %{"x" => "y"})}
      s = Updates.apply_scope(before, "campaign_discord_config", %{})
      assert s.assigns.discord_config == %{}
    end
  end
end
