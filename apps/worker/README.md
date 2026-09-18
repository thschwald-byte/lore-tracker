# Worker

Lokal beim Spielleiter installierte OTP-App von LoreTracker. Verbindet sich via Slipstream-WebSocket zu einem Hub, materialisiert dessen EventLog in lokale Mnesia-Tabellen und betreibt die Audio-/LLM-Pipeline (Whisper-Transkription → Wahrheitsbild-Pipeline: Glättung → Fakten-Extraktion durch Jack, jede Aussage am wörtlichen Beleg geprüft → Resümee / Epos-Kapitel / Zeitstrahl aus diesen Fakten).

## Komponenten

- **`Worker.HubClient`** — Slipstream-Connection zum Hub. Topic `worker:<worker_id>`. Empfängt `event_appended`-Pushes + `catch_up_batch`, publisht `publish_intent` für eigene Events. Siehe `apps/hub/lib/hub_web/channels/worker_channel.ex` für die Hub-Gegenseite.
- **`Worker.Materializer`** — Konsumiert Events aus dem Hub-Log, schreibt sie in worker-lokale Mnesia-Tabellen (`worker_campaigns`, `worker_sessions`, `worker_utterances`, …). Per-Event-Apply, idempotent.
- **`Worker.Recording.*`** — Audio-Capture (Per-Stream-Routing seit #642: Per-Spieler-Spuren UND Raummikro-Spuren `multi_<did>` dürfen gemischt in einer Session laufen, `Transcribe.run_mixed/3` fährt beide Pfade additiv; Live-Transkription wurde mit #418 entfernt), Whisper-CLI-Wrapper und die Wahrheitsbild-Pipeline (#651/#786): Glättung (Stage 1.1, samt Gap-Fill) → Fakten-Extraktion durch Jack (`Worker.Jack.*`, s.u.) → Entity- und Thread-Registry (#714/#832) → Geschwister-Render: Resümee, per-Session-Epos-Kapitel (#752) und deterministischer Zeitstrahl (#724). Die frühere Chain (Stage 2→3→4 Prosa-Kette) ist mit #786 entfernt; die alte Extraktion (`Stages`: Chunking/Map-Reduce, Halbierung, Satzgrenzen-Split, Salvage) und das Verify-Gate (Stufe 3) mit J4 (#1207).
- **`Worker.Jack.*`** — Stufe 2 der Pipeline (Epic #1195, J4 #1207): ein Agent mit Werkzeugen, der eine Sitzung in Gedächtnis, Extraktion und Verifikationen bis zur Sättigung liest (`Worker.Jack.Pipeline`); Aufträge als Vorlagen unter `priv/jack/auftraege/`, Jacks Stand je Sitzung als Ereignis `JackStandAbgelegt` (Grundlage für „noch N Iterationen“), lokale Laufsicht auf `127.0.0.1:8099` (`Worker.Jack.Sicht`; eine Teststage nimmt Stage-Port + 10 über `LORE_JACK_SICHT_PORT`). Messläufe über `mix lore.jack.lauf`, der Referenzlauf über `mix lore.jack.referenz`. Details: `CLAUDE.md` → „Stufe 2 ist Jack“.
- **`Worker.Recording.Diarize`** — Single-Source-Sprecher-Trennung (Issue #19). Ruft den pyannote-Sidecar in `priv/sidecar/diarization_sidecar.py` an (16 kHz Mono WAV → Sprecher-Turns). `Transcribe.run_single_source/2` jagt jeden Turn einzeln durch Whisper und schreibt Utterances mit Pseudo-Label `speaker:<session_id>:<n>`. Skip mit `:sidecar_offline` wenn `:diarization_sidecar_url` nicht gesetzt.
- **`Worker.Recording.ChunkManifest`** — Per-Speaker-Sidecar `<key>.chunks.jsonl` neben jeder Audio-Datei (Issue #757). `AudioBuffer.write_chunk/6` stempelt bei jedem eingehenden Chunk `{wc: System.system_time(:millisecond), b: cumulative_bytes}` in den Sidecar; `Transcribe.emit_utterances/6` interpoliert daraus pro Whisper-Segment die Wall-Clock statt `session.started_at + offset_ms`. Deckt Late-Mic-Join (Speaker beginnt nach Session-Start) und Mid-Session-Writer-Reset (Wall-Clock läuft weiter, WAV-Position nicht) ab. Alt-Sessions ohne Sidecar → `resolve/4` liefert `nil`, Fallback auf das Alt-Verhalten. Seit Issue #1060 trägt jede Zeile zusätzlich ihre **Anker-Richtung**: der Stempel meint das Ende des Stücks (Default, Browser-Mic — der Wall-Clock ist die Chunk-Ankunft) oder seinen Anfang (`"a":"s"`, Discord-Bot — dort gibt `VoiceSession` den Fensterbeginn über `AudioBuffer.append/6` mit, weil der Clip beim letzten Wort des Sprechers endet und erst nach ffmpeg geschrieben wird). Zeilen ohne das Feld bleiben Ende-verankert.
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
