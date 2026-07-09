defmodule Worker.LegacyEventBackfillTest do
  @moduledoc """
  Issue #696: Drift-Guard für den Legacy-Event-Backfill. Fixture = das
  Pre-Migration-Szenario: Domain-Rows werden DIREKT in Mnesia geschrieben
  (ohne Events in den Logs). Getestet werden (a) die synthetisierten
  Event-Shapes + Reihenfolge + ts-Mapping, (b) der Roundtrip (Events in eine
  leere Mnesia anwenden → Domain-Zustand äquivalent zur Fixture) und (c) die
  Skip-Idempotenz von run/2 (CampaignCreated schon im Global-Log → skip).
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.LegacyEventBackfill, as: Backfill
  alias Worker.Materializer
  alias Worker.Schema.Mnesia, as: S

  @cid "legacy-backfill-test-campaign"
  @owner "owner-did-696"
  @player "player-did-696"
  @sid "legacy-session-696"

  setup do
    clear_all_tables!()
    {:atomic, :ok} = :mnesia.clear_table(S.worker_state())
    # Der Backfill legt beim Apply den dynamischen per-Campaign-Store an
    # (disc_copies, überlebt clear_all_tables!). Vor UND nach dem Test
    # droppen, sonst zählen andere Tests (EventLogTest scannt ALLE
    # Campaign-Stores) unsere Alt-ts-Events mit.
    Worker.Schema.DynamicTables.drop_campaign_store!(@cid)

    mat_pid = ensure_materializer!()

    on_exit(fn ->
      if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill)
      Worker.Schema.DynamicTables.drop_campaign_store!(@cid)
    end)

    :ok
  end

  defp dt(iso),
    do:
      (case DateTime.from_iso8601(iso) do
         {:ok, d, _} -> d
       end)

  # Pre-Migration-Fixture: Domain-Rows OHNE Events (genau der #696-Zustand).
  defp write_fixture! do
    created = dt("2025-01-01T10:00:00Z")
    started = dt("2025-01-02T19:00:00Z")
    ended = dt("2025-01-02T23:00:00Z")

    :ok =
      :mnesia.dirty_write(
        {S.campaigns(), @cid, "Legacy-Kampagne", nil, "Alt-Import", :active, created,
         %{"base" => "düster"}, nil, :confirmed}
      )

    :ok =
      :mnesia.dirty_write(
        {S.campaign_members(), S.member_key(@cid, @owner), @cid, @owner, :spielleiter, created,
         nil, nil}
      )

    :ok =
      :mnesia.dirty_write(
        {S.campaign_members(), S.member_key(@cid, @player), @cid, @player, :spieler,
         dt("2025-01-01T11:00:00Z"), "Aragorn", nil}
      )

    :ok = :mnesia.dirty_write({S.users(), @owner, "Der SL", created, nil, :spielleiter, nil})
    :ok = :mnesia.dirty_write({S.users(), @player, "Spieler Eins", created, nil, :spieler, nil})

    :ok =
      :mnesia.dirty_write(
        {S.sessions(), @sid, @cid, 1, "Auftakt", :completed, nil, started, ended}
      )

    :ok =
      :mnesia.dirty_write(
        {S.utterances(), "utt-1", @sid, @owner, dt("2025-01-02T19:05:00Z"), "Es beginnt.", 0.9,
         :confirmed, nil}
      )

    :ok =
      :mnesia.dirty_write(
        {S.utterances(), "utt-2", @sid, @player, dt("2025-01-02T19:06:00Z"), "Ich ziehe los.",
         0.8, :confirmed, dt("2025-01-03T00:00:00Z")}
      )

    :ok =
      :mnesia.dirty_write(
        {S.session_summaries(), @sid, @cid, "# Resümee", dt("2025-01-03T01:00:00Z"), :llm,
         ["utt-1"], []}
      )

    :ok =
      :mnesia.dirty_write(
        # Issue #724/#698: chronik_entries ist ein 12-Tupel (in_game_day/precision
        # + generation trailing) — Legacy-Fixture ohne Zeitstrahl-Datum/Generation
        # → nil, nil, nil.
        {S.chronik_entries(), "chr-1", @cid, "1. Tag", "Aufbruch", "Die Reise beginnt", @sid,
         ["utt-1"], "**Aufbruch**", nil, nil, nil}
      )

    :ok =
      :mnesia.dirty_write(
        {S.epos_entries(), "epos-#{@cid}", @cid, nil, "# Epos", dt("2025-01-03T02:00:00Z"),
         ["utt-1"]}
      )

    :ok
  end

  describe "plan/1 — Shapes, Reihenfolge, ts-Mapping" do
    test "unbekannte Kampagne → not_found" do
      assert Backfill.plan("gibt-es-nicht") == {:error, :not_found}
    end

    test "CampaignCreated zuerst, mit Owner + Original-created_at im ts" do
      write_fixture!()
      {:ok, [first | _rest]} = Backfill.plan(@cid)

      assert %{
               "payload" => %{
                 "kind" => "CampaignCreated",
                 "id" => @cid,
                 "name" => "Legacy-Kampagne",
                 "owner_discord_id" => @owner,
                 "owner_display_name" => "Der SL"
               },
               "ts" => "2025-01-01T10:00:00Z"
             } = first
    end

    test "Member/Rolle/Alias, Session-Trio, Utterances mit Tombstone, Artefakte" do
      write_fixture!()
      {:ok, events} = Backfill.plan(@cid)
      kinds = Enum.map(events, & &1["payload"]["kind"])

      # Spieler kommt als AdminMemberAdded (kein Promote — er ist :spieler),
      # sein Charaktername als Alias.
      assert "AdminMemberAdded" in kinds
      refute "MemberRolePromoted" in kinds
      assert "CampaignAliasSet" in kinds
      # Flavor-Slot aus der Map.
      assert Enum.any?(
               events,
               &(&1["payload"]["kind"] == "CampaignFlavorSet" and
                   &1["payload"]["slot"] == "base")
             )

      # Session-Trio mit Original-Zeiten im Event-ts.
      started = Enum.find(events, &(&1["payload"]["kind"] == "SessionStarted"))
      ended = Enum.find(events, &(&1["payload"]["kind"] == "SessionEnded"))
      assert started["ts"] == "2025-01-02T19:00:00Z"
      assert ended["ts"] == "2025-01-02T23:00:00Z"

      # Utterances chronologisch, payload-timestamp = Original, Tombstone folgt.
      utts = Enum.filter(events, &(&1["payload"]["kind"] == "UtteranceAppended"))
      assert Enum.map(utts, & &1["payload"]["id"]) == ["utt-1", "utt-2"]
      assert hd(utts)["payload"]["timestamp"] == "2025-01-02T19:05:00Z"

      assert Enum.any?(
               events,
               &(&1["payload"]["kind"] == "UtteranceDeleted" and
                   &1["payload"]["id"] == "utt-2")
             )

      # Artefakte.
      assert "SessionSummaryGenerated" in kinds
      assert "ChronikEntryChanged" in kinds
      assert "EposEntryEdited" in kinds

      # Abhängigkeits-Reihenfolge: Created vor Membership vor Session vor Utterance.
      idx = fn kind -> Enum.find_index(kinds, &(&1 == kind)) end
      assert idx.("CampaignCreated") < idx.("AdminMemberAdded")
      assert idx.("AdminMemberAdded") < idx.("SessionScheduled")
      assert idx.("SessionScheduled") < idx.("UtteranceAppended")
    end

    test "alle Payloads sind JSON-serialisierbar (gehen beim Pull übers Wire)" do
      write_fixture!()
      {:ok, events} = Backfill.plan(@cid)
      assert {:ok, _} = Jason.encode(events)
    end
  end

  describe "Roundtrip — plan-Events in leere Mnesia → Domain-Zustand äquivalent" do
    test "Campaign/Member/Session/Utterances/Summary materialisieren korrekt" do
      write_fixture!()
      {:ok, events} = Backfill.plan(@cid)

      # Leere Mnesia (simulierter frischer Worker), dann Replay wie der
      # Pull-Sync es täte (apply_local pro Event, in Log-Reihenfolge).
      clear_all_tables!()

      Enum.each(events, fn %{"payload" => payload, "ts" => ts} ->
        :ok =
          Materializer.apply_local(%{
            "event_id" => UUIDv7.generate(),
            "payload" => payload,
            "ts" => ts,
            "author_worker_id" => nil
          })
      end)

      # Campaign-Row mit Original-created_at.
      [{_, @cid, "Legacy-Kampagne", _, _, :active, created_at, flavors, _, _}] =
        :mnesia.dirty_read(S.campaigns(), @cid)

      assert DateTime.to_iso8601(created_at) == "2025-01-01T10:00:00Z"
      assert flavors == %{"base" => "düster"}

      # Beide Member, Rollen korrekt, Alias da.
      [{_, _, _, _, :spielleiter, _, _, nil}] =
        :mnesia.dirty_read(S.campaign_members(), S.member_key(@cid, @owner))

      [{_, _, _, _, :spieler, _, "Aragorn", nil}] =
        :mnesia.dirty_read(S.campaign_members(), S.member_key(@cid, @player))

      # Session completed mit Original-Zeiten.
      [{_, @sid, @cid, 1, "Auftakt", :completed, _, started_at, ended_at}] =
        :mnesia.dirty_read(S.sessions(), @sid)

      assert DateTime.to_iso8601(started_at) == "2025-01-02T19:00:00Z"
      assert DateTime.to_iso8601(ended_at) == "2025-01-02T23:00:00Z"

      # Utterances: Texte + Original-Timestamps + Tombstone auf utt-2.
      [{_, "utt-1", @sid, @owner, ts1, "Es beginnt.", 0.9, :confirmed, nil}] =
        :mnesia.dirty_read(S.utterances(), "utt-1")

      assert DateTime.to_iso8601(ts1) == "2025-01-02T19:05:00Z"

      [{_, "utt-2", _, _, _, _, _, _, deleted_at}] = :mnesia.dirty_read(S.utterances(), "utt-2")
      refute is_nil(deleted_at)

      # Summary mit Original-generated_at + flagged_claims-Slot (Issue #715, [] für alte Rows).
      [{_, @sid, @cid, "# Resümee", gen_at, :llm, ["utt-1"], []}] =
        :mnesia.dirty_read(S.session_summaries(), @sid)

      assert DateTime.to_iso8601(gen_at) == "2025-01-03T01:00:00Z"

      # Chronik + Epos.
      # Issue #724/#698: 12-Tupel (in_game_day/precision + generation trailing).
      # in_game_day/precision nil (Legacy ohne Zeitstrahl-Datum); generation ist
      # die frische event_id des Backfill-Re-Emits (via Materializer-Fallback).
      [{_, "chr-1", @cid, "1. Tag", "Aufbruch", _, @sid, ["utt-1"], "**Aufbruch**", nil, nil, _}] =
        :mnesia.dirty_read(S.chronik_entries(), "chr-1")

      [{_, _, @cid, nil, "# Epos", _, ["utt-1"]}] =
        :mnesia.dirty_read(S.epos_entries(), "epos-#{@cid}")
    end
  end

  describe "run/2 + legacy_campaigns/0 — Skip-Idempotenz" do
    test "Kampagne mit CampaignCreated im Global-Log wird geskippt, --force übersteuert" do
      write_fixture!()

      # Vorher: Kandidat für den Backfill.
      assert @cid in Backfill.legacy_campaigns()
      refute Backfill.migrated?(@cid)

      # Erster Lauf schreibt (CampaignCreated landet im Global-Log).
      assert [{@cid, :applied, n}] = Backfill.run([@cid])
      assert n > 0
      assert Backfill.migrated?(@cid)
      refute @cid in Backfill.legacy_campaigns()

      # Zweiter Lauf: Skip ohne force, applied mit force.
      assert [{@cid, :skipped_migrated}] = Backfill.run([@cid])
      assert [{@cid, :applied, _}] = Backfill.run([@cid], force: true)
    end

    test "unbekannte Kampagne → not_found" do
      assert [{"nope", :not_found}] = Backfill.run(["nope"])
    end
  end
end
