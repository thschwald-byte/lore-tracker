# Performance-Baseline

Mess-Daten + Deployment-Empfehlungen für Self-Hosting des Lore-Tracker-Stacks. Aggregiert aus den Sub-Issues von #69 (#91, #92, #94, #95, #99) plus laufendem Probelauf-Sweep (#88) als laufende Selbst-Diagnose.

> **Stichtag**: 2026-05-25 (Pass 1: BEAM + Mnesia-Disk + Whisper Stage-1; LLM-Stages wartet auf #201 Stage-Isolation; #92/#95 stehen noch aus).
> **Hardware**: siehe Sektion „Mess-Setup".
> **Vorgehen**: alle Messungen aus einem `mix lore.pr_test.spawn`-Stack (frischer Worktree, frische Worker-Mnesia, Romeo-Schlegel-Demo als Standard-Seed = 1159 Events / 27 Sessions / 1060 Utterances).

## TL;DR — Self-Hosting-Empfehlung

| Profil | RAM | Disk | CPU | LLM-Konfiguration |
|---|---|---|---|---|
| **Minimal** | 8 GB | 10 GB | 4 cores | `qwen2.5:0.5b` für alle Stages, `whisper.cpp tiny` |
| **Komfort** (Default) | 16 GB | 20 GB | 8 cores | `qwen2.5:7b` für alle Stages, `whisper.cpp base` |
| **Premium** | 32 GB | 50 GB | 8+ cores | `qwen3:30b-a3b` oder `mistral-nemo:12b`, `whisper.cpp medium` |

Cloud-LLM-Backends (Anthropic, OpenAI, Google — siehe #174/#175) entlasten den Worker-Compute, brauchen aber `ANTHROPIC_API_KEY` etc. als Env-Var und kosten USD/Token (Spend-Tracking siehe #177/#178).

## Mess-Setup

- **OS**: CachyOS (Arch-derived), Linux 7.0.x.
- **Hardware**: x86_64 Workstation (siehe `lscpu` lokal).
- **Erlang/OTP**: 27, Elixir 1.19.
- **Hub-Version**: 1.0.3 (post-Etappe-5c DB-frei).
- **Worker-Version**: 0.16.0.
- **Romeo-Schlegel-Seed**: 27 Sessions, 1159 Events, 1060 Utterances, mit pre-generated Stage-2/3/4-Outputs.

Alle Werte aus einem PR-Test-Stack (`mix lore.pr_test.spawn` Issue #186 + #190 — siehe `docs/PR-Test-Setup.md`).

## BEAM-Footprint + Mnesia-Disk (#99)

### Worker-BEAM

Gemessen mit `:erlang.memory()` via RPC (idle, direkt nach Romeo-Seed-Abschluss, vor LLM-Sweep-Start).

| Kategorie | KB | MB |
|---|---:|---:|
| **total** | 94 127 | **~92** |
| processes | 19 883 | 19 |
| binary | 3 706 | 4 |
| ets | 2 066 | 2 |
| code | 22 115 | 22 |

- **process count**: 255

### Hub-BEAM

| Kategorie | KB | MB |
|---|---:|---:|
| **total** | 165 845 | **~162** |
| processes | 26 979 | 26 |
| binary | 48 188 | 47 |
| ets | 3 115 | 3 |
| code | 33 157 | 32 |

- **process count**: 646

Hub ist deutlich schwerer als Worker — Bandit + Phoenix-Endpoint + LiveView + alle HubWeb-LiveView-Module sind im `code`-Segment, plus die initial-geladenen Assets im `binary`-Heap.

### Mnesia-Disk

Worker-Mnesia direkt nach Romeo-Schlegel-Seed:

| Pfad | Größe | Notiz |
|---|---:|---|
| `/tmp/pr-4005/worker-0-mnesia/` | **364 KB** | 1159 Events + materialisierte Tabellen + Mnesia-LATEST.LOG |
| `/tmp/pr-4005/hub-mnesia/` | **0 B** | Hub ist DB-frei post-Etappe-5c (#164) |

Per-Tabelle (`worker-0-mnesia/*.DCD`):
- `LATEST.LOG`: 260 KB — Write-Ahead-Log (alle frisch geseedeten Events darin, noch nicht in DCD gemerged)
- `schema.DAT`: 27 KB — Mnesia-Schema-Metadata
- `worker_state.DCD`: 722 B — hub_token, worker_id, admin_discord_id, hub_base_url, last_applied_seq
- `worker_users.DCD`: 394 B — 1 User (PR-Test User)
- Per-Campaign-Event-Store `worker_campaign_events_romeojuliademo.DCD` + alle materialisierten Tabellen (`worker_sessions`, `worker_utterances`, etc.): jeweils 8 B initial, weil Mnesia die Daten erst nach `sync_log` aus dem LATEST.LOG materialisiert.

### Per-Event-Footprint

Romeo-Schlegel: **364 KB / 1159 Events = ~314 Bytes pro Event** (inkl. materialisierter Tabellen-Rows).

### Wachstums-Extrapolation

Eine **typische Kampagne** ≈ 50 Sessions × 30-50 Utterances × 1 SessionSummary × 1 EposEntry × 5 ChronikEntries ≈ **~3000 Events** ≈ **~1 MB Mnesia**.

Eine **Power-Kampagne** mit 200 Sessions × 100 Utterances ≈ **~25 000 Events** ≈ **~8 MB Mnesia**.

Eine **Self-Hosting-Worker mit 10 aktiven Kampagnen über 3 Jahre**: ~50 MB Mnesia. Vernachlässigbar.

Audio-Aufnahmen sind separat (nicht in Mnesia) und der größere Disk-Faktor: WebM ~10 MB/h aktive Aufnahme. **10 Kampagnen × 1 Session/Woche × 4h × 52 Wochen ≈ 2 TB Audio** falls alles permanent gespeichert. Empfehlung: alte Sessions nach Pipeline-Stage-4-Completion archivieren (siehe #97 EventLog-Retention).

### Empfehlung

- **Worker-RAM**: 100 MB idle, 500 MB Peak unter Pipeline-Last (Whisper + LLM-Stage parallel — Ollama-RAM separat).
- **Hub-RAM**: 200 MB konstant (DB-frei).
- **Disk Mnesia**: 1 MB/Kampagne, vernachlässigbar.
- **Disk Audio**: dominanter Faktor, Retention-Politik nötig.

## LLM-Stages (#91)

**Wartet auf #201 (Stage-Isolation mit Goldstandard-Pre-Seed).**

Erster Sweep-Versuch (24.05.2026, abgebrochen): Probelauf-Sweep variiert pro Variante das Stage-N-Modell, fährt aber die **komplette Pipeline** (alle Stages 2/3/4) — Stage-3+4-Wall-Clock-Werte sind dadurch verzerrt (jedes Stage-2-Modell produziert anderen Input für Stage 3, → unfaire Vergleich). Stage 2 alleine wäre fair (Input deterministisch), aber ohne Faithfulness-Score nur Wall-Clock + Format-Outcome (`ok`/`timeout`/`empty_output`/`parse_error`).

**Geplanter Mess-Pfad nach #201**:
- Goldstandard-Asset in `apps/hub/priv/seeds/probelauf-eval/` mit pre-kuratierten Stage-Outputs.
- `start_sweep_isolated/2` läuft nur die gewählte Stage, lädt prior-Stage-Output aus Goldstandard.
- Faithfulness-Score (#11 Phase 2) gegen Goldstandard → echte Qualitäts-Metrik.

**Sweep-Konfiguration für Pass 2** (geplant):

| Modell | RAM (Ollama-load) | Stage 2 | Stage 3 | Stage 4 |
|---|---:|:---:|:---:|:---:|
| `qwen2.5:0.5b` | 0.4 GB | pending | pending | pending |
| `qwen2.5:7b` | 4.7 GB | pending | pending | pending |
| `mistral-nemo:12b` | 7.1 GB | pending | pending | pending |
| `qwen3:30b-a3b` | 18 GB | pending | pending | pending |
| `command-r:35b-08-2024-q4_K_M` | 19 GB | pending | pending | pending |

Pro Cell wird gemessen: Median-Wall-Clock + Success-Rate + Faithfulness-Score gegen Goldstandard. Aggregation pro Stage: bestes Modell nach (Wall-Clock × Faithfulness)-Pareto-Front.

## Whisper-Stage (#94)

Gemessen via `mix lore.stt_bench --all-models --all-sessions` (Issue #94) gegen die committed Faust-Fixtures (`apps/worker/test/fixtures/stt/faust/`, PD-Audio aus Librivox, CC0). Zwei Sessions à 6 bzw. 3 Sprecher-Turns, alle isoliert (no-context Baseline). Whisper-Backend: `whisper-cli` aus dem Arch-Paket `whisper-cpp`.

**Modell × Session — WER + RTF**

| Modell | Gartenszene WER | Gartenszene RTF | Hexenkueche WER | Hexenkueche RTF |
|---|---:|---:|---:|---:|
| base | 22.4% | 0.06 | 15.8% | 0.03 |
| medium | 11.0% | 0.11 | 9.2% | 0.10 |
| large-v3 | 4.2% | 0.14 | 8.3% | 0.07 |
| **large-v3-turbo** | **0.5%** | **0.09** | **7.5%** | **0.04** |

`tiny` und `small` waren auf dieser Maschine nicht gecached — Skip mit Warnung (`[skip] tiny — Modell-Datei fehlt`).

### Erkenntnisse

- **large-v3-turbo dominiert** auf beiden Achsen: niedrigste WER **und** schneller als large-v3 (turbo nutzt nur 4 Decoder-Layer statt 32). Empfehlung als Default-Modell für Komfort + Premium-Profil.
- **base** ist nur als Minimal-Profil-Fallback brauchbar (22% WER bedeutet jedes 5. Wort falsch, LLM-Stages 2-4 müssen das mit Kontext kompensieren).
- **RTF < 1.0 bei allen Modellen** auf dieser Hardware → alle live-Modus-tauglich. Faktor ~14× Echtzeit bei large-v3-turbo (RTF 0.07-0.09 mittel).
- **Hexenkueche-Turn 1 (faust, hochrhetorisch)** hat über alle Modelle hinweg 22–47% WER — verzerrt den hexenkueche-Durchschnitt nach oben. Bei mehr Turns/Session würde sich der Effekt rausmitteln.

### Empfehlung pro Hardware-Profil

| Profil | Modell | Begründung |
|---|---|---|
| Minimal (8 GB RAM) | `ggml-base.bin` (~150 MB) | RTF schnell, akzeptabel wenn Vokabular im Prompt steht |
| Komfort (16 GB RAM) | `ggml-large-v3-turbo.bin` (~1.6 GB) | bestes WER/RTF-Verhältnis, einziges Modell mit < 1% WER auf dieser Test-Suite |
| Premium (32 GB RAM) | `ggml-large-v3-turbo.bin` | gleich — Premium nutzt Reserve für gleichzeitige LLM-Pipeline-Last, nicht für teureres STT-Modell |

`large-v3` lohnt sich nicht mehr — turbo ist überall gleichwertig oder besser.

### Reproduzieren

```bash
# Modelle laden (einmalig, ~2 GB total wenn alle):
for m in tiny base small medium large-v3 large-v3-turbo; do
  curl -L -o ~/.cache/whisper/ggml-$m.bin \
    https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-$m.bin
done

# Fixtures generieren (~60 MB Faust-Audio von archive.org):
bash apps/worker/test/fixtures/stt/setup.sh

# Full Matrix:
mix lore.stt_bench --all-models --all-sessions
```

### Out of Scope (für Folge-Issues)

- **Audio-Längen-Skalierung (1/5/30 min)** — die Fixture-Turns sind ~4-30s. Längere Mess-Streams brauchen Concatenation o.ä. — eigenes Ticket.
- **German-Fine-Tuned-Modell** (`ggml-large-v3-turbo-german.bin`) — Worker.Settings hat den Pfad bereits im Fallback-Lookup (siehe `Worker.Settings.whisper_model_fallback/0`); Modell-Datei nicht im öffentlichen HuggingFace-Repo, muss separat beschafft werden.

## Reader + Materializer Scaling (#92)

**Out of scope für Pass 1.** Eigener PR — siehe Issue #92. `mix lore.bench.reader`-Task fehlt noch.

Geplant:
- Synthetic-Event-Generator pumpt 10k / 100k / 1M Events ins Event-Log
- Per Skala: `Worker.Reader.read/2`-Latenz + Materializer-Replay-Zeit + Mnesia-Disk-Wachstum

## UI-Last-Test (#95)

**Out of scope für Pass 1.** Eigener PR — siehe Issue #95. Manueller Mess-Pfad (Chrome DevTools Performance-Profiling auf Schlegel-Volltext), kein Code-Aufwand.

Geplant:
- Session-View mit 99 Utterances (Akt 5 Szene 3 der Schlegel-Demo) — Scrolling-FPS
- Modal-Open/Close-Latenz
- LiveView-WebSocket-Bandbreite bei großen Updates

## Selbst-Diagnose: Probelauf-UI

`/admin/probelauf` (Issue #74 / #88) ist die laufende Selbst-Diagnose. Admin kann jederzeit einen Single-Stage- oder Multi-Modell-Sweep gegen den eigenen Worker fahren und die Heuristik-Empfehlung („Modell X für Stage Y") direkt in `Worker.Settings` übernehmen.

## Cross-Cutting

- **Cloud-LLM** (Anthropic via #27 Phase 1a, OpenAI/Google in #174/#175): wenn Worker-Hardware schwach ist, Cloud-Backends pro Stage konfigurierbar. Cost-Tracking via #177.
- **Pipeline-Re-Run** (Issue #104): pro Session ein „🔄 neu generieren"-Button — nützlich nach Modell-Wechsel.
- **Probelauf-Auto-Apply** (#88 Phase 2c): Sweep-Sieger automatisch in `Worker.Settings` schreiben.
