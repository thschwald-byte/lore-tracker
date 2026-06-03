defmodule Worker.RepoExtraTest do
  @moduledoc """
  Issue #66 (Coverage-Followup, Teil 2): hebt `Worker.Repo` über das
  70%-Ziel. Deckt die Read-Pfade ab, die `repo_queries_test` noch offen
  ließ — User-/Consent-Queries, Chronik (inkl. `derive_chronik_sort_tuple/1`-
  Datumsparsing), Epos + Epos-History, Speaker-Assignments,
  Faithfulness-Liste, Probelauf-Reads (leer) und die `snapshot`-Klauseln
  all_users + invite.

  Die Ollama-abhängigen `snapshot`-Klauseln (settings/probelauf, rufen
  `Worker.LLM.Local.list_models/0`) bleiben bewusst außen vor — sie sind
  in der Test-Umgebung netz-/timeout-abhängig.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Materializer
  alias Worker.Repo

  @cid "repo-x-camp"
  @owner "did-owner-x"
  @member "did-member-x"
  @sid "repo-x-camp-s1"

  setup do
    clear_all_tables!()
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)

    build_campaign(
      campaign_id: @cid,
      owner_did: @owner,
      members: [@member],
      sessions: [3],
      apply: true
    )

    :ok
  end

  defp apply!(kind, payload) do
    seq = System.unique_integer([:positive])
    ev = event(kind, payload, seq, event_id: "x-#{kind}-#{seq}")
    assert {:applied, _} = Materializer.apply_event(ev)
  end

  # ── derive_chronik_sort_tuple/1: reine Funktion, keine Events nötig ──

  describe "derive_chronik_sort_tuple/1" do
    test "leere / nil Daten → Familie 9 (ans Ende)" do
      assert Repo.derive_chronik_sort_tuple(nil) == {9, 0, ""}
      assert Repo.derive_chronik_sort_tuple("") == {9, 0, ""}
    end

    test "Unit+Zahl (Session/Tag/Day/Akt/Scene) → Familie 0, numerisch" do
      assert {0, 13, _} = Repo.derive_chronik_sort_tuple("Session 13")
      assert {0, 5, _} = Repo.derive_chronik_sort_tuple("Tag 5")
      assert {0, 2, _} = Repo.derive_chronik_sort_tuple("Akt 2")
      assert {0, 7, _} = Repo.derive_chronik_sort_tuple("scene 7")
    end

    test "Jahres-Datum mit optionaler Season → Familie 1, year*10+season" do
      # year*10 + season-bump (Spring 1, Summer 2, Autumn/Fall 3, Winter 4).
      assert {1, 5520, _} = Repo.derive_chronik_sort_tuple("552 CY")
      assert {1, 5521, _} = Repo.derive_chronik_sort_tuple("552 CY - Spring")
      assert {1, 5504, _} = Repo.derive_chronik_sort_tuple("550 CY (Winter)")
      assert {1, 5503, _} = Repo.derive_chronik_sort_tuple("550 CY Autumn")
    end

    test "narrativer Marker → Familie 2" do
      assert {2, 0, "Aufbruch"} = Repo.derive_chronik_sort_tuple("Aufbruch")
    end

    test "Familien sortieren 0 < 1 < 2 < 9" do
      dates = ["Aufbruch", nil, "552 CY", "Session 1"]
      sorted = Enum.sort_by(dates, &Repo.derive_chronik_sort_tuple/1)
      assert sorted == ["Session 1", "552 CY", "Aufbruch", nil]
    end
  end

  # ── User / Consent ──────────────────────────────────────────────

  describe "User-Queries" do
    test "UserUpserted → get_user + list_all_users" do
      apply!("UserUpserted", %{
        "discord_id" => @owner,
        "display_name" => "Zelda",
        "avatar_url" => "http://a"
      })

      u = Repo.get_user(@owner)
      assert u.display_name == "Zelda"
      assert u.avatar_url == "http://a"
      assert u.role == :spieler

      assert @owner in Enum.map(Repo.list_all_users(), & &1.discord_id)
      assert Repo.get_user("niemand") == nil
    end

    test "admin_exists?/last_admin? nach UserRoleSet :admin" do
      refute Repo.admin_exists?()

      apply!("UserUpserted", %{"discord_id" => @owner, "display_name" => "Boss"})
      apply!("UserRoleSet", %{"discord_id" => @owner, "role" => "admin"})

      assert Repo.admin_exists?()
      assert Repo.last_admin?(@owner)
      refute Repo.last_admin?("anderer")
    end

    test "AudioConsentRecorded → audio_consent" do
      assert Repo.audio_consent(@owner) == nil

      apply!("AudioConsentRecorded", %{"discord_id" => @owner, "version" => "v1"})

      consent = Repo.audio_consent(@owner)
      assert consent.version == "v1"
      assert consent.accepted_at
    end

    test "users_for_dashboard liefert die Spielleiter der Viewer-Kampagnen" do
      apply!("UserUpserted", %{"discord_id" => @owner, "display_name" => "GM"})
      users = Repo.users_for_dashboard(@member)
      assert users[@owner]["display_name"] == "GM"
    end
  end

  # ── Chronik (Materializer → list_chronik_entries) ────────────────

  describe "Chronik-Einträge" do
    test "list_chronik_entries sortiert nach derive_chronik_sort_tuple" do
      apply!("ChronikEntryChanged", %{
        "id" => "chr-b",
        "campaign_id" => @cid,
        "in_game_date" => "Session 2",
        "label" => "Später",
        "summary" => "B",
        "session_id" => @sid
      })

      apply!("ChronikEntryChanged", %{
        "id" => "chr-a",
        "campaign_id" => @cid,
        "in_game_date" => "Session 1",
        "label" => "Früher",
        "summary" => "A",
        "session_id" => @sid
      })

      entries = Repo.list_chronik_entries(@cid)
      assert Enum.map(entries, & &1.id) == ["chr-a", "chr-b"]
    end
  end

  # ── Epos + Epos-History ──────────────────────────────────────────

  describe "Epos" do
    test "EposEntryEdited → get_epos_entry + list_epos_history" do
      apply!("EposEntryEdited", %{
        "entry_id" => @cid,
        "campaign_id" => @cid,
        "new_md" => "# Das Epos",
        "source" => "llm",
        "source_refs" => ["u1", "u2"]
      })

      entry = Repo.get_epos_entry(@cid)
      assert entry.content_md == "# Das Epos"
      assert entry.source_refs == ["u1", "u2"]

      [hist] = Repo.list_epos_history(@cid)
      assert hist.content_md == "# Das Epos"
      assert hist.source == :llm
    end
  end

  # ── Speaker-Assignments ──────────────────────────────────────────

  describe "Speaker-Assignments" do
    test "SpeakerAssigned → list_speaker_assignments(_for_campaign)" do
      apply!("SpeakerAssigned", %{
        "session_id" => @sid,
        "speaker_label" => "Sprecher 1",
        "discord_id" => @member
      })

      [a] = Repo.list_speaker_assignments(@sid)
      assert a.speaker_label == "Sprecher 1"
      assert a.discord_id == @member

      assert Repo.list_speaker_assignments_for_campaign(@cid) == [a]
    end
  end

  # ── Faithfulness-Liste ───────────────────────────────────────────

  describe "Faithfulness" do
    test "list_faithfulness_scores nach SessionFaithfulnessScored" do
      apply!("SessionFaithfulnessScored", %{
        "session_id" => @sid,
        "campaign_id" => @cid,
        "score" => 0.91,
        "claims" => []
      })

      [score] = Repo.list_faithfulness_scores(@cid)
      assert score.score == 0.91
    end
  end

  # ── Probelauf-Reads (leer) ───────────────────────────────────────

  describe "Probelauf-Reads ohne Daten" do
    test "leere Tabellen → nil / []" do
      assert Repo.last_probelauf_run() == nil
      assert Repo.all_probelauf_runs() == []
      assert Repo.last_probelauf_sweep() == nil
    end
  end

  # ── LLM-Spend (Issue #177) ───────────────────────────────────────

  describe "LLM-Spend" do
    test "snapshot kind=llm_spend aggregiert die gebillten Calls" do
      apply!("LLMCallBilled", %{
        "provider" => "anthropic",
        "model" => "claude-x",
        "input_tokens" => 100,
        "output_tokens" => 50,
        "cost_usd" => 0.012,
        "requested_by_discord_id" => @owner,
        "session_id" => @sid,
        "stage" => "summary",
        "duration_ms" => 1200
      })

      apply!("LLMCallBilled", %{
        "provider" => "openai",
        "model" => "gpt-x",
        "input_tokens" => 200,
        "output_tokens" => 80,
        "cost_usd" => 0.02,
        "requested_by_discord_id" => @owner,
        "session_id" => @sid,
        "stage" => "epos",
        "duration_ms" => 900
      })

      snap = Repo.snapshot(%{"kind" => "llm_spend"})
      assert length(snap["rows"]) == 2
      assert_in_delta snap["totals"]["total_cost_usd"], 0.032, 0.0001
      assert snap["totals"]["total_input_tokens"] == 300
      assert snap["totals"]["total_calls"] == 2
      assert Map.has_key?(snap["totals"]["by_provider"], "anthropic")
      assert Map.has_key?(snap["totals"]["by_provider"], "openai")
    end
  end

  # ── Last-Spielleiter-Resolution (Issue #57) ──────────────────────

  describe "last_spielleiter_campaigns_for/1" do
    test "Owner ist einziger SL → Kampagne taucht mit promotebaren Spielern auf" do
      result = Repo.last_spielleiter_campaigns_for(@owner)
      assert [%{id: @cid, members: members}] = result
      assert @member in Enum.map(members, & &1.discord_id)
    end

    test "Nicht-SL → leere Liste" do
      assert Repo.last_spielleiter_campaigns_for(@member) == []
    end
  end

  # ── snapshot/1: all_users + invite ───────────────────────────────

  describe "snapshot/1 — Admin- + Invite-Klauseln" do
    test "kind=all_users liefert users + campaigns" do
      apply!("UserUpserted", %{"discord_id" => @owner, "display_name" => "Admin"})
      snap = Repo.snapshot(%{"kind" => "all_users"})
      assert is_list(snap["users"])
      assert is_list(snap["campaigns"])
      assert Enum.any?(snap["campaigns"], &(&1["id"] == @cid))
    end

    test "kind=invite liefert Invite + Kampagne" do
      apply!("InviteCreated", %{
        "token" => "snap-tok",
        "campaign_id" => @cid,
        "created_by_discord_id" => @owner,
        "expires_at" => "2099-01-01T00:00:00Z"
      })

      snap = Repo.snapshot(%{"kind" => "invite", "token" => "snap-tok"})
      assert snap["invite"]["token"] == "snap-tok"
      assert snap["campaign"]["id"] == @cid
    end

    test "kind=invite für unbekannten Token → not_found" do
      assert Repo.snapshot(%{"kind" => "invite", "token" => "gibt-es-nicht"}) == %{
               "not_found" => true
             }
    end
  end
end
