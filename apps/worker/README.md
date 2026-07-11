# Worker

Lokal beim Spielleiter installierte OTP-App von LoreTracker. Verbindet sich via Slipstream-WebSocket zu einem Hub, materialisiert dessen EventLog in lokale Mnesia-Tabellen und betreibt die Audio-/LLM-Pipeline (Whisper-Transkription → Wahrheitsbild-Pipeline: Fakten-Extraktion → Verify-Gate → Resümee / Epos-Kapitel / Zeitstrahl aus verifizierten Fakten).

## Komponenten

- **`Worker.HubClient`** — Slipstream-Connection zum Hub. Topic `worker:<worker_id>`. Empfängt `event_appended`-Pushes + `catch_up_batch`, publisht `publish_intent` für eigene Events. Siehe `apps/hub/lib/hub_web/channels/worker_channel.ex` für die Hub-Gegenseite.
- **`Worker.Materializer`** — Konsumiert Events aus dem Hub-Log, schreibt sie in worker-lokale Mnesia-Tabellen (`worker_campaigns`, `worker_sessions`, `worker_utterances`, …). Per-Event-Apply, idempotent.
- **`Worker.Recording.*`** — Audio-Capture (Per-Stream-Routing seit #642: Per-Spieler-Spuren UND Raummikro-Spuren `multi_<did>` dürfen gemischt in einer Session laufen, `Transcribe.run_mixed/3` fährt beide Pfade additiv; Live-Transkription wurde mit #418 entfernt), Whisper-CLI-Wrapper und die Wahrheitsbild-Pipeline (#651/#786): Fakten-Extraktion (`extract_facts`, Map-Reduce für lange Sessions #683 — überschreitet das Transkript `:extract_chunk_tokens`, wird an Turn-Grenzen gechunkt und pro Chunk extrahiert, degenerierte Chunks werden halbiert erneut versucht #763) → Entity-Registry (#714) → Verify-Gate (Grounding + Attribution, Flag-statt-Drop) → Geschwister-Render: Resümee, per-Session-Epos-Kapitel (#752) und deterministischer Zeitstrahl (#724) aus den verifizierten Fakten. Die frühere Chain (Stage 2→3→4 Prosa-Kette) ist mit #786 entfernt.
- **`Worker.Recording.Diarize`** — Single-Source-Sprecher-Trennung (Issue #19). Ruft den pyannote-Sidecar in `priv/sidecar/diarization_sidecar.py` an (16 kHz Mono WAV → Sprecher-Turns). `Transcribe.run_single_source/2` jagt jeden Turn einzeln durch Whisper und schreibt Utterances mit Pseudo-Label `speaker:<session_id>:<n>`. Skip mit `:sidecar_offline` wenn `:diarization_sidecar_url` nicht gesetzt.
- **`Worker.Recording.ChunkManifest`** — Per-Speaker-Sidecar `<key>.chunks.jsonl` neben jeder Audio-Datei (Issue #757). `AudioBuffer.write_chunk/6` stempelt bei jedem eingehenden Chunk `{wc: System.system_time(:millisecond), b: cumulative_bytes}` in den Sidecar; `Transcribe.emit_utterances/6` interpoliert daraus pro Whisper-Segment die Wall-Clock statt `session.started_at + offset_ms`. Deckt Late-Mic-Join (Speaker beginnt nach Session-Start) und Mid-Session-Writer-Reset (Wall-Clock läuft weiter, WAV-Position nicht) ab. Alt-Sessions ohne Sidecar → `resolve/4` liefert `nil`, Fallback auf das Alt-Verhalten.
- **`Worker.LLM.Faithfulness`** — NLI-Scoring-Baustein (Issue #11 Phase 2), heute genutzt vom Verify-Gate (`grounding_method: :nli`) und vom Render-Gate. Ruft den Python-Sidecar in `priv/sidecar/` an. Skip ohne Crash wenn `:faithfulness_sidecar_url` nicht gesetzt oder Sidecar offline.
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
