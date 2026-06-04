defmodule Worker.UpdaterBootGuardTest do
  @moduledoc """
  Issue #500: Boot-Crash-Rollback. `boot_decision/3` ist die reine Entscheidungs-
  logik (rollback nach @rollback_threshold=2 erfolglosen Boots einer neuen SHA);
  `mark_boot_good/1` persistiert die bewährte SHA + resettet den Zähler.
  """
  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Repo
  alias Worker.Updater

  describe "boot_decision/3 (rein)" do
    test "unbestimmbare SHA → proceed, Zähler unangetastet" do
      assert Updater.boot_decision("unknown", "good1", {"good1", 5}) == {:proceed, {"good1", 5}}
    end

    test "keine Baseline (last_good nil) → proceed, Reset" do
      assert Updater.boot_decision("abc", nil, {"abc", 1}) == {:proceed, {nil, 0}}
    end

    test "läuft die bewährte SHA → proceed, Reset" do
      assert Updater.boot_decision("good1", "good1", {"good1", 1}) == {:proceed, {nil, 0}}
    end

    test "neue SHA, erster Versuch → proceed mit count=1" do
      assert Updater.boot_decision("new", "good1", {nil, 0}) == {:proceed, {"new", 1}}
    end

    test "neue SHA, anderer vorheriger attempt → count startet bei 1" do
      assert Updater.boot_decision("new", "good1", {"other", 9}) == {:proceed, {"new", 1}}
    end

    test "neue SHA, zweiter Versuch (n=2, == threshold) → proceed, noch kein Rollback" do
      assert Updater.boot_decision("new", "good1", {"new", 1}) == {:proceed, {"new", 2}}
    end

    test "neue SHA, dritter Versuch (n=3 > threshold) → ROLLBACK auf last_good" do
      assert Updater.boot_decision("new", "good1", {"new", 2}) == {:rollback, "good1"}
    end
  end

  describe "mark_boot_good/1" do
    setup do
      clear_all_tables!()
      # worker_state wird von clear_all_tables! NICHT geleert (hält Pairing/
      # Settings) → die Boot-Guard-Keys explizit zurücksetzen, sonst leaken sie
      # zwischen Tests.
      Repo.put_state(:last_good_sha, nil)
      Repo.put_state(:boot_attempt_sha, nil)
      Repo.put_state(:boot_attempt_count, 0)
      System.put_env("LORE_WORKER_AUTOUPDATE", "1")
      on_exit(fn -> System.delete_env("LORE_WORKER_AUTOUPDATE") end)
      :ok
    end

    test "setzt last_good_sha + resettet Boot-Versuchszähler" do
      Repo.put_state(:boot_attempt_sha, "new")
      Repo.put_state(:boot_attempt_count, 2)

      assert Updater.mark_boot_good("abc123") == :ok
      assert Repo.get_state(:last_good_sha) == "abc123"
      assert Repo.get_state(:boot_attempt_sha) == nil
      assert Repo.get_state(:boot_attempt_count) == 0
    end

    test "no-op für \"unknown\"" do
      assert Updater.mark_boot_good("unknown") == :ok
      assert Repo.get_state(:last_good_sha) == nil
    end

    test "no-op ohne Auto-Update" do
      System.delete_env("LORE_WORKER_AUTOUPDATE")
      assert Updater.mark_boot_good("abc123") == :ok
      assert Repo.get_state(:last_good_sha) == nil
    end
  end
end
