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
        "tools/credo/module_too_long.ex",
        "tools/credo/raw_event_bridge_publish.ex",
        "tools/credo/unescaped_markdown_render.ex"
      ],
      strict: true,
      checks: [
        {LoreTracker.Credo.Check.SyncReaderInMount, []},
        {LoreTracker.Credo.Check.UnsupervisedTaskStart, []},
        {LoreTracker.Credo.Check.HardcodedEventKind, []},
        {LoreTracker.Credo.Check.TimerWithoutCleanup, []},
        {LoreTracker.Credo.Check.IgnoredIntentsPublish, []},
        # Issue #1097: der Check zählt CODE-Zeilen (Doku/Kommentare/Leerzeilen
        # zählen nicht mit — die Doku-Dichte dieses Projekts ist Absicht).
        # Grenze 600. Die vier Bestandsdateien darunter halten ihren heutigen
        # Stand als RATSCHE: sie dürfen nicht wachsen, aber sie blockieren die
        # CI auch nicht. Wächst eine um eine Zeile, wird der Check rot; sinkt
        # sie unter 600, greift wieder die reguläre Grenze und der Eintrag hier
        # kann ersatzlos weg. Der Schnitt dieser vier ist eigene Arbeit — er
        # gehört an einen Tisch, nicht zwischen zwei Feature-Hunks (das ist der
        # Anlass von #1097).
        {LoreTracker.Credo.Check.ModuleTooLong,
         [
           bestand: [
             # Issue #1062: 775 → 732. Der Wartezeiten-Block brauchte hier eine
             # Einhänge-Zeile, die Datei stand aber genau auf ihrem Ratschen-
             # Wert. Statt die Zeile zu verstecken oder die Ratsche anzuheben
             # ist der Debug-Zugriffs-Block (#144) herausgewandert — er hatte
             # mit Settings ohnehin nichts zu tun. Die Ratsche zieht damit
             # nach unten nach, wie es die Regel verlangt.
             {"apps/hub/lib/hub_web/live/einstellungen_live.ex", 732},
             # Issue #1122: 691 → 690. Die Stufen-Whitelist im Status-Stream ist
             # ersatzlos entfallen (gefiltert wird beim Lesen, gegen
             # Shared.PipelineStufen) — die Ratsche zieht nach unten nach.
             {"apps/hub/lib/hub_web/live/dashboard_live.ex", 690},
             {"apps/worker/lib/worker/repo/artifacts.ex", 611},
             {"apps/worker/lib/worker/repo/snapshots.ex", 602}
           ]
         ]},
        {LoreTracker.Credo.Check.RawEventBridgePublish, []},
        {LoreTracker.Credo.Check.UnescapedMarkdownRender, []}
      ]
    }
  ]
}
