defmodule Worker.MaterializerUserRoleSetTest do
  @moduledoc """
  Issue #646: UserRoleSet mappt role-Strings auf Atome OHNE String.to_existing_atom.

  Der frühere `to_existing_atom`-Pfad crashte auf einem frischen Worker-BEAM beim
  ersten UserRoleSet mit role="admin" (Atom :admin noch nicht interniert →
  :badarg → Mnesia-Abort → Materializer-Crash). Der Timing-Crash selbst ist im
  Test-Suite-BEAM nicht reproduzierbar (andere Tests internieren :admin längst);
  dieser Test sichert die korrekte Mapping-Semantik + den Unknown-Role-Drop ab,
  und das explizite Mapping (statt to_existing_atom) eliminiert die Lade-
  Reihenfolge-Abhängigkeit strukturell.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Materializer
  alias Worker.Schema.Mnesia, as: S

  @did "role-set-test-did"

  setup do
    clear_all_tables!()
    {:atomic, :ok} = :mnesia.clear_table(S.worker_state())

    mat_pid = ensure_materializer!()

    on_exit(fn ->
      if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill)
    end)

    :ok
  end

  for {role_str, role_atom} <- [
        {"admin", :admin},
        {"spielleiter", :spielleiter},
        {"spieler", :spieler}
      ] do
    test "role=#{role_str} → #{inspect(role_atom)} (kein to_existing_atom-Crash)" do
      ev = event("UserRoleSet", %{"discord_id" => @did, "role" => unquote(role_str)}, 100)

      assert {:applied, 100} = Materializer.apply_event(ev)

      [{_, did, _name, _joined, _avatar, role, _cap}] = :mnesia.dirty_read(S.users(), @did)
      assert did == @did
      assert role == unquote(role_atom)
    end
  end

  test "unbekannte Rolle wird verworfen, kein user-row" do
    ev = event("UserRoleSet", %{"discord_id" => @did, "role" => "großmeister"}, 200)

    assert {:applied, 200} = Materializer.apply_event(ev)
    assert :mnesia.dirty_read(S.users(), @did) == []
  end
end
