defmodule Worker.MaterializerUserRoleTest do
  @moduledoc """
  Issue #34: `UserRoleSet`-Event setzt globale Rolle eines Users.
  Whitelist gegen admin/spielleiter/spieler; sonst Drop.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Materializer
  alias Worker.Schema.Builder
  alias Worker.Schema.Mnesia, as: S

  @did "user-role-test-did"

  setup do
    clear_all_tables!()
    {:atomic, :ok} = :mnesia.clear_table(S.worker_state())

    mat_pid = ensure_materializer!()

    Builder.write!(Builder.user(@did, display_name: "Test User", role: :spieler))

    on_exit(fn ->
      if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill)
    end)

    :ok
  end

  defp role_of(did) do
    case :mnesia.dirty_read(S.users(), did) do
      [{_, _, _, _, _, role}] -> role
      [] -> nil
    end
  end

  test "promoviert :spieler zu :admin" do
    assert role_of(@did) == :spieler

    ev =
      event(
        "UserRoleSet",
        %{"discord_id" => @did, "role" => "admin", "set_by" => "test"},
        100
      )

    assert {:applied, 100} = Materializer.apply_event(ev)

    assert role_of(@did) == :admin
  end

  test "downgrade :admin zurück zu :spielleiter" do
    Materializer.apply_event(
      event("UserRoleSet", %{"discord_id" => @did, "role" => "admin"}, 200)
    )

    assert role_of(@did) == :admin

    Materializer.apply_event(
      event("UserRoleSet", %{"discord_id" => @did, "role" => "spielleiter"}, 201)
    )

    assert role_of(@did) == :spielleiter
  end

  test "unbekannte Rolle wird gedroppt, keine Mutation" do
    ev = event("UserRoleSet", %{"discord_id" => @did, "role" => "superuser"}, 300)
    assert {:applied, 300} = Materializer.apply_event(ev)

    assert role_of(@did) == :spieler
  end

  test "Role-Set für noch nicht existierenden User legt User-Row an" do
    new_did = "fresh-did"
    assert role_of(new_did) == nil

    ev = event("UserRoleSet", %{"discord_id" => new_did, "role" => "admin"}, 400)
    assert {:applied, 400} = Materializer.apply_event(ev)

    assert role_of(new_did) == :admin
  end

  test "display_name + avatar bleiben bei Role-Change unverändert" do
    [{_, _, name_before, _, avatar_before, _}] = :mnesia.dirty_read(S.users(), @did)

    Materializer.apply_event(
      event("UserRoleSet", %{"discord_id" => @did, "role" => "admin"}, 500)
    )

    [{_, _, name_after, _, avatar_after, _}] = :mnesia.dirty_read(S.users(), @did)
    assert name_after == name_before
    assert avatar_after == avatar_before
  end
end
