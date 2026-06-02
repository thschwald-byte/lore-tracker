# Performance-Baseline

Mess-Daten + Deployment-Empfehlungen für Self-Hosting des Lore-Tracker-Stacks. Aggregiert aus den Sub-Issues von #69 (#91, #92, #94, #95, #99) plus laufendem Probelauf-Sweep (#88) als laufende Selbst-Diagnose.

> **Stichtag**: 2026-05-26 (Pass 1 abgeschlossen + #95 Server-Side gefüllt). **Offen**: #95 Browser-Side (DevTools-Pass, manuell) + Stages 3+4 (blocked auf #201 Stage-Isolation).
> **Hardware**: siehe Sektion „Mess-Setup".
> **Vorgehen**: alle Messungen aus einem `mix lore.pr_test.spawn`-Stack (frischer Worktree, frische Worker-Mnesia, Romeo-Schlegel-Demo als Standard-Seed = 1159 Events / 27 Sessions / 1060 Utterances).

## TL;DR — Self-Hosting-Empfehlung

| Profil | RAM | Disk | CPU | Whisper (Stage 1) | Stage 2 (Resümee) | Stage 3+4 (Epos/Chronik) |
|---|---|---|---|---|---|---|
| **Minimal** | 8 GB | 10 GB | 4 cores | `ggml-base.bin` (~150 MB, ~22% WER) | `qwen2.5:0.5b` (~2s) | `qwen2.5:7b` (Batch) ¹ |
| **Komfort** (Default) | 16 GB | 20 GB | 8 cores | **`ggml-large-v3-turbo.bin` (~1.6 GB, ~0.5% WER)** | **`qwen2.5:7b` (~1.5s)** | `qwen2.5:7b` ¹ |
| **Premium** | 32 GB | 50 GB | 8+ cores | `ggml-large-v3-turbo.bin` | `qwen2.5:7b` (Live) | `qwen3:30b-a3b` (Batch, ~30-45s/Call) ¹ |

¹ Stage-3+4-Empfehlung ist heuristisch — fair vermessbar erst nach #201 (Stage-Isolation mit Goldstandard-Pre-Seed). Heutige Defaults in `Worker.Settings` siehe `Worker.Settings.@defaults` und `/settings`-UI.

**Disk-Footprint** ist dominant **Audio**, nicht Mnesia. Mnesia/Kampagne ≈ 1 MB (siehe #99). Audio bei aktivem Recording ~10 MB/h WebM, Retention-Politik nötig wenn alle Sessions permanent gespeichert (siehe #97).

**Cloud-LLM-Backends** (Anthropic via #27, OpenAI/Google in #174/#175) entlasten den Worker-Compute, brauchen aber `ANTHROPIC_API_KEY` etc. als Env-Var und kosten USD/Token (Spend-Tracking siehe #177/#178).

## Mess-Setup

- **OS**: CachyOS (Arch-derived), Linux 7.0.x.
- **Hardware**: x86_64 Workstation (siehe `lscpu` lokal).
- **Erlang/OTP**: 27, Elixir 1.19.
- **Hub-Version**: 1.0.3 (post-Etappe-5c DB-frei).
- **Worker-Version**: 0.17.4.
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

### Stage 2 — Session-Summary (gemessen, fair)

Gemessen via `mix lore.bench_llm_stage2` (Issue #91, pragmatisch). Direkter Aufruf von `Worker.LLM.complete(:summary, prompt)` mit Warm-Up-Call, ohne Pipeline-Roundtrip. Median über 2 Steady-State-Samples. Stage-2-Input ist deterministisch (synthetische Utterance-Liste, identisch zum `Worker.Probelauf`-Seed) → Modell-Vergleich ist fair.

| Modell | Ollama-RAM | short (10 utts, ~1300 chars) | medium (30 utts, ~3200 chars) | Success |
|---|---:|---:|---:|---:|
| `qwen2.5:0.5b` | 0.4 GB | 1.7s | 1.9s | 100% |
| **`qwen2.5:7b`** | 4.4 GB | **1.2s** | **1.5s** | **100%** |
| `mistral-nemo:12b` | 6.6 GB | 3.8s | 1.8s | 100% |
| `qwen3:30b-a3b` | 17.3 GB | 28.8s | 45.0s | 100% |

**Erkenntnisse:**

- **`qwen2.5:7b` dominiert** für Stage 2 — schnellster, geringster RAM-Footprint unter den brauchbaren Modellen, 100% Success-Rate. Bestätigt den heutigen Default in `Worker.Settings`.
- **`qwen2.5:0.5b`** ist Minimal-Profil-tauglich (~2s), Output-Qualität schwankt (manchmal extrem knapp, manchmal verbose — eigene Faithfulness-Messung nach #201/#11-Phase-2 nötig).
- **`mistral-nemo:12b`** bringt für Stage 2 keinen Vorteil gegenüber qwen2.5:7b. Eventuell sinnvoll für Stage 3+4 mit langem Output — Vergleich folgt nach #201.
- **`qwen3:30b-a3b`** ist mit 30-45s pro Stage-2-Call **zu langsam für Live-Recording** (Pipeline läuft alle 30s, würde sich aufstauen). Nur für Stage 3 + 4 Batch-Generation sinnvoll, wenn überhaupt.

### Stage 2 — Prompt-Token-Footprint + Context-Window-Last (#114-Folge)

> **Stichtag**: 2026-05-28. Gemessen gegen das **live konfigurierte** Stage-2-Modell `qwen3:30b-a3b-instruct-2507-q4_K_M` (256k nativer Context), nicht den Komfort-Default `qwen2.5:7b` — der Tokenizer ist also qwen3. Datensatz: prod-Kampagne „Call of Cthulhu", Session 2 (200 Utterances, 3 aktive Sprecher, 2 Spieler mit toten Mikros = 0 Utterances).

**Methode**: Stage-2-Prompt exakt wie `Worker.Recording.Pipeline.build_summary_prompt/3` aus den echten Repo-Utterances rekonstruiert (via Worker-RPC), dann an Ollama `/api/generate` (`num_predict: 1`) geschickt und `prompt_eval_count` ausgelesen — Ground Truth des Modell-Tokenizers, keine `chars/4`-Heuristik.

#### Footprint: UUID-Prefix vs. Kurz-ID

Seit #114 prefixt jede Transkript-Zeile die volle Utterance-UUID (`[019e611c-…-3944] Sprecher: Text`), damit das LLM im JSON-Mode `source_refs` mit echten IDs füllen kann. Eine UUID tokenisiert zu ~30 Token (Hex zerfällt schlecht in BPE) — teurer als der eigentliche Gesprächstext.

| Variante | 200 utts | pro Utterance |
|---|---:|---:|
| **UUID-Prefix (aktuell)** | 10 074 tok | **50,4 tok/utt** |
| Kurz-ID `[u1]…[uN]` | 3 959 tok | **19,8 tok/utt** |
| **Ersparnis** | −6 115 tok | **−60,7 %** |

#### Context-Window-Ceiling (bei live `ctx_stage2 = 81920`)

| | max. utts vor Truncation | reale 5-h-Vollmikro-Session (~3 700 utts) |
|---|---:|---|
| UUID (aktuell) | ~1 600 | 186k tok → **2,3× über 80k, ~57 % des Transkripts still weggeworfen** |
| Kurz-ID | ~4 040 | 73k tok → **passt (gerade so)** |

Utterance-Hochrechnung 5-h-Session: aufgezeichnete Dichte ~2,5 utts/min pro aktivem Mikro × 5 Mikros × 300 min ≈ 3 700 utts.

**Erkenntnisse:**

- Ollama trunkiert bei Prompt > `num_ctx` **still** und behält die *jüngsten* Token — der **Session-Anfang** fällt weg, ohne Fehler, ohne Log. Die Pipeline meldet trotzdem `ended`. Das ist das gefährliche Failure-Mode: leise falsch statt Crash.
- Mit den UUID-Prefixen kippt schon eine geschäftige 2-h-Runde (>1 600 utts); eine echte 5-h-Session verliert über die Hälfte ihres Transkripts.
- `ctx_stage2` steht bereits auf 80k (qwen3-2507 deckt das nativ, kein Rope-Scaling / Modelfile nötig). KV-Cache dafür ist auf 128 GB RAM unkritisch (~wenige GB). Der binding constraint ist **nicht RAM**, sondern Token-Effizienz + CPU-Prefill-Speed.
- Kurz-IDs verschieben das Ceiling von ~1 600 auf ~4 040 utts — der Unterschied zwischen „trunkiert jede lange Session" und „deckt die volle 5-h-Runde im bestehenden Context ab", ohne `num_ctx` weiter hochzudrehen.

**Empfehlung:**

1. **Kurz-IDs im Stage-2/3-Prompt** (`[u1]…[uN]`, nach dem Parse auf echte UUIDs zurückmappen) — 60,7 % Token-Ersparnis, der billige Hebel. Höchste Prio.
2. **Silent-Truncation-Guard**: Prompt-Token > `num_ctx` → Logger-Warning + chunk/abbrechen statt unbemerktem Halb-Transkript.
3. **Map-Reduce-Chunking** nur als Reserve für Sessions jenseits ~4 000 utts + als Qualitäts-Upgrade (lost-in-the-middle). Nicht dringend, solange Kurz-IDs + 80k den typischen Fall decken.
4. `num_ctx` weiter hochziehen (bis 256k) ginge nativ, aber CPU-Prefill von 100k+ Token wird zäh — Token-Effizienz schlägt mehr Context.

**Update (Issue #417, umgesetzt):** Empfehlung 3 ist gebaut. Stage 2 schaltet
automatisch auf **Map-Reduce** um, sobald das gerenderte Transkript das
Per-Worker-Setting `:stage2_chunk_tokens` (Default 6000) überschreitet: Utterances
werden an Turn-Grenzen in Budget-Chunks gesplittet (Overlap 2 für Kontinuität), pro
Chunk ein Teil-Resümee (Map), dann zu einem Gesamt-Resümee zusammengefasst (Reduce,
rekursiv bei sehr vielen Chunks). `source_refs` = Union der Chunk-Refs (echte UUIDs,
weil Prompt-Builder + Parser pro Chunk dieselbe Chunk-Liste sehen). Ein gescheiterter
Map-Chunk wird geloggt + übersprungen, killt aber nicht die Stage. Der
Single-Prompt-Pfad (kurze Sessions ≤ Budget) bleibt unverändert. Damit ist eine
4-h-Session unabhängig von `num_ctx` vollständig abgedeckt; der Silent-Truncation-Guard
(Empfehlung 2) bleibt als Diagnose für den Single-Pfad + Stage 3/4 (noch ohne Chunking).

**Reproduzieren** (ad-hoc, kein committed Bench-Task):

```
# Stage-2-Prompt aus echten Utterances bauen (Worker-RPC) + Ollama prompt_eval_count:
#  1. Worker.Repo.list_utterances/1 + resolve_speaker_names → Transkript wie build_summary_prompt/3
#  2. POST localhost:11434/api/generate {"model": <model_stage2>, "prompt": …, "options": {"num_predict": 1}}
#  3. prompt_eval_count aus der Antwort = exakter Token-Count (UUID- vs. [uN]-Variante gegenüberstellen)
```

### Stage 3 (Epos) + Stage 4 (Chronik) — blocked on #201

Stage 3 hängt vom Stage-2-Output ab, Stage 4 vom Stage-3-Output. Sobald man bei einem Multi-Modell-Sweep den Stage-N-Modell variiert, ist der Input für Stage N+1 **kein konstanter Vergleichsgegenstand** mehr — die Wall-Clock-Werte sind vermischt mit Input-Längen-Effekten. Faire Messung braucht **#201 (Stage-Isolation mit Goldstandard-Pre-Seed)**:

- Goldstandard-Asset mit pre-kuratierten Stage-N-Outputs in `apps/hub/priv/seeds/probelauf-eval/`
- `start_sweep_isolated/2` läuft nur die gewählte Stage, lädt prior-Stage-Output aus Goldstandard
- Faithfulness-Score (#11 Phase 2) gegen Goldstandard → echte Qualitäts-Metrik (nicht nur Wall-Clock)

| Modell | RAM (Ollama-load) | Stage 3 | Stage 4 |
|---|---:|:---:|:---:|
| `qwen2.5:0.5b` | 0.4 GB | blocked on #201 | blocked on #201 |
| `qwen2.5:7b` | 4.4 GB | blocked on #201 | blocked on #201 |
| `mistral-nemo:12b` | 6.6 GB | blocked on #201 | blocked on #201 |
| `qwen3:30b-a3b` | 17.3 GB | blocked on #201 | blocked on #201 |

### Empfehlung pro Hardware-Profil (Stage 2)

| Profil | Stage-2-Modell | Erwartete Latenz | Begründung |
|---|---|---|---|
| Minimal (8 GB RAM) | `qwen2.5:0.5b` | ~2s | klein genug, akzeptable Latenz, Output-Qualität schwankt |
| Komfort (16 GB RAM) | `qwen2.5:7b` | ~1.5s | bestes Verhältnis Latenz × Output-Qualität (heutiger Default) |
| Premium (32 GB RAM) | `qwen2.5:7b` (Stage 2) + `qwen3:30b-a3b` (Stage 3/4 Batch) | Stage 2 ~1.5s, Stages 3/4 minutenlang | mixed-Konfig — schnelle Live-Stage 2, hochwertige Batch-Stages 3+4 |

### Reproduzieren

```bash
ollama pull qwen2.5:0.5b qwen2.5:7b mistral-nemo:12b qwen3:30b-a3b
mix lore.bench_llm_stage2                      # alle 4 Default-Modelle, short+medium+long
mix lore.bench_llm_stage2 --skip-long          # ~5 min
mix lore.bench_llm_stage2 --models qwen2.5:7b  # einzelnes Modell
```

Stage-3+4-Bench-Task folgt nach #201.

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

Gemessen via `mix lore.bench_reader` (Issue #92) gegen den lokalen Worker-BEAM. Pumpt synthetic `UtteranceAppended`-Events in eine Bench-Campaign (eigene UUID, am Schluss via `CampaignDeleted` cascade-cleanup) und misst:

- **Cold-Apply**: `Worker.Materializer.apply_local/1`-Durchsatz (initial-Write)
- **Skip-Apply**: Re-Apply via `apply_event` mit `seq` (Hub-Catch-Up-Pfad, alle event_ids in `applied_event_ids` → skipped, nur Tx-Overhead)
- **get_campaign**: `Worker.Repo.get_campaign/1` (single Mnesia-Hash-Lookup), 200 Samples
- **snapshot**: `Worker.Repo.snapshot(%{"kind" => "campaign", ...})` (volle LiveView-Mount-Payload — Sessions + alle Utterances + Members + Summaries + Epos + Chronik), 200 Samples
- **Bytes/Event**: `:mnesia.table_info(:worker_campaign_events_<uuid>, :memory)` × wordsize / row-count

### Ergebnis

| Scale | Cold-Apply | Skip-Apply | get_campaign p50/p95 | snapshot p50/p95 | Bytes/Event (RAM) |
|---:|---:|---:|---:|---:|---:|
| 10 000 | 9 843 events/s | 11 923 events/s | 35µs / 49µs | 85.77ms / 98.87ms | 1 336 |
| 100 000 | 9 617 events/s | 11 889 events/s | 34µs / 39µs | 975.12ms / 1.08s | 1 336 |

### Erkenntnisse

- **Materializer-Throughput skaliert flach** (~10k events/s cold, ~12k events/s skip). Bei 100k Events erscheinen Mnesia-WAL-Warnings (`Mnesia is overloaded: {:dump_log, :write_threshold}`) — Standard-Backpressure, kein Datenverlust. Worker.Recording.Pipeline pumpt nie auch nur annähernd so schnell, kein praktischer Engpass.
- **`get_campaign/1` ist konstant ~35µs** über alle Skalen — Mnesia-Hash-Lookup auf der `campaigns`-Tabelle, unabhängig vom Utterance-Volumen. Sicherer Default-Read im Hot-Path.
- **`snapshot/1` skaliert LINEAR mit Utterance-Count** — bei 10k Events ~86ms, bei 100k Events ~975ms. Das ist der LiveView-Mount-Pfad (CampaignLive zieht den vollen Snapshot pro Page-Load). **Ab ~50k Utterances pro Kampagne wird das im UI spürbar.** Begründet das Stream-Refactoring der Protokoll-Spalte als Folge-Issue (#95-Ableitung).
- **RAM-Footprint pro Event ~1336 Bytes** (Mnesia-Row-Overhead + UtteranceAppended-Payload mit ~120-Byte-Text). Bei 100k Events: ~130 MB pro Campaign. Vergleichswert: Romeo-Schlegel-Demo (1159 Events) braucht 364 KB auf Disk — synthetic-Bench liegt RAM-side höher weil die `:memory`-Metrik den ungedumpten WAL mitzählt.

### Empfehlung

| Campaign-Größe (Utterances) | get_campaign | snapshot | UX-Bewertung |
|---:|---:|---:|---|
| < 1 000 | <50µs | <10ms | sofort |
| 1 000-10 000 | <50µs | ~100ms | OK |
| 10 000-50 000 | <50µs | ~500ms | spürbar |
| > 50 000 | <50µs | >1s | Stream-Refactoring nötig |

### Reproduzieren

```bash
mix lore.bench_reader                     # Default 10k + 100k
mix lore.bench_reader --scale 1000        # Single Custom-Scale
mix lore.bench_reader --scale 1000000     # 1M (≈ 5-10 min wegen Mnesia-WAL-Backpressure)
mix lore.bench_reader --keep              # CampaignDeleted-Cleanup überspringen
```

### Idempotenz-Test

`apps/worker/test/worker/materializer_replay_test.exs` — doppelter Apply derselben Event-Sequenz (CampaignCreated + SessionScheduled + 50 × UtteranceAppended) produziert identischen Mnesia-State. Alle Re-Apply-Calls sind `:skipped` via `applied_event_ids`-Lookup. Test läuft als Teil von `mix test`.

### Out of Scope

- **1M-Event-Skala**: läuft aber ~5-10 Minuten und Mnesia geht in heavy-WAL-Backpressure. Aktuell keine Production-Kampagne ist auch nur ansatzweise in dieser Größenordnung (Romeo-Schlegel hat 1159 Events). Eigenes Ticket falls relevant.
- **Multi-Worker-Materializer-Stress**: per-Worker bleibt die Mess-Baseline. Cross-Worker-Pull-Throughput ist eigenes Mess-Ticket.

## UI-Last-Test (#95)

Zwei Mess-Pfade: **Server-Side** (Hub-RPC, automatisierbar) + **Browser-Side** (Chrome DevTools, manuell). Server-Side-Numbers + Recipe sind hier, Browser-Side-Recipe + Akzeptanz-Kriterien direkt darunter.

### Server-Side: Hub.Reader.read End-to-End-Latenz

Gemessen via `:rpc.call` in einen laufenden PR-Test-Hub (`mix lore.pr_test.spawn`), gegen die Schlegel-Volltext-Variante (`mix lore.seed.romeo --variant schlegel-de`). 50 Samples pro Scope nach Warm-up. Inkludiert den Hub→Worker-WebSocket-Round-Trip, also realistischer als #92's worker-interne Snapshot-Latenz.

| Scope | Sessions | Utterances | p50 | p95 | external_size (Snapshot) |
|---|---:|---:|---:|---:|---:|
| `dashboard` | — | — | **0.20 ms** | 0.28 ms | 118 B |
| `campaign` (Schlegel-Volltext) | 24 | 977 | **21.86 ms** | 25.63 ms | **346.87 KB** |
| `campaign` (Paraphrase-Demo) | 5 | 97 | 3.87 ms | 4.19 ms | 70.46 KB |
| `session` (größte: Akt 1.1, 101 Utt) | — | 101 | 0.21 ms | 0.24 ms | 140 B¹ |

¹ Session-Scope materialisiert nur die Metadata (Utterances lädt der LV-Mount aus dem Campaign-Scope). Die kleine Number ist erwartet.

**Erkenntnisse:**
- Schlegel-Volltext-Campaign (977 Utterances → realistischer Power-User-Lasttest) wird in **~22 ms p50** serialisiert + zum Hub übertragen. **WebSocket-Initial-Frame ~347 KB**.
- Paraphrase-Variante (97 Utterances → typische Self-Hosting-Kampagne) liegt bei ~4 ms p50 / 70 KB. **5× weniger Utterances ergeben 5× weniger Latenz + 5× kleinere Payload** — konsistent mit #92's Linear-Scaling-Befund.
- Dashboard-Scope ist quasi-frei (118 B / 0.2 ms): keine Skalierungs-Probleme im Landing-View.

### Server-Side: LV-Mount-Latenz via Telemetry (#238)

`Hub.Telemetry` (Issue #238, gemerged 2026-05-26) loggt automatisch jeden LiveView-Mount mit `duration_ms`. **Kein extra Bench-Tool nötig — einfach ein paar Seiten im Browser anklicken und greppen:**

```bash
tail -f /tmp/pr-$PORT/hub.log | grep --line-buffered "phoenix.live_view.mount.stop"
# Beispiel-Output:
# [info] [telemetry] event=phoenix.live_view.mount.stop lv=Elixir.HubWeb.CampaignLive duration_ms=27
```

Beobachtete Range bei `HubWeb.CampaignLive` für die Schlegel-Volltext (während des manuellen Browser-Passes): **siehe `docs/Performance.md` nach nächstem manuellem Pass** (pending — der erste Manual-Pass wird die Numbers + Screenshots in dieses Doc übernehmen).

### Browser-Side: Manueller Chrome-DevTools-Pass

Server-Side-Numbers sagen: kein Bottleneck auf der Hub-Seite. Die offene Frage ist **Client-Side-Render** (HTML-Diff-Anwendung im Browser, Scrolling-FPS, Modal-Open-Latenz).

**Recipe:**

1. PR-Test-Stack hochfahren: `mix lore.pr_test.spawn` (seedet automatisch Paraphrase-Demo). Für die volle Schlegel-Last danach: `mix lore.seed.romeo --hub http://localhost:$PORT --as-admin <discord-id> --variant schlegel-de` (1159 Events, 24 Sessions, 977 Utterances).
2. Browser auf `http://localhost:$PORT/` → einloggen via Discord-OAuth → Dashboard.
3. Chrome DevTools öffnen → **Performance**-Tab.
4. Record-Button → klick auf die Romeo-Schlegel-Kampagne → warte bis voll gerendert → Stop. *Erwartung: < 1s bis interaktiv.*
5. Performance-Tab → "Scripting" + "Rendering" lesen. **Bottleneck-Indikatoren:**
   - Long Tasks > 50ms im Main-Thread während Mount
   - Layout-Shifts > 0.1 CLS
   - Forced Reflows in der Protokoll-Spalte
6. Scrolling-Test: in der Protokoll-Spalte (977 Utterances bei Schlegel) ganz nach unten scrollen. **Performance-Tab → FPS-Meter aktivieren** (Esc → "Rendering" → "Frame Rendering Stats"). *Erwartung: ≥ 50 FPS auf einem 8-Core Desktop.*
7. Modal-Open-Latenz: klick auf eine Utterance → Edit-Modal öffnet. *Erwartung: < 100ms Open-Animation.*

**Akzeptanz für #95 (was heißt „kein UI-Bottleneck"):**

| Metrik | Pass | Fail | Notiz |
|---|---|---|---|
| LV-Mount-Duration (Telemetry) | < 100 ms | > 500 ms | Server-side, aktuell ~22 ms p50 |
| Initial-Frame-Größe | < 500 KB | > 2 MB | Aktuell 347 KB |
| Scrolling-FPS (Protokoll-Spalte, 977 Utt) | ≥ 50 FPS | < 30 FPS | manueller Pass |
| Modal-Open-Latenz | < 100 ms | > 500 ms | manueller Pass |
| Long Tasks im Main-Thread | < 50 ms | > 200 ms | DevTools Performance-Tab |

**Falls Bottleneck identifiziert:** Folge-Issue für `phx-update="stream"`-Refactoring der Protokoll-Spalte in `campaign_live.ex` — Stream-API erlaubt Phoenix LiveView, inkrementelle Updates statt Voll-Re-Render des Listen-Containers. Reduziert Memory + CPU bei großen Listen drastisch.

### Stand 2026-05-26

- **Server-Side**: gemessen + dokumentiert (siehe Tabellen oben).
- **Browser-Side**: Recipe + Akzeptanz-Kriterien dokumentiert, manueller Pass ausstehend. Sobald ein Browser-Pass auf der Schlegel-Volltext-Demo gefahren wird, hier die Screenshots/Numbers ergänzen (FPS, Modal-Latenz). Pass-Fail-Status der Tabelle dann updaten.

### Umgesetzt (#321, 2026-05-29): Reload-Coalescing + async Snapshot

Beobachtetes Problem (penpaper-Single-Source-Lauf, 200 Utterances, qwen3:30b auf allen Stages): während eines Pipeline-Laufs stockte die Kampagnen-GUI sekundenlang. Ursache in `HubWeb.CampaignLive`: jedes Stage-Output-Event (`SessionSummaryGenerated`, `EposEntryEdited`, je `ChronikEntryChanged`, `SpeakerAssigned`) löste ein eigenes `:reload` aus → `load_snapshot` → **synchroner blockierender** `Hub.Reader.read` (bis 15s unter Ollama-Last) + Voll-Re-Render. Eine Event-Burst → N blockierende Reloads seriell → LV eingefroren.

Fix:
- **Coalescing**: `:reload`-Handler dedupliziert via `reload_state` (`:idle/:scheduled/:running`) — Burst von N Events → ~1-2 Reloads statt N (`load_snapshot` holt eh den Voll-Stand). `reload_dirty?` triggert einen Nachlauf für Events, die während eines laufenden Reads reinkamen.
- **Async**: der reaktive Snapshot-Read läuft über `start_async`/`handle_async` (LV 1.1.30) statt synchron im LV-Prozess → die GUI bleibt während des Worker-Round-Trips reagierbar. Initial-`mount` bleibt synchron (Page-Load, kein interaktiver Freeze).

Das #95-Stream-Refactoring der Protokoll-Spalte (inkrementelles Render statt Voll-Re-Render) bleibt der orthogonale, größere Folge-Schritt für sehr große Kampagnen.

## Selbst-Diagnose: Probelauf-UI

`/admin/probelauf` (Issue #74 / #88) ist die laufende Selbst-Diagnose. Admin kann jederzeit einen Single-Stage- oder Multi-Modell-Sweep gegen den eigenen Worker fahren und die Heuristik-Empfehlung („Modell X für Stage Y") direkt in `Worker.Settings` übernehmen.

## Bench-Tools — Übersicht

Alle Self-Diagnose-Tools sind unter `mix lore.*` aufrufbar. Nicht Teil von `mix test` (brauchen lokale Modelle / Ollama). Reproduzierbar pro Workstation.

| Tool | Misst | Laufzeit |
|---|---|---|
| `mix lore.stt_bench --all-models --all-sessions` | Whisper Stage 1: WER + RTF pro Modell × Fixture-Session | ~3-5 min (Modelle in Cache) |
| `mix lore.bench_reader` | Reader/Materializer-Skalierung: Throughput, Latenzen, Bytes/Event | ~30s pro Default-Skala |
| `mix lore.bench_llm_stage2` | LLM Stage 2 (Session-Summary): Median-Latenz pro Modell × Prompt-Größe | ~5-15 min (je nach Modell-Set) |
| `/admin/probelauf` (UI, #74/#88) | LLM Pipeline-Sweep (Stages 2/3/4) — laufende Selbst-Diagnose | ~10-30 min |

## Cross-Cutting

- **Cloud-LLM** (Anthropic via #27 Phase 1a, OpenAI/Google in #174/#175): wenn Worker-Hardware schwach ist, Cloud-Backends pro Stage konfigurierbar. Cost-Tracking via #177.
- **Pipeline-Re-Run** (Issue #104): pro Session ein „🔄 neu generieren"-Button — nützlich nach Modell-Wechsel.
- **Probelauf-Auto-Apply** (#88 Phase 2c): Sweep-Sieger automatisch in `Worker.Settings` schreiben.
- **Audio-Retention** (#97): Audio-Disk-Verbrauch wächst mit aktiver Recording-Zeit (~10 MB/h WebM) — Mnesia-Wachstum dagegen vernachlässigbar. Retention-Politik nötig wenn alle historischen Audio-Dateien permanent gespeichert.
- **Stream-Refactoring der Protokoll-Spalte**: aus #92-Bench abgeleitet — `Worker.Repo.snapshot` skaliert linear mit Utterance-Count. Bei >50k Utterances pro Kampagne wird LV-Mount spürbar. Folge-Issue nach #95-Profiling.

## Folge-Issues aus diesem Performance-Pass

- **#201** Stage-Isolation mit Goldstandard-Pre-Seed — entblockt faire LLM-Stage-3+4-Messung
- **#95** UI-Last-Test (manuelles Chrome-DevTools-Profiling) — pending
- *(neu)* Kurz-IDs im Stage-2/3-Prompt (`[u1]…[uN]` statt voller UUID) + Silent-Truncation-Guard — 60,7 % Token-Ersparnis, verschiebt das Context-Ceiling von ~1 600 auf ~4 040 utts (siehe „Stage 2 — Prompt-Token-Footprint")
- *(neu, Reserve)* Map-Reduce-Chunking für Stage 2 bei Sessions jenseits ~4 000 utts
- *(neu, nach #95)* Stream-Refactoring der Protokoll-Spalte falls UI-FPS unter 30 fällt
- *(neu)* STT-Throughput-Skalierung mit langen Audio-Fixtures (1/5/30 min) — bisher nur 4-30s-Turns
- *(neu)* Multi-Worker-Materializer-Stress (Cross-Worker-Pull-Throughput)
