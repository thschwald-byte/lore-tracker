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
      requires: ["tools/credo/sync_reader_in_mount.ex"],
      strict: true,
      checks: [
        {LoreTracker.Credo.Check.SyncReaderInMount, []}
      ]
    }
  ]
}
