# Issue #544 — Credo-Decision-Gate-Spike.
#
# Bewusst MINIMAL: läuft NUR den einen AST-Custom-Check, um das Modell zu
# beweisen (AST winkt async-gewrappte Reader.read sauber durch), ohne die
# God-Modul-Default-Check-Lawine. Die Default-Checks + `credo diff`-Scope
# kommen in den Folge-Cuts (#544 Plan, Cut 1/2/4).
#
# `requires:` lädt den Custom-Check ohne App-Compile → kein `use Credo.Check`
# im Prod-Release-Pfad (credo ist nur dev/test-Dep).
%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["apps/*/lib/**/*.ex"],
        excluded: []
      },
      requires: [
        "tools/credo/sync_reader_in_mount.ex",
        "tools/credo/unsupervised_task_start.ex",
        "tools/credo/hardcoded_event_kind.ex",
        "tools/credo/timer_without_cleanup.ex",
        "tools/credo/ignored_intents_publish.ex",
        "tools/credo/module_too_long.ex"
      ],
      strict: true,
      checks: [
        {LoreTracker.Credo.Check.SyncReaderInMount, []},
        {LoreTracker.Credo.Check.UnsupervisedTaskStart, []},
        {LoreTracker.Credo.Check.HardcodedEventKind, []},
        {LoreTracker.Credo.Check.TimerWithoutCleanup, []},
        {LoreTracker.Credo.Check.IgnoredIntentsPublish, []},
        {LoreTracker.Credo.Check.ModuleTooLong, []}
      ]
    }
  ]
}
