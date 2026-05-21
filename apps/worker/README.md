# Worker

Lokal beim Spielleiter installierte OTP-App von LoreTracker. Verbindet sich via Slipstream-WebSocket zu einem Hub, materialisiert dessen EventLog in lokale Mnesia-Tabellen und betreibt die Audio-/LLM-Pipeline (Whisper-Transkription → mehrstufige LLM-Verarbeitung → Resümees / Epos / Chronik).

## Komponenten

- **`Worker.HubClient`** — Slipstream-Connection zum Hub. Topic `worker:<worker_id>`. Empfängt `event_appended`-Pushes + `catch_up_batch`, publisht `publish_intent` für eigene Events. Siehe `apps/hub/lib/hub_web/channels/worker_channel.ex` für die Hub-Gegenseite.
- **`Worker.Materializer`** — Konsumiert Events aus dem Hub-Log, schreibt sie in worker-lokale Mnesia-Tabellen (`worker_campaigns`, `worker_sessions`, `worker_utterances`, …). Per-Event-Apply, idempotent.
- **`Worker.Recording.*`** — Audio-Capture (LiveTranscribe + Batch-Modus), Whisper-CLI-Wrapper, Pipeline-Stages 1-4 (Transkript → Resümee → Epos → Chronik).
- **`Worker.Probelauf`** — LLM-Smoke-Test für die Pipeline (Issue #74), startbar aus dem Hub-Admin-UI.
- **`Worker.Setup.Endpoint`** — Cowboy-Mini-Endpoint für den initialen Pairing-Flow (Discord-OAuth-Round-Trip). Läuft nur wenn noch kein Hub-Token in Mnesia liegt.

## Start

Erst pairen, dann verbinden — siehe [`docs/Worker-Setup.md`](../../docs/Worker-Setup.md). Lokale Dev-Variante gegen Dev-Hub:

```bash
cd apps/worker
LORE_MNESIA_DIR=$(pwd)/../../priv/mnesia/dev-worker \
  elixir --sname worker --no-halt -S mix run
```

## Mehr

Siehe Root-[`README.md`](../../README.md) und [`CLAUDE.md`](../../CLAUDE.md).
