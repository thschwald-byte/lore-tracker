defmodule Worker.MaterializerMemberRolePromotedTest do
  @moduledoc """
  Issue #140 Phase B: `MemberRolePromoted`-Event updated die per-Campaign-
  Rolle eines bestehenden Members. Idempotent, akzeptiert beide Richtungen
  (Promote :spieler → :spielleiter, Demote :spielleiter → :spieler) und
  respektiert Tombstones (gelöschter Member wird nicht wiederbelebt).
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Materializer
  alias Worker.Schema.Builder
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-role-promote-test"
  @did "member-did"

  setup do
    clear_all_tables!()
    {:atomic, :ok} = :mnesia.clear_table(S.worker_state())

    mat_pid = ensure_materializer!()

    Builder.write_many!([
      Builder.campaign(@cid, name: "Test Campaign"),
      Builder.campaign_member(@cid, @did, role: :spieler, character_name: "Aragorn")
    ])

    on_exit(fn ->
      if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill)
    end)

    :ok
  end

  defp read_member do
    :mnesia.dirty_read(S.campaign_members(), S.member_key(@cid, @did))
  end

  test "promote :spieler → :spielleiter, andere Felder unverändert" do
    ev =
      event("MemberRolePromoted",
        %{
          "campaign_id" => @cid,
          "discord_id" => @did,
          "new_role" => "spielleiter",
          "promoted_by" => "gm-did"
        },
        100
      )

    assert {:applied, 100} = Materializer.apply_event(ev)

    [{_, _, _, did, role, _joined, character_name, deleted_at}] = read_member()
    assert did == @did
    assert role == :spielleiter
    assert character_name == "Aragorn"
    assert deleted_at == nil
  end

  test "demote :spielleiter → :spieler" do
    # Start als SL — über Builder, damit die Member-Arity zentral bleibt (#462).
    [{_, _key, cid, did, _role, joined, name, deleted}] = read_member()

    Builder.write!(
      Builder.campaign_member(cid, did,
        role: :spielleiter,
        joined_at: joined,
        character_name: name,
        deleted_at: deleted
      )
    )

    ev =
      event("MemberRolePromoted",
        %{
          "campaign_id" => @cid,
          "discord_id" => @did,
          "new_role" => "spieler",
          "promoted_by" => "gm-did"
        },
        110
      )

    assert {:applied, 110} = Materializer.apply_event(ev)

    [{_, _, _, _, role, _, _, _}] = read_member()
    assert role == :spieler
  end

  test "idempotent — gleicher new_role zweimal anwenden ist no-op" do
    ev1 =
      event("MemberRolePromoted",
        %{"campaign_id" => @cid, "discord_id" => @did, "new_role" => "spielleiter"},
        200
      )

    ev2 =
      event("MemberRolePromoted",
        %{"campaign_id" => @cid, "discord_id" => @did, "new_role" => "spielleiter"},
        201
      )

    Materializer.apply_event(ev1)
    Materializer.apply_event(ev2)

    [{_, _, _, _, role, _, _, _}] = read_member()
    assert role == :spielleiter
  end

  test "invalides new_role wird ignoriert, Row unverändert" do
    ev =
      event("MemberRolePromoted",
        %{"campaign_id" => @cid, "discord_id" => @did, "new_role" => "junk"},
        300
      )

    assert {:applied, 300} = Materializer.apply_event(ev)

    [{_, _, _, _, role, _, _, _}] = read_member()
    assert role == :spieler
  end

  test "unbekannter Member wird ignoriert" do
    ev =
      event("MemberRolePromoted",
        %{"campaign_id" => @cid, "discord_id" => "ghost-did", "new_role" => "spielleiter"},
        400
      )

    assert {:applied, 400} = Materializer.apply_event(ev)

    assert :mnesia.dirty_read(S.campaign_members(), S.member_key(@cid, "ghost-did")) == []
  end

  test "Tombstone bleibt erhalten — gelöschter Member wird nicht wiederbelebt" do
    ts = DateTime.utc_now()

    [{_, _key, cid, did, role, joined, name, _}] = read_member()

    Builder.write!(
      Builder.campaign_member(cid, did,
        role: role,
        joined_at: joined,
        character_name: name,
        deleted_at: ts
      )
    )

    ev =
      event("MemberRolePromoted",
        %{"campaign_id" => @cid, "discord_id" => @did, "new_role" => "spielleiter"},
        500
      )

    assert {:applied, 500} = Materializer.apply_event(ev)

    [{_, _, _, _, _, _, _, deleted_at}] = read_member()
    assert deleted_at == ts, "Tombstone darf nicht durch MemberRolePromoted überschrieben werden"
  end
end
