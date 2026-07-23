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
end
