<!--
Codeberg PR-Template für lore-tracker (Issue #536).

Die Akzeptanz-Checkliste unten ist die Ergänzung zur Definition-of-Done in
CONTRIBUTING.md. Bitte HAKEN setzen (`[x]`) statt Items zu löschen — wenn
ein Punkt nicht anwendbar ist, "n/a" daneben schreiben.
-->

## Summary

<!-- 1-3 Sätze: was ändert sich und warum. -->

Closes #<!-- Issue-Nummer -->

## Akzeptanz-Checkliste

- [ ] `mix format` ist gelaufen
- [ ] `mix compile --warnings-as-errors` clean
- [ ] `mix credo` ohne neue Findings für die geänderten Dateien (AST-Linter gegen die Anti-Pattern-Klassen, Issue #544)
- [ ] `mix test` grün — bei neuer Funktionalität: relevante Tests **im selben PR** mit-geliefert
- [ ] Doku-Drift gefixt (CLAUDE.md / README.md / docs/ / @moduledoc) — siehe CONTRIBUTING.md "Definition of Done"

## Spezifische Risiko-Checks

Wenn dein PR einen der folgenden Punkte berührt, bestätige explizit:

- [ ] **Neuer `handle_event` im LV** → dedizierter Bare-Socket-Test im `*_live_test.exs` (Pattern: `mic_live_test.exs`)
- [ ] **Neue `apply_kind/4`-Klausel in `Worker.Materializer`** → dedizierter Test in `apps/worker/test/worker/materializer_*_test.exs`
- [ ] **Neuer Event-Kind** → in `Shared.Events.all()` deklariert UND Materializer-Handler ODER expliziter no-op-Handler
- [ ] **Neuer `Task.start/1`** → kommentiert WARUM fire-and-forget OK ist (typisch: try/rescue im Body, oder Task.Supervisor.start_child)
- [ ] **Neuer sync Worker-Roundtrip im LV** → benutzt `assign_async/start_async/handle_async` statt `mount`-blockierender Calls
- [ ] **Neuer Cloud-Backend** → folgt `Worker.LLM.CloudHelper`-Pattern (Issue #463)
- [ ] **Neue `Process.send_after`** → Timer-Ref in assigns + Cancel im `terminate/2`-Pfad
- [ ] **Permissions / Auth-Pfad geändert** → explizit im PR-Body benannt, Side-Effect-Path hat `HubWeb.Permissions.can?/3`-Check

## Test plan

<!--
Bullet-Liste: wie wurde verifiziert. Mindestens:
- mix test (welche Suite)
- ggf. PR-Test (mix lore.pr_test.spawn auf Port X) wenn UI-Wirkung
- ggf. Browser-Verifikation bei JS-Änderungen
-->

## Folge

<!--
Welche Issues bleiben offen / sind als Folge-Cut geplant. Bei stacked PRs:
welcher PR muss vorher mergen.
-->
