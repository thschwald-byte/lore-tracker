defmodule Worker.MaterializerDVarianteConvergenceTest do
  @moduledoc """
  Issue #896 (I7-Bucket-D-Variante): Existenz-LWW für Delete↔legitime-Wiederkehr.
  „Existenz" (`deleted_at` bzw. Row-Präsenz) ist ein event_id-LWW-Feld, das ein
  Delete-Kind und ein Re-Add-Kind beide schreiben — muss order-insensitiv
  konvergieren, ohne die legitime Wiederkehr (Rejoin/Re-Login) zu brechen.

  Members + Users(users-Row): symmetrische `fold_meta`-LWW. Users create-seitig:
  `{:user,did}`-Tombstone als Inline-Check im Member-Helper. Utterances:
  `{:utterance,id}`-Watermark via zentralem Gate.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Materializer
  alias Worker.Schema.Builder
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-dvar-896"
  @did "did-1"

  setup do
    reset_for_permutation!()
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
    :ok
  end

  defp next_seq, do: System.unique_integer([:positive, :monotonic])

  # Alle Permutationen einer (kleinen) Event-Liste.
  defp permutations([]), do: [[]]
  defp permutations(list), do: for(x <- list, rest <- permutations(list -- [x]), do: [x | rest])

  # Reset + Campaign seeden (AdminMemberAdded braucht die campaigns-Row) + Order
  # applien + lesen. Ersetzt materialize_permutations, das keinen Seed zwischen
  # Reset und Apply erlaubt.
  defp converge(orderings, read_fn) do
    for order <- orderings do
      reset_for_permutation!()
      Builder.write!(Builder.campaign(@cid, name: "C"))
      Enum.each(order, &Materializer.apply_event/1)
      read_fn.()
    end
  end

  defp admin_add(event_id, did \\ @did) do
    event(
      "AdminMemberAdded",
      %{"campaign_id" => @cid, "discord_id" => did, "display_name" => "D"},
      next_seq(),
      event_id: event_id
    )
  end

  defp member_removed(event_id, did \\ @did) do
    event("MemberRemoved", %{"campaign_id" => @cid, "discord_id" => did}, next_seq(),
      event_id: event_id
    )
  end

  defp promote(event_id, role) do
    event(
      "MemberRolePromoted",
      %{"campaign_id" => @cid, "discord_id" => @did, "new_role" => role},
      next_seq(),
      event_id: event_id
    )
  end

  # {:present, role} | :removed (soft-gelöscht) | :absent — :removed und :absent
  # sind beide „nicht sichtbar" (Reader filtern deleted_at != nil).
  defp member_state(did \\ @did) do
    case :mnesia.dirty_read(S.campaign_members(), S.member_key(@cid, did)) do
      [{_, _, _, _, role, _, _, nil}] -> {:present, role}
      [{_, _, _, _, _, _, _, _del}] -> :removed
      [] -> :absent
    end
  end

  defp visible?(state), do: match?({:present, _}, state)

  test "add-before-remove: entfernt über beide Ordnungen" do
    for s <- converge(permutations([admin_add("e05"), member_removed("e09")]), &member_state/0),
        do: refute(visible?(s), "war: #{inspect(s)}")
  end

  test "legit-return (remove-before-add): present über beide Ordnungen" do
    for s <- converge(permutations([member_removed("e05"), admin_add("e09")]), &member_state/0),
        do: assert(visible?(s), "Rejoin (add e9 > rem e5) muss present sein, war: #{inspect(s)}")
  end

  test "stale-delete-replay: [add e9, rem e5] → present (remove verliert)" do
    for s <- converge(permutations([admin_add("e09"), member_removed("e05")]), &member_state/0),
        do:
          assert(
            visible?(s),
            "Stale-remove e5 vs. add e9 darf nicht entfernen, war: #{inspect(s)}"
          )
  end

  test "mid-insert [rem e5, add e9, rem e7] → present (alle 6 Permutationen)" do
    events = [member_removed("e05"), admin_add("e09"), member_removed("e07")]

    for s <- converge(permutations(events), &member_state/0),
        do: assert(visible?(s), "add e9 ist der neueste Existenz-Writer, war: #{inspect(s)}")
  end

  test "remove-on-never-existed + stale add → absent/nicht sichtbar (H4)" do
    # remove e9 legt KEINE Row an, recordet aber :membership=e9; stale add e5 verliert.
    for s <- converge(permutations([member_removed("e09"), admin_add("e05")]), &member_state/0),
        do:
          refute(
            visible?(s),
            "Stale add e5 < :membership=e9 darf nicht resurrecten, war: #{inspect(s)}"
          )
  end

  test "role-Kollision (H3): Rejoin resettet auf :spieler (add e9 > promote e3)" do
    # Explizite Add-vor-Promote-Orderings (man promotet keinen Nicht-Member;
    # promote-vor-add-Divergenz ist pre-existing, s. #766-Tracking).
    orderings = [
      [admin_add("e01"), promote("e03", "spielleiter"), member_removed("e05"), admin_add("e09")],
      [admin_add("e01"), member_removed("e05"), admin_add("e09"), promote("e03", "spielleiter")]
    ]

    for order <- orderings do
      reset_for_permutation!()
      Builder.write!(Builder.campaign(@cid, name: "C"))
      Enum.each(order, &Materializer.apply_event/1)

      assert member_state() == {:present, :spieler},
             "Rejoin (add e9) muss role auf :spieler resetten (promote e3 < e9), war: #{inspect(member_state())}"
    end
  end

  test "role-Kollision Gegenprobe: Promote NACH Rejoin gewinnt (:spielleiter)" do
    orderings =
      permutations([
        admin_add("e01"),
        member_removed("e05"),
        admin_add("e09"),
        promote("e11", "spielleiter")
      ])
      # nur Orderings, in denen promote e11 nach seinem add e9 kommt (kausal-real)
      |> Enum.filter(fn o -> idx(o, "e09") < idx(o, "e11") end)

    for order <- orderings do
      reset_for_permutation!()
      Builder.write!(Builder.campaign(@cid, name: "C"))
      Enum.each(order, &Materializer.apply_event/1)

      assert member_state() == {:present, :spielleiter},
             "Promote e11 > Rejoin e9 muss :spielleiter gewinnen, war: #{inspect(member_state())}"
    end
  end

  defp idx(order, event_id), do: Enum.find_index(order, &(&1["event_id"] == event_id))

  test "Doppel-Zustellung ist idempotent (strict-> : gleiche event_id supersedet nicht)" do
    # add e5 zweimal → present; rem e9 zweimal → nicht sichtbar. Re-Apply = No-op.
    reset_for_permutation!()
    Builder.write!(Builder.campaign(@cid, name: "C"))
    Enum.each([admin_add("e05"), admin_add("e05")], &Materializer.apply_event/1)
    assert member_state() == {:present, :spieler}

    Enum.each([member_removed("e09"), member_removed("e09")], &Materializer.apply_event/1)
    refute visible?(member_state())
  end

  test "nil-event_id (Legacy) crasht nicht, degradiert zum Alt-Verhalten" do
    reset_for_permutation!()
    Builder.write!(Builder.campaign(@cid, name: "C"))
    # Events OHNE event_id (kein :event_id-Opt) → fold_supersedes?(nil) No-op-Semantik.
    add = event("AdminMemberAdded", %{"campaign_id" => @cid, "discord_id" => @did}, next_seq())
    rem = event("MemberRemoved", %{"campaign_id" => @cid, "discord_id" => @did}, next_seq())

    assert :ok = (fn -> Materializer.apply_event(add) end).() && :ok
    Materializer.apply_event(rem)
    # Kein Crash; Alt-Verhalten (nil supersedet nichts → Fold bleibt leer, letzter
    # Row-Write gewinnt): add dann rem → removed.
    refute visible?(member_state())
  end

  # ── Users (Commit 2): {:user,did}-Tombstone + :user_existence-Fold ─────────

  defp user_upserted(event_id, did \\ @did) do
    event("UserUpserted", %{"discord_id" => did, "display_name" => "U"}, next_seq(),
      event_id: event_id
    )
  end

  defp user_deleted(event_id, did \\ @did) do
    event("UserDeleted", %{"discord_id" => did}, next_seq(), event_id: event_id)
  end

  defp user_present?(did \\ @did), do: :mnesia.dirty_read(S.users(), did) != []

  test "user: upsert-before-delete → absent; legit-return delete-before-upsert → present" do
    for u <-
          materialize_permutations([user_upserted("e05"), user_deleted("e09")], &user_present?/0),
        do: refute(u, "upsert e5 < delete e9 → User absent")

    for u <-
          materialize_permutations([user_deleted("e05"), user_upserted("e09")], &user_present?/0),
        do: assert(u, "Re-Login (upsert e9 > delete e5) → User present (H2)")
  end

  test "user mid-insert [del e5, ups e9, del e7] → present (alle 6 Permutationen)" do
    events = [user_deleted("e05"), user_upserted("e09"), user_deleted("e07")]

    for u <- materialize_permutations(events, &user_present?/0),
        do: assert(u, "ups e9 ist der neueste Existenz-Writer → present")
  end

  test "3-Event-Revive-Interleave [add, del, ups]: User present, Member nicht sichtbar" do
    # add e5 (member+user), del e9 (user weg + member-fanout + {:user}-tombstone),
    # ups e11 (user revive). Member bleibt unsichtbar (H1: tombstone-Inline-Check).
    events = [admin_add("e05"), user_deleted("e09"), user_upserted("e11")]

    for {u, m} <-
          converge(permutations(events), fn -> {user_present?(), member_state()} end) do
      assert u, "ups e11 > del e9 → User present"

      refute visible?(m),
             "Member bleibt nach UserDelete unsichtbar (kein Revive über den User), war: #{inspect(m)}"
    end
  end

  test "3-Event-Interleave [del, ups, add]: beide present, Member live" do
    events = [user_deleted("e05"), user_upserted("e09"), admin_add("e11")]

    for {u, m} <-
          converge(permutations(events), fn -> {user_present?(), member_state()} end) do
      assert u, "User present (ups e9 > del e5)"
      assert visible?(m), "add e11 > {:user}-tombstone e5 → Member live, war: #{inspect(m)}"
    end
  end

  test "Fan-out-never-existed [UserDeleted e9, AdminMemberAdded e5] → User absent UND Member absent (H1)" do
    events = [user_deleted("e09"), admin_add("e05")]

    for {u, m} <-
          converge(permutations(events), fn -> {user_present?(), member_state()} end) do
      refute u, "User bleibt gelöscht"

      refute visible?(m),
             "add e5 < {:user}-tombstone e9 → Member wird inline gegated, war: #{inspect(m)}"
    end
  end

  test "Invite-Multi-Effect: [InviteRedeemed e5, UserDeleted e9] → :invite_status redeemed in BEIDEN Ordnungen" do
    token = "tok-896"

    seed = fn ->
      Builder.write!(Builder.campaign(@cid, name: "C"))

      Builder.write!(
        Builder.campaign_invite(token, @cid, created_by_discord_id: "creator", created_at: nil)
      )
    end

    redeem =
      event("InviteRedeemed", %{"token" => token, "discord_id" => @did}, next_seq(),
        event_id: "e05"
      )

    del = user_deleted("e09")

    for order <- [[redeem, del], [del, redeem]] do
      reset_for_permutation!()
      seed.()
      Enum.each(order, &Materializer.apply_event/1)

      # campaign_invites: {tbl, token, cid, created_by, created_at, expires_at, status(6), redeemed_by}
      status = :mnesia.dirty_read(S.campaign_invites(), token) |> hd() |> elem(6)

      assert status == :redeemed,
             "Der Inline-Check skippt NUR den Member-Write, nicht das :invite_status-Fold — war: #{inspect(status)}, Order: #{inspect(Enum.map(order, & &1["event_id"]))}"
    end
  end

  # ── Utterances (Commit 3): {:utterance,id}-Watermark via zentralem Gate ────

  @uid "utt-1"
  @sid "sess-896"

  defp utt_appended(event_id, opts \\ []) do
    event(
      "UtteranceAppended",
      %{
        "id" => @uid,
        "session_id" => @sid,
        "campaign_id" => @cid,
        "discord_id" => "u",
        "text" => Keyword.get(opts, :text, "hi"),
        "status" => Keyword.get(opts, :status, "confirmed")
      },
      next_seq(),
      event_id: event_id
    )
  end

  defp utt_deleted(event_id) do
    event("UtteranceDeleted", %{"id" => @uid}, next_seq(), event_id: event_id)
  end

  defp utt_edited(event_id, new_text) do
    event("UtteranceEdited", %{"id" => @uid, "new_text" => new_text}, next_seq(),
      event_id: event_id
    )
  end

  # {:present, text} | :deleted (deleted_at gesetzt) | :absent
  defp utt_state do
    case :mnesia.dirty_read(S.utterances(), @uid) do
      [{_, _, _, _, _, text, _, _, nil}] -> {:present, text}
      [{_, _, _, _, _, _, _, _, _del}] -> :deleted
      [] -> :absent
    end
  end

  defp utt_visible?, do: match?({:present, _}, utt_state())

  test "utterance: [app e5, del e9] und [del e9, app e5] → beide nicht sichtbar" do
    for order <- permutations([utt_appended("e05"), utt_deleted("e09")]) do
      reset_for_permutation!()
      Enum.each(order, &Materializer.apply_event/1)
      refute utt_visible?(), "war: #{inspect(utt_state())}"
    end
  end

  test "utterance stale-edit [app e1, del e9, edit e5] → gelöscht bleibt (Edit gegated)" do
    for order <- permutations([utt_appended("e01"), utt_deleted("e09"), utt_edited("e05", "X")]) do
      reset_for_permutation!()
      Enum.each(order, &Materializer.apply_event/1)

      refute utt_visible?(),
             "Stale-Edit e5 < Tombstone e9 darf nicht resurrecten, war: #{inspect(utt_state())}"
    end
  end

  test "utterance newer-edit [app e1, del e9, edit e11] → Edit läuft, deleted_at erhalten → versteckt" do
    for order <- permutations([utt_appended("e01"), utt_deleted("e09"), utt_edited("e11", "X")]) do
      reset_for_permutation!()
      Enum.each(order, &Materializer.apply_event/1)

      refute utt_visible?(),
             "Ein neuerer Edit hebt das deleted_at nicht auf, war: #{inspect(utt_state())}"
    end
  end

  test "utterance baseline (kein Delete) [app e1, edit e5] → sichtbar, editiert" do
    reset_for_permutation!()
    Enum.each([utt_appended("e01"), utt_edited("e05", "NEU")], &Materializer.apply_event/1)
    assert {:present, "NEU"} = utt_state()
  end
end
