# Probelauf-Eval-Asset

Seit #786 (Chain-Rückbau) liegt hier nur noch **eine** Datei:

```
session-4-utterances.jsonl   — Quell-Utterances der „real"-Eval-Session (eine JSON pro Zeile)
```

Die Real-Size-Eval-Session (Issue #286): „Corbett House — Boston 1925", ~840 Whisper-anmutende Utterances (5 Sprecher: sl/laurent/flaw/oreilly/crawford, Ø ~35c) einer kompletten CoC-Investigations-Session. Das Backbone-Material stammt aus einer echten gespielten CoC-Session 1+2 der prod-Kampagne (anonymisiert), ergänzt um Briefing-Phase und Resolution. JSON-Format pro Zeile: `{"text", "discord_id"}`.

## Verwendung

- `Worker.Probelauf` lädt die Datei via `real_utterances/0`, wenn im Probelauf/Sweep das Session-Set „real" angekreuzt ist (Sessions short/medium/long sind hardcoded im Modul).
- `mix lore.seed.coc_demo` seedet daraus eine wiederverwendbare Test-Stage-Kampagne (dort wird auch die `discord_id` pro Utterance übernommen, damit mehrere Sprecher sichtbar sind).

## Historie

Bis #786 lagen hier zusätzlich Stage-2/3/4-**Goldstandard**-Outputs (`session-N-{summary,epos}.md`, `session-N-chronik.json`) für die stage-isolierten Chain-Sweeps (Issue #201/#262). Die sind mit der Chain-Pipeline entfernt — der Wahrheitsbild-Probelauf misst den vollen Pfad (extract → verify → render/timeline/render_epos) inklusive Verify-Trichter und braucht keine Pre-Seeds.

## Lizenz

Inhalte sind kurze fiktive RPG-Szenen bzw. anonymisiertes Eigen-Material — keine externe Vorlage, CC0-äquivalent.
