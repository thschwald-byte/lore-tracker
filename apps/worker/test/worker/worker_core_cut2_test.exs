defmodule Worker.WorkerCoreCut2Test do
  @moduledoc """
  Issue #475 Cut 2: (Item 2) Daten-Migrationen hinter One-Shot-Flags statt
  Full-Table-Scan bei jedem Boot; (Item 3) :pending-Publish-Counter.
  """
  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Repo

  describe "Item 2: One-Shot-Migrations-Gate" do
    test "Flags gesetzt nach bootstrap + bootstrap bleibt idempotent (kein Re-Scan-Crash)" do
      # Erster bootstrap (im Test-Setup eh gelaufen) hat die Gate-Flags gesetzt.
      assert :ok = Worker.Schema.Mnesia.bootstrap!()
      assert Repo.get_state(:migrated_member_role_rename) == true
      assert Repo.get_state(:repaired_swapped_created_at_flavors) == true

      # Wiederholter bootstrap greift aufs Flag → kein Crash, kein erneuter Scan.
      assert :ok = Worker.Schema.Mnesia.bootstrap!()
    end
  end

  describe "Item 3: :pending-Publish-Counter" do
    setup do
      clear_all_tables!()
      Repo.put_state(:pending_publish_count, 0)
      :ok
    end

    test "bump_pending_publish_count/0 zählt monoton hoch + ist abfragbar" do
      assert 1 = Repo.bump_pending_publish_count()
      assert 2 = Repo.bump_pending_publish_count()
      assert 3 = Repo.bump_pending_publish_count()
      assert Repo.get_state(:pending_publish_count) == 3
    end

    test "startet bei 1 wenn der Key noch gar nicht existiert" do
      Repo.put_state(:pending_publish_count, nil)
      assert 1 = Repo.bump_pending_publish_count()
    end
  end
end
