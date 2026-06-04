defmodule Mix.Tasks.Lore.AuditTest do
  @moduledoc """
  Issue #535: Tests für die Mix-Task `mix lore.audit`.

  Da die Task gegen das LIVE-Repo scannt (Path.wildcard auf `apps/**`),
  testen wir das Diff-Verhalten via temp-Baseline-Files + Scope-Helper,
  und das Pattern-Erkennen separat via direkten Funktionsaufruf in einer
  Test-Sandbox.

  Die Mix-Task selbst hat keinen `inject`-Mechanismus für das Working
  Directory — pragmatisch: wir testen das Format der Output-Helper +
  die Pattern-Regex'es indirekt über das Scan-Helper.
  """

  use ExUnit.Case, async: true

  alias Mix.Tasks.Lore.Audit

  describe "Anti-Pattern-Erkennung (Smoke-Tests gegen Live-Repo)" do
    # `mix test` cd't pro umbrella-App auf das App-Verzeichnis. Mix-Task
    # rennt aber gegen Path.wildcard("apps/**") — also vom Umbrella-Root.
    # Im Test cd'en wir explizit auf den Umbrella-Root und restoren danach.
    setup do
      original = File.cwd!()
      # __DIR__ = apps/shared/test/mix/tasks → 5 levels hoch zum Repo-Root
      umbrella_root = Path.expand("../../../../..", __DIR__)
      File.cd!(umbrella_root)
      on_exit(fn -> File.cd!(original) end)
      :ok
    end

    test "collect_all_findings/0 returnt Liste von %{check, file, line, snippet}" do
      findings = Audit.collect_all_findings()

      assert is_list(findings)
      assert findings != [], "Repo sollte mindestens den existing-Drift enthalten (Baseline 97)"

      # Schema-Check pro Finding
      Enum.each(findings, fn f ->
        assert is_atom(f.check)
        assert is_binary(f.file)
        assert is_integer(f.line) and f.line > 0
        assert is_binary(f.snippet)

        assert f.check in [
                 :unsupervised_task_start,
                 :sync_reader_in_mount,
                 :hardcoded_event_kind,
                 :timer_without_cleanup,
                 :ignored_intents_publish
               ]
      end)
    end

    test "alle Checks liefern mindestens ein Finding (Baseline-Sanity)" do
      findings = Audit.collect_all_findings()
      by_check = Enum.group_by(findings, & &1.check)

      # Mindestens ein Finding pro Check — der Repo hat heute bekannten
      # Drift in jedem der fünf Pattern. Wenn ein Check 0 liefert, ist
      # der Regex vermutlich kaputt.
      for check <- [
            :unsupervised_task_start,
            :sync_reader_in_mount,
            :hardcoded_event_kind,
            :timer_without_cleanup,
            :ignored_intents_publish
          ] do
        assert by_check[check] != nil and by_check[check] != [],
               "Check #{check} liefert 0 Findings — Regex vermutlich kaputt"
      end
    end
  end

  describe "Baseline-Diff" do
    test "finding_key/1 ist line-stabil (nur check + file + snippet)" do
      f1 = %{check: :foo, file: "x.ex", line: 100, snippet: "Task.start(fn -> :ok end)"}
      f2 = %{check: :foo, file: "x.ex", line: 200, snippet: "Task.start(fn -> :ok end)"}

      assert Audit.finding_key(f1) == Audit.finding_key(f2)
    end

    test "finding_key/1 unterscheidet check + file + snippet" do
      a = %{check: :foo, file: "x.ex", line: 1, snippet: "A"}
      b = %{check: :foo, file: "x.ex", line: 1, snippet: "B"}
      c = %{check: :foo, file: "y.ex", line: 1, snippet: "A"}
      d = %{check: :bar, file: "x.ex", line: 1, snippet: "A"}

      keys = Enum.map([a, b, c, d], &Audit.finding_key(&1))
      assert length(Enum.uniq(keys)) == 4
    end
  end
end
