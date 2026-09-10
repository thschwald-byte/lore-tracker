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
          utterance_refs_index: %{}
        }
        |> Map.put(:__changed__, %{}),
      # Issue #1187: `push_event` legt in `private.live_temp` ab — ein Socket aus
      # `mount`/`handle_*` hat das immer, ein nackter Test-Socket nicht.
      private: %{live_temp: %{}}
    }
  end

  # Issue #1187: der Sync-Index reist als Ereignis, nicht mehr als Assign.
  # Die EINE Stelle im Test, die LiveViews interne Ablage kennt — bricht sie,
  # bricht sie hier und nicht in 13 Asserts.
  defp gepushter_index(socket) do
    socket.private.live_temp
    |> Map.get(:push_events, [])
    |> Enum.find_value(fn
      ["sync_index", %{index: index}] -> index
      _ -> nil
    end)
  end

  defp gepushter_index_json(socket), do: socket |> gepushter_index() |> Jason.encode!()

  describe "apply_scope/3 — campaign_facts (#1095)" do
    test "Fakten landen im Sync-Index — beide Richtungen" do
      s = Updates.apply_scope(socket(), "campaign_facts", %{"facts" => facts()})

      idx = s |> gepushter_index_json() |> Jason.decode!()

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
      assert gepushter_index(socket()) == nil
      s = Updates.apply_scope(socket(), "campaign_facts", %{"facts" => facts()})

      assert is_map(gepushter_index(s))
      assert s.assigns.facts == facts()
    end

    test "byte-identisch zu Refs.build_sync_index/6" do
      s = Updates.apply_scope(socket(), "campaign_facts", %{"facts" => facts()})

      expected =
        Jason.encode!(
          Refs.build_sync_index(summaries(), epos(), chronik(), utterances(), [], facts())
        )

      assert gepushter_index_json(s) == expected
    end

    test "Fakten ohne quell_utterance_ids fallen raus (kein leerer Anker)" do
      ohne = [%{"id" => "f_leer", "session_id" => "s1", "quell_utterance_ids" => []}]
      s = Updates.apply_scope(socket(), "campaign_facts", %{"facts" => ohne})

      idx = s |> gepushter_index_json() |> Jason.decode!()
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

      idx = s |> gepushter_index_json() |> Jason.decode!()
      assert idx["entries_to_utts"]["fakten:f_weg"] == ["u2"]
    end

    # Bis #1198 standen hier zwei Tests für `utt_sessions` (Utterance → Session,
    # für Zeilen außerhalb des Ladefensters). Die Karte ist weg: sie kam zum
    # größten Teil aus dem Block-Skelett, und der Hook brauchte sie nur als
    # Sperre in `tryAutoExpand` — die Session findet `focus_utterance/3` selbst
    # (`source_refs_resolution_test.exs` hält das Fehlen fest).

    test "leere Fakten-Liste lässt die übrigen Spalten unberührt" do
      s = Updates.apply_scope(socket(), "campaign_facts", %{"facts" => []})
      idx = s |> gepushter_index_json() |> Jason.decode!()

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

    test "#1198: Lücken-Events → campaign_glatt_ansicht (die Anzeige-Form, kein Skelett)" do
      assert Updates.scope_for_event("TranscriptSmoothed") == "campaign_glatt_ansicht"
      assert Updates.scope_for_event("LueckenVorschlagGeneriert") == "campaign_glatt_ansicht"
      assert Updates.scope_for_event("LueckenKurationSet") == "campaign_glatt_ansicht"
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

      expected =
        Jason.encode!(Refs.build_sync_index(new_sums, epos(), chronik(), utterances(), [], []))

      assert gepushter_index_json(s) == expected

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

      expected =
        Jason.encode!(Refs.build_sync_index(summaries(), epos(), new_chr, utterances(), [], []))

      assert gepushter_index_json(s) == expected
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
        Jason.encode!(
          Refs.build_sync_index(summaries(), new_epos, chronik(), utterances(), [], [])
        )

      assert gepushter_index_json(s) == expected
    end
  end

  describe "#1198: die Derivations-Scopes tragen den 🕳-Marker" do
    test "summaries/chronik/epos übernehmen luecken_marker" do
      for {kind, snap} <- [
            {"campaign_summaries", %{"summaries" => summaries()}},
            {"campaign_chronik", %{"chronik" => chronik()}},
            {"campaign_epos", %{"epos" => epos(), "epos_history" => []}}
          ] do
        s = Updates.apply_scope(socket(), kind, Map.put(snap, "luecken_marker", ["summary:s1"]))

        assert s.assigns.luecken_marker == MapSet.new(["summary:s1"]),
               "#{kind} übernimmt den Marker nicht — 🕳 bliebe bis zum nächsten Voll-Read falsch"
      end
    end

    test "ein Alt-Worker ohne Marker lässt den Stand stehen" do
      alt = MapSet.new(["chronik:c1"])
      base = %{socket() | assigns: Map.put(socket().assigns, :luecken_marker, alt)}

      s = Updates.apply_scope(base, "campaign_chronik", %{"chronik" => chronik()})
      assert s.assigns.luecken_marker == alt
    end

    test "der Sync-Index liest die aufgelösten Quellen" do
      # Block-IDs in source_refs, Utterance-IDs in quell_utterance_ids — der
      # Index muss die zweiten nehmen, sonst zeigt er auf nichts.
      sums = [
        %{"session_id" => "s1", "source_refs" => ["b_x"], "quell_utterance_ids" => ["u1", "u2"]}
      ]

      s = Updates.apply_scope(socket(), "campaign_summaries", %{"summaries" => sums})
      idx = s |> gepushter_index_json() |> Jason.decode!()

      assert idx["entries_to_utts"]["summaries:s1"] == ["u1", "u2"]
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
      assert gepushter_index(s) == nil,
             "kein Sync-Index-Ereignis erwartet — dieser Scope baut den Index nicht neu"

      assert s.assigns.summaries == summaries()
    end
  end

  describe "apply_scope/3 — campaign_discord_config (Issue #985 Slice 1)" do
    test "ersetzt discord_config, fasst Sync-Index/andere Assigns NICHT an" do
      before = %{socket() | assigns: Map.put(socket().assigns, :discord_config, %{})}
      new_cfg = %{"guild_id" => "111", "voice_channel_id" => "222"}

      s = Updates.apply_scope(before, "campaign_discord_config", %{"discord_config" => new_cfg})

      assert s.assigns.discord_config == new_cfg

      assert gepushter_index(s) == nil,
             "kein Sync-Index-Ereignis erwartet — dieser Scope baut den Index nicht neu"

      assert s.assigns.summaries == summaries()
    end

    test "fehlender discord_config-Key im Snapshot -> leere Map statt Crash" do
      before = %{socket() | assigns: Map.put(socket().assigns, :discord_config, %{"x" => "y"})}
      s = Updates.apply_scope(before, "campaign_discord_config", %{})
      assert s.assigns.discord_config == %{}
    end
  end
end
