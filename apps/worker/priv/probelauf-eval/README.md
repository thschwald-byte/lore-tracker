# Probelauf-Eval Goldstandard-Asset

Issue #201: Stage-Isolation mit Goldstandard-Pre-Seed für fairen Stage-N-Modell-Vergleich.

## Struktur

Drei Eval-Sessions mit ansteigender Länge (10/30/100 Utterances), pro Session je ein Stage-Output als Goldstandard:

```
session-{1,2,3}-utterances.jsonl       — Quell-Utterances (eine JSON pro Zeile)
session-{1,2,3}-summary.md             — Stage-2-Goldstandard (Resümee, Markdown)
session-{1,2,3}-epos.md                — Stage-3-Goldstandard (Epos-Kapitel, Markdown)
session-{1,2,3}-chronik.json           — Stage-4-Goldstandard (Chronik-Einträge, JSON-Array)
```

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
