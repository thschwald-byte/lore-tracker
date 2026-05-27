# Probelauf-Eval Goldstandard-Asset

Issue #201: Stage-Isolation mit Goldstandard-Pre-Seed für fairen Stage-N-Modell-Vergleich.

## Struktur

Vier Eval-Sessions mit ansteigender Länge (10/30/100/~800 Utterances), pro Session je ein Stage-Output als Goldstandard:

```
session-{2,3}-summary.md           — Stage-2-Goldstandard (Resümee, Markdown)
session-{2,3}-epos.md              — Stage-3-Goldstandard (Epos-Kapitel, Markdown)
session-{2,3}-chronik.json         — Stage-4-Goldstandard (Chronik-Einträge, JSON-Array)
session-4-utterances.jsonl         — Quell-Utterances Session 4 (eine JSON pro Zeile)
session-{1,2,3,4}-summary.md       — Stage-2-Goldstandard pro Session
session-{1,2,3,4}-epos.md          — Stage-3-Goldstandard pro Session
session-{1,2,3,4}-chronik.json     — Stage-4-Goldstandard pro Session
```

Session 1-3: Utterances hardcoded in `Worker.Probelauf.short_utterances/0` + `medium_utterances/0` + `long_utterances/0` (10 / 30 / 100 utts). Session 4 ist die Real-Size-Eval (Issue #286): „Walden Hollow 1925", ~800 Whisper-anmutende Utterances (Ø 30-40c) einer kompletten CoC-Investigations-Session, geladen aus `session-4-utterances.jsonl`. Diese vierte Größe wird im Sweep-Picker als „real" angeboten und liegt **zusätzlich** als wiederverwendbare Test-Stage-Kampagne via `mix lore.seed.walden_hollow` bereit.

## Verwendung

`Worker.Probelauf.seed_eval_campaign/0` lädt diese Files und publisht entsprechende Events in eine Probelauf-Eval-Kampagne. `Pipeline.run_for_session/2` mit `only_stages: [N]` läuft dann nur die Ziel-Stage und vergleicht den Output gegen den Goldstandard via `Worker.LLM.Faithfulness`.

## Curation-Workflow

Initial-Inhalte wurden manuell aus den hardcoded `short_utterances`/`medium_utterances`/`long_utterances`-Funktionen in `Worker.Probelauf` kuratiert. **Pflege-Workflow**:

1. Wenn ein neueres / besseres Modell zur Verfügung steht: einmaliger Run mit
   ```
   mix lore.probelauf.eval_seed_regenerate --model qwen3:30b-a3b
   ```
   (Folge-Issue — Mix-Task noch nicht implementiert.)
2. Tom reviewt die generierten Outputs, korrigiert offensichtliche Fehler.
3. Files committen.

## Lizenz

Inhalte sind kurze fiktive RPG-Szenen — keine externe Vorlage, CC0-äquivalent.
