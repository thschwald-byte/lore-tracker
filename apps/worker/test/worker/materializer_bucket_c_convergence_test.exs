defmodule Worker.MaterializerBucketCConvergenceTest do
  @moduledoc """
  Issue #766 (I7-Bucket-C): Convergence-Tests für die 15 neu geguardeten
  Folds + Sonderfälle (Invite-Cross-Kind-Kollision, Partial-Payload-Brüche,
  Reject-Log, nil-event_id-Randfälle, Migrations-Backfill).

  Zwei Test-Muster:

  - **Self-sufficient Folds** (Apply-Code schreibt unconditional, kein
    Existenz-Check auf eine Parent-Row): `materialize_permutations/2`
    (5 Reihenfolgen) aus `Worker.TestHelper`.
  - **Row-required Folds** (Apply-Code liest erst die bestehende Row, No-op
    wenn sie fehlt — CampaignUpdated, CampaignFlavorSet, CampaignArchived,
    CampaignAliasSet, MemberRolePromoted, InviteRevoked/Redeemed,
    UtteranceEdited): Basis-Entität fix vor JEDER der 2 Reihenfolgen neu
    aufgebaut, nur die 2 konkurrierenden Events werden umsortiert — 2
    Ordnungen reichen für paarweise Order-Unabhängigkeit (Analog zum
    bestehenden #698-Pattern "gleiche id, höheres event_id gewinnt").
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper
  import ExUnit.CaptureLog

  alias Worker.Materializer
  alias Worker.Repo
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-816"
  @sid "camp-816-s1"
  @uid "camp-816-s1-u1"
  @member_did "did-member-816"
  @owner_did "did-owner-816"
  @token "tok-816"

  setup do
    reset_for_permutation!()
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
    :ok
  end

  defp next_seq, do: System.unique_integer([:positive, :monotonic])

  # Kampagne + 1 Member + 1 Session mit 1 Utterance + 1 Invite frisch aufbauen
  # — für row-required Folds vor JEDER der 2 Reihenfolgen neu aufgerufen.
  defp seed_base! do
    build_campaign(
      campaign_id: @cid,
      owner_did: @owner_did,
      members: [@member_did],
      sessions: [1],
      apply: true
    )

    # event_id setzen → Apply läuft über den event_id-Pfad, unabhängig vom
    # Seq-Cursor materialisiert (sonst könnte ein Seq-Gap-Zufall — next_seq()
    # ist global monoton über die ganze Testdatei, nicht pro Test resettet —
    # dieses Event stillschweigend über den Cursor-Skip verwerfen).
    Materializer.apply_event(
      event(
        "InviteCreated",
        %{"token" => @token, "campaign_id" => @cid, "created_by_discord_id" => @owner_did},
        next_seq(),
        event_id: "seed-invite-created"
      )
    )
  end

  defp apply_pairwise!(order) do
    reset_for_permutation!()
    seed_base!()
    Enum.each(order, &Materializer.apply_event/1)
  end

  defp assert_pairwise_converges!(older, newer, read_fn, expected) do
    for order <- [[older, newer], [newer, older]] do
      apply_pairwise!(order)

      assert read_fn.() == expected,
             "Reihenfolge #{inspect(order |> Enum.map(& &1["event_id"]))} lieferte falsches Ergebnis"
    end
  end

  # ─── Row-required Folds ──────────────────────────────────────────

  describe "CampaignUpdated" do
    test "höheres event_id gewinnt, konvergent unter Umordnung" do
      older =
        event(
          "CampaignUpdated",
          %{"id" => @cid, "name" => "Alt", "icon_url" => nil, "theme_blurb" => nil},
          next_seq(),
          event_id: "e01"
        )

      newer =
        event(
          "CampaignUpdated",
          %{"id" => @cid, "name" => "Neu", "icon_url" => nil, "theme_blurb" => nil},
          next_seq(),
          event_id: "e02"
        )

      assert_pairwise_converges!(older, newer, fn -> Repo.get_campaign(@cid).name end, "Neu")
    end

    test "toter status-Branch: Payload-status wird NICHT übernommen (status bleibt Owner von CampaignArchived)" do
      apply_pairwise!([
        event(
          "CampaignUpdated",
          %{
            "id" => @cid,
            "name" => "X",
            "icon_url" => nil,
            "theme_blurb" => nil,
            "status" => "archived"
          },
          next_seq(),
          event_id: "e01"
        )
      ])

      assert Repo.get_campaign(@cid).status == :active
    end

    test "Partial-Payload (fehlendes icon_url) loggt die Voll-Snapshot-Warnung" do
      apply_pairwise!([])

      log =
        capture_log(fn ->
          Materializer.apply_event(
            event(
              "CampaignUpdated",
              %{"id" => @cid, "name" => "X", "theme_blurb" => "Y"},
              next_seq()
            )
          )
        end)

      # Logger.warning (nicht :debug) — läuft schon durch die Default-Test-
      # Logger-Config (:warning), kein Level-Override nötig.
      assert log =~ "Voll-Snapshot-Invariante gebrochen"
    end
  end

  describe "CampaignVocabUpdated" do
    test "höheres event_id gewinnt, konvergent unter Umordnung" do
      older =
        event("CampaignVocabUpdated", %{"campaign_id" => @cid, "vocab_hint" => "alt"}, next_seq(),
          event_id: "e01"
        )

      newer =
        event("CampaignVocabUpdated", %{"campaign_id" => @cid, "vocab_hint" => "neu"}, next_seq(),
          event_id: "e02"
        )

      assert_pairwise_converges!(
        older,
        newer,
        fn -> Repo.get_campaign(@cid).vocab_hint end,
        "neu"
      )
    end
  end

  describe "CampaignTranscriptSourceUpdated" do
    test "höheres event_id gewinnt, konvergent unter Umordnung" do
      older =
        event(
          "CampaignTranscriptSourceUpdated",
          %{"campaign_id" => @cid, "transcript_source" => "live"},
          next_seq(),
          event_id: "e01"
        )

      newer =
        event(
          "CampaignTranscriptSourceUpdated",
          %{"campaign_id" => @cid, "transcript_source" => "confirmed"},
          next_seq(),
          event_id: "e02"
        )

      assert_pairwise_converges!(
        older,
        newer,
        fn -> Repo.get_campaign(@cid).transcript_source end,
        :confirmed
      )
    end
  end

  describe "CampaignArchived" do
    test "ein älteres Event nach einem neueren wird verworfen (Reject-Log)" do
      newer = event("CampaignArchived", %{"campaign_id" => @cid}, next_seq(), event_id: "e02")
      older = event("CampaignArchived", %{"campaign_id" => @cid}, next_seq(), event_id: "e01")

      apply_pairwise!([newer])
      assert Repo.get_campaign(@cid).status == :archived

      # `Logger.debug/1` in fold_supersedes?/4 wird bei der Default-Test-
      # Logger-Config (:warning) VOR dem Backend gefiltert — CaptureLog's
      # `level:`-Opt überschreibt das nicht zuverlässig, ein expliziter
      # Per-Modul-Level-Override auf das AUFRUFENDE Modul (Worker.Materializer,
      # nicht diesen Test) ist der einzige Weg, der tatsächlich durchgreift.
      Logger.put_module_level(Worker.Materializer, :debug)

      log = capture_log(fn -> Materializer.apply_event(older) end)

      Logger.delete_module_level(Worker.Materializer)

      assert log =~ "fold rejected"
      assert log =~ "fold=campaign_archived_status"
    end
  end

  describe "CampaignFlavorSet — Partial-Payload-Fund (kritisch)" do
    test "zwei unterschiedliche Slots konvergieren BEIDE, unabhängig von der Reihenfolge" do
      # Der eigentliche Test für den zweiten Design-Fund: base (älter) und
      # epos (neuer) sind UNABHÄNGIGE Feld-Updates. Ohne die Slot-Keying-
      # Korrektur würde die Reihenfolge [epos, base] das base-Update
      # fälschlich verwerfen (Guard sähe epos' event_id als "neueren Winner"
      # für denselben — falschen — Fold-Key).
      base_ev =
        event(
          "CampaignFlavorSet",
          %{"campaign_id" => @cid, "slot" => "base", "flavor" => "Grimdark"},
          next_seq(),
          event_id: "e01"
        )

      epos_ev =
        event(
          "CampaignFlavorSet",
          %{"campaign_id" => @cid, "slot" => "epos", "flavor" => "Episch"},
          next_seq(),
          event_id: "e02"
        )

      for order <- [[base_ev, epos_ev], [epos_ev, base_ev]] do
        apply_pairwise!(order)
        flavors = Repo.get_campaign(@cid).flavors

        assert flavors["base"] == "Grimdark",
               "base-Slot muss unabhängig von Reihenfolge #{inspect(order |> Enum.map(& &1["event_id"]))} erhalten bleiben"

        assert flavors["epos"] == "Episch",
               "epos-Slot muss unabhängig von Reihenfolge #{inspect(order |> Enum.map(& &1["event_id"]))} erhalten bleiben"
      end
    end

    test "zwei Events für DENSELBEN Slot konvergieren auf das höhere event_id" do
      older =
        event(
          "CampaignFlavorSet",
          %{"campaign_id" => @cid, "slot" => "base", "flavor" => "Alt"},
          next_seq(),
          event_id: "e01"
        )

      newer =
        event(
          "CampaignFlavorSet",
          %{"campaign_id" => @cid, "slot" => "base", "flavor" => "Neu"},
          next_seq(),
          event_id: "e02"
        )

      assert_pairwise_converges!(
        older,
        newer,
        fn -> Repo.get_campaign(@cid).flavors["base"] end,
        "Neu"
      )
    end
  end

  describe "CampaignAliasSet" do
    test "höheres event_id gewinnt, konvergent unter Umordnung" do
      older =
        event(
          "CampaignAliasSet",
          %{"campaign_id" => @cid, "discord_id" => @member_did, "character_name" => "Alt"},
          next_seq(),
          event_id: "e01"
        )

      newer =
        event(
          "CampaignAliasSet",
          %{"campaign_id" => @cid, "discord_id" => @member_did, "character_name" => "Neu"},
          next_seq(),
          event_id: "e02"
        )

      read = fn ->
        [row] = :mnesia.dirty_read(S.campaign_members(), S.member_key(@cid, @member_did))
        elem(row, 6)
      end

      assert_pairwise_converges!(older, newer, read, "Neu")
    end
  end

  describe "MemberRolePromoted" do
    test "höheres event_id gewinnt, konvergent unter Umordnung" do
      older =
        event(
          "MemberRolePromoted",
          %{"campaign_id" => @cid, "discord_id" => @member_did, "new_role" => "spielleiter"},
          next_seq(),
          event_id: "e01"
        )

      newer =
        event(
          "MemberRolePromoted",
          %{"campaign_id" => @cid, "discord_id" => @member_did, "new_role" => "spieler"},
          next_seq(),
          event_id: "e02"
        )

      assert_pairwise_converges!(
        older,
        newer,
        fn -> Repo.campaign_role(@cid, @member_did) end,
        :spieler
      )
    end
  end

  describe "InviteRevoked/InviteRedeemed — geteilter Fold :invite_status (der eigentliche Fund)" do
    test "GM widerruft (neuer) nach Spieler-Einlösung (älter) — Revoke gewinnt" do
      redeem =
        event(
          "InviteRedeemed",
          %{"token" => @token, "discord_id" => "did-redeemer-1", "display_name" => "R1"},
          next_seq(),
          event_id: "e01"
        )

      revoke = event("InviteRevoked", %{"token" => @token}, next_seq(), event_id: "e02")

      for order <- [[redeem, revoke], [revoke, redeem]] do
        apply_pairwise!(order)
        assert Repo.get_invite(@token).status == :revoked
      end
    end

    test "Spieler löst ein (neuer) nach GM-Widerruf (älter) — Redeem gewinnt" do
      revoke = event("InviteRevoked", %{"token" => @token}, next_seq(), event_id: "e01")

      redeem =
        event(
          "InviteRedeemed",
          %{"token" => @token, "discord_id" => "did-redeemer-2", "display_name" => "R2"},
          next_seq(),
          event_id: "e02"
        )

      for order <- [[revoke, redeem], [redeem, revoke]] do
        apply_pairwise!(order)
        assert Repo.get_invite(@token).status == :redeemed
      end
    end

    test "InviteRedeemed: User-Upsert läuft IMMER, auch wenn der Invite-Status-Write verworfen wird" do
      # Redeem mit ÄLTEREM event_id nach einem bereits gewonnenen Revoke —
      # der Invite-Status-Write wird verworfen, aber der User MUSS trotzdem
      # in S.users() landen (Bucket-F-Seiteneffekt, kein Bucket-C-Race).
      apply_pairwise!([
        event("InviteRevoked", %{"token" => @token}, next_seq(), event_id: "e05")
      ])

      assert Repo.get_invite(@token).status == :revoked

      stale_redeem =
        event(
          "InviteRedeemed",
          %{"token" => @token, "discord_id" => "did-late-redeemer", "display_name" => "Late"},
          next_seq(),
          event_id: "e01"
        )

      Materializer.apply_event(stale_redeem)

      # Invite-Status bleibt :revoked (das ältere Redeem wurde verworfen) ...
      assert Repo.get_invite(@token).status == :revoked
      # ... aber der User + die Membership wurden trotzdem angelegt.
      assert [_] = :mnesia.dirty_read(S.users(), "did-late-redeemer")

      assert [_] =
               :mnesia.dirty_read(S.campaign_members(), S.member_key(@cid, "did-late-redeemer"))
    end
  end

  describe "UtteranceEdited — Partial-Payload-Fund (kritisch, Feld-Split)" do
    test "new_text (älter) + new_timestamp (neuer) sind unabhängig, BEIDE überleben" do
      seed_base!()

      text_ev =
        event("UtteranceEdited", %{"id" => @uid, "new_text" => "Korrigierter Text"}, next_seq(),
          event_id: "e01"
        )

      ts_ev =
        event(
          "UtteranceEdited",
          %{"id" => @uid, "new_timestamp" => "2026-02-02T10:00:00Z"},
          next_seq(),
          event_id: "e02"
        )

      for order <- [[text_ev, ts_ev], [ts_ev, text_ev]] do
        reset_for_permutation!()
        seed_base!()
        Enum.each(order, &Materializer.apply_event/1)

        [row] = :mnesia.dirty_read(S.utterances(), @uid)
        {_, _, _, _, ts, text, _, _, _} = row

        assert text == "Korrigierter Text",
               "Text-Änderung muss unabhängig von Reihenfolge #{inspect(order |> Enum.map(& &1["event_id"]))} überleben"

        assert DateTime.to_iso8601(ts) == "2026-02-02T10:00:00Z",
               "Timestamp-Änderung muss unabhängig von Reihenfolge #{inspect(order |> Enum.map(& &1["event_id"]))} überleben"
      end
    end

    test "zwei new_text-Events konvergieren auf das höhere event_id" do
      seed_base!()

      older =
        event("UtteranceEdited", %{"id" => @uid, "new_text" => "Alt"}, next_seq(),
          event_id: "e01"
        )

      newer =
        event("UtteranceEdited", %{"id" => @uid, "new_text" => "Neu"}, next_seq(),
          event_id: "e02"
        )

      read = fn ->
        [row] = :mnesia.dirty_read(S.utterances(), @uid)
        elem(row, 5)
      end

      for order <- [[older, newer], [newer, older]] do
        reset_for_permutation!()
        seed_base!()
        Enum.each(order, &Materializer.apply_event/1)
        assert read.() == "Neu"
      end
    end
  end

  # ─── Self-sufficient Folds (kein Existenz-Check, materialize_permutations OK) ──

  describe "CampaignVorgabeSet" do
    test "höheres event_id gewinnt, konvergent über 5 Permutationen" do
      events = [
        event(
          "CampaignVorgabeSet",
          %{
            "campaign_id" => @cid,
            "stage" => "summary",
            "name" => "Alt",
            "darstellungsform" => "Fliesstext"
          },
          next_seq(),
          event_id: "e01"
        ),
        event(
          "CampaignVorgabeSet",
          %{
            "campaign_id" => @cid,
            "stage" => "summary",
            "name" => "Neu",
            "darstellungsform" => "Stichpunkte"
          },
          next_seq(),
          event_id: "e02"
        )
      ]

      for name <-
            materialize_permutations(events, fn ->
              [row] = :mnesia.dirty_read(S.campaign_vorgaben(), "#{@cid}:summary")
              elem(row, 4)
            end) do
        assert name == "Neu"
      end
    end

    test "Delete- und Write-Zweig teilen sich denselben Guard" do
      set_ev =
        event(
          "CampaignVorgabeSet",
          %{"campaign_id" => @cid, "stage" => "epos", "name" => "X", "darstellungsform" => "Y"},
          next_seq(),
          event_id: "e01"
        )

      delete_ev =
        event(
          "CampaignVorgabeSet",
          %{"campaign_id" => @cid, "stage" => "epos", "name" => "", "darstellungsform" => ""},
          next_seq(),
          event_id: "e02"
        )

      for r <-
            materialize_permutations([set_ev, delete_ev], fn ->
              :mnesia.dirty_read(S.campaign_vorgaben(), "#{@cid}:epos")
            end) do
        assert r == [],
               "das neuere Delete-Event muss immer gewinnen (Row weg), war: #{inspect(r)}"
      end
    end
  end

  describe "CampaignCalendarSet" do
    test "höheres event_id gewinnt, konvergent über 5 Permutationen" do
      older =
        event(
          "CampaignCalendarSet",
          %{
            "campaign_id" => @cid,
            "calendar" => %{"months" => [%{"name" => "Alt", "days" => 30}]}
          },
          next_seq(),
          event_id: "e01"
        )

      newer =
        event(
          "CampaignCalendarSet",
          %{
            "campaign_id" => @cid,
            "calendar" => %{"months" => [%{"name" => "Neu", "days" => 31}]}
          },
          next_seq(),
          event_id: "e02"
        )

      read = fn ->
        [{_, _, json, _}] = :mnesia.dirty_read(S.campaign_calendars(), @cid)
        Jason.decode!(json)["months"] |> List.first() |> Map.get("name")
      end

      for name <- materialize_permutations([older, newer], read) do
        assert name == "Neu"
      end
    end
  end

  describe "SessionInGameAnchorSet" do
    test "höheres event_id gewinnt, konvergent über 5 Permutationen" do
      older =
        event(
          "SessionInGameAnchorSet",
          %{"session_id" => @sid, "campaign_id" => @cid, "in_game_date_raw" => "1. Januar"},
          next_seq(),
          event_id: "e01"
        )

      newer =
        event(
          "SessionInGameAnchorSet",
          %{"session_id" => @sid, "campaign_id" => @cid, "in_game_date_raw" => "2. Januar"},
          next_seq(),
          event_id: "e02"
        )

      read = fn ->
        [row] = :mnesia.dirty_read(S.session_anchors(), @sid)
        # {tbl, session_id, campaign_id, day, raw} -> elem(4) = raw
        elem(row, 4)
      end

      for raw <- materialize_permutations([older, newer], read) do
        assert raw == "2. Januar"
      end
    end

    test "Delete- (leerer Roh-String) und Write-Zweig teilen sich denselben Guard" do
      set_ev =
        event(
          "SessionInGameAnchorSet",
          %{"session_id" => @sid, "campaign_id" => @cid, "in_game_date_raw" => "1. Januar"},
          next_seq(),
          event_id: "e01"
        )

      delete_ev =
        event(
          "SessionInGameAnchorSet",
          %{"session_id" => @sid, "campaign_id" => @cid, "in_game_date_raw" => ""},
          next_seq(),
          event_id: "e02"
        )

      for r <-
            materialize_permutations([set_ev, delete_ev], fn ->
              :mnesia.dirty_read(S.session_anchors(), @sid)
            end) do
        assert r == [],
               "das neuere Delete-Event muss immer gewinnen (Row weg), war: #{inspect(r)}"
      end
    end
  end

  describe "UserRoleSet" do
    test "höheres event_id gewinnt, konvergent über 5 Permutationen" do
      older =
        event("UserRoleSet", %{"discord_id" => @member_did, "role" => "spielleiter"}, next_seq(),
          event_id: "e01"
        )

      newer =
        event("UserRoleSet", %{"discord_id" => @member_did, "role" => "spieler"}, next_seq(),
          event_id: "e02"
        )

      read = fn ->
        [row] = :mnesia.dirty_read(S.users(), @member_did)
        elem(row, 5)
      end

      for role <- materialize_permutations([older, newer], read) do
        assert role == :spieler
      end
    end
  end

  describe "UserSpendCapChanged" do
    test "höheres event_id gewinnt, konvergent über 5 Permutationen" do
      older =
        event(
          "UserSpendCapChanged",
          %{"discord_id" => @member_did, "cap_usd" => 10.0},
          next_seq(),
          event_id: "e01"
        )

      newer =
        event(
          "UserSpendCapChanged",
          %{"discord_id" => @member_did, "cap_usd" => 20.0},
          next_seq(),
          event_id: "e02"
        )

      read = fn ->
        [row] = :mnesia.dirty_read(S.users(), @member_did)
        elem(row, 6)
      end

      for cap <- materialize_permutations([older, newer], read) do
        assert cap == 20.0
      end
    end
  end

  describe "SpeakerAssigned" do
    test "höheres event_id gewinnt, konvergent über 5 Permutationen" do
      older =
        event(
          "SpeakerAssigned",
          %{"session_id" => @sid, "speaker_label" => "S1", "discord_id" => "did-alt"},
          next_seq(),
          event_id: "e01"
        )

      newer =
        event(
          "SpeakerAssigned",
          %{"session_id" => @sid, "speaker_label" => "S1", "discord_id" => "did-neu"},
          next_seq(),
          event_id: "e02"
        )

      key = S.speaker_assignment_key(@sid, "S1")

      read = fn ->
        [row] = :mnesia.dirty_read(S.speaker_assignments(), key)
        # {tbl, key, session_id, speaker_label, discord_id, assigned_at} -> elem(4) = discord_id
        elem(row, 4)
      end

      for did <- materialize_permutations([older, newer], read) do
        assert did == "did-neu"
      end
    end

    test "Delete- (leere discord_id) und Write-Zweig teilen sich denselben Guard" do
      key = S.speaker_assignment_key(@sid, "S2")

      set_ev =
        event(
          "SpeakerAssigned",
          %{"session_id" => @sid, "speaker_label" => "S2", "discord_id" => "did-x"},
          next_seq(),
          event_id: "e01"
        )

      delete_ev =
        event(
          "SpeakerAssigned",
          %{"session_id" => @sid, "speaker_label" => "S2", "discord_id" => ""},
          next_seq(),
          event_id: "e02"
        )

      for r <-
            materialize_permutations([set_ev, delete_ev], fn ->
              :mnesia.dirty_read(S.speaker_assignments(), key)
            end) do
        assert r == [],
               "das neuere Delete-Event muss immer gewinnen (Row weg), war: #{inspect(r)}"
      end
    end
  end

  # ─── nil-event_id-Randfälle (direkt gegen Worker.Materializer.fold_supersedes?/4) ──

  describe "fold_supersedes?/4 — nil-event_id-Semantik" do
    # fold_supersedes?/4 + record_fold_winner!/4 laufen im Prod-Pfad IMMER
    # innerhalb der Materializer-Transaktion (materializer.ex:117/155) —
    # direkter Aufruf aus dem Test-Prozess braucht denselben Rahmen, sonst
    # {:aborted, :no_transaction}.
    test "nil vs. nil -> true (Legacy-Strom, ungeguardeter Last-Write-Wins)" do
      :mnesia.transaction(fn ->
        assert Materializer.fold_supersedes?(S.campaigns(), "row-x", :test_fold, nil)
        Materializer.record_fold_winner!(S.campaigns(), "row-x", :test_fold, nil)
        assert Materializer.fold_supersedes?(S.campaigns(), "row-x", :test_fold, nil)
      end)
    end

    test "nil vs. real -> false (event_id-loses Event clobbert eine reguläre Row nicht)" do
      :mnesia.transaction(fn ->
        Materializer.record_fold_winner!(S.campaigns(), "row-y", :test_fold, "e01")
        refute Materializer.fold_supersedes?(S.campaigns(), "row-y", :test_fold, nil)
      end)
    end

    test "real vs. nil -> true (erstes echtes Event gewinnt immer gegen 'noch kein Winner')" do
      :mnesia.transaction(fn ->
        assert Materializer.fold_supersedes?(S.campaigns(), "row-z", :test_fold, "e01")
      end)
    end
  end

  # ─── Migrations-Test: session_faithfulness_scores Backfill + Arity-Shrink ──

  describe "Migration: session_faithfulness_scores auf fold_meta konsolidiert" do
    test "Backfill übernimmt einen bestehenden event_id-Wert, danach ist die Spalte weg" do
      # Simuliert den Pre-#766-Zustand: Tabelle mit trailing event_id-Spalte
      # (7-Tupel), eine Row mit gesetztem event_id. Backfill muss den Wert nach
      # fold_meta kopieren, der Drop danach die Spalte entfernen.
      target_attrs = [:session_id, :campaign_id, :score, :claims_json, :scored_at, :event_id]

      {:atomic, :ok} =
        :mnesia.transform_table(
          S.session_faithfulness_scores(),
          fn
            {tbl, sid, cid, score, claims, ts} -> {tbl, sid, cid, score, claims, ts, nil}
            row -> row
          end,
          target_attrs
        )

      :mnesia.dirty_write(
        {S.session_faithfulness_scores(), "mig-sid", "mig-cid", 0.5, "[]", DateTime.utc_now(),
         "e-migrated"}
      )

      :ok = Worker.Schema.Migrations.FoldMeta.backfill_session_faithfulness_fold_meta!()
      :ok = Worker.Schema.Migrations.FoldMeta.migrate_session_faithfulness_drop_event_id!()

      assert :event_id not in :mnesia.table_info(S.session_faithfulness_scores(), :attributes)

      key = {S.session_faithfulness_scores(), "mig-sid", :session_faithfulness_scored}
      assert [{_, ^key, "e-migrated"}] = :mnesia.dirty_read(S.fold_meta(), key)
    end
  end
end
