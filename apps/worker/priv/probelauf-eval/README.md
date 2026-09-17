# Seed-Asset „Corbett House“ (ehemals Probelauf-Eval)

Hier liegt genau **eine** Datei:

```
session-4-utterances.jsonl   — Quell-Utterances einer kompletten CoC-Session (eine JSON pro Zeile)
```

„Corbett House — Boston 1925“ (Issue #286): ~840 Whisper-anmutende Utterances (5 Sprecher: sl/laurent/flaw/oreilly/crawford, Ø ~35c) einer kompletten CoC-Investigations-Session. Das Backbone-Material stammt aus einer echten gespielten CoC-Session 1+2 der prod-Kampagne (anonymisiert), ergänzt um Briefing-Phase und Resolution. JSON-Format pro Zeile: `{"text", "discord_id"}`.

## Verwendung

- `mix lore.seed.coc_demo` seedet daraus eine wiederverwendbare Test-Stage-Kampagne (dort wird auch die `discord_id` pro Utterance übernommen, damit mehrere Sprecher sichtbar sind). Das ist der einzige Verbraucher.

## Historie

Die Datei war die „real“-Session des LLM-Probelaufs (`/admin/probelauf`, Issue #74/#88/#284). Der Probelauf ist mit J4 (#1207) entfernt; seitdem ist sie reines Seed-Material. Der Ordnername ist geblieben, weil `mix lore.seed.coc_demo` diesen Pfad fest verdrahtet hat.

Bis #786 lagen hier zusätzlich Stage-2/3/4-**Goldstandard**-Outputs (`session-N-{summary,epos}.md`, `session-N-chronik.json`) für die stage-isolierten Chain-Sweeps (Issue #201/#262); die sind mit der Chain-Pipeline entfernt.

## Lizenz

Inhalte sind kurze fiktive RPG-Szenen bzw. anonymisiertes Eigen-Material — keine externe Vorlage, CC0-äquivalent.
