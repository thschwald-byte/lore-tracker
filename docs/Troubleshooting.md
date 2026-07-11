# Troubleshooting

Self-Hosted-Spielleiter sehen Pipeline-Fehler im Hub unter `/admin/errors`. Jede Error-Row trägt einen **Recovery-Hint** mit konkretem Fix-Schritt (Issue #68 Phase 2). Diese Doku ist die Langform — eine schnelle Liste pro Error-Type, plus „wo finde ich Logs", „wie hänge ich an LoreTracker mit", und „wann ist es ein Bug, den ich melden sollte".

## Wo sind die Logs?

| Setup | Log-Pfad |
|---|---|
| **Lokaler Hub** (`mix phx.server` in `apps/hub`) | Direkt im Terminal |
| **Lokaler Worker** (`mix run`) | Direkt im Terminal des Worker-Prozesses |
| **PR-Test-Stack** (`mix lore.pr_test.spawn`) | `/tmp/pr-<port>/hub.log` und `/tmp/pr-<port>/worker-0.log` |
| **Gigalixir prod** | `gigalixir logs -a loretracker -f` (nur Hub; Worker läuft lokal beim Self-Hoster) |

Strukturiert in der UI: `/admin/errors` (Admin-only) zeigt die letzten 50 `PipelineErrorLogged`-Events mit Stage, Type, Message, Context und Retry-Button.

## Error-Types und ihre Fixes

### Cloud-LLM (Anthropic / OpenAI / Google)

#### `no_key_configured`

**Was**: API-Key-Env-Var ist nicht gesetzt im Worker-Prozess.

**Fix**: Setze die passende Variable und starte den Worker neu:

```bash
ANTHROPIC_API_KEY=sk-ant-...
OPENAI_API_KEY=sk-proj-...
GEMINI_API_KEY=AIza...
```

Keys leben pro Worker als Env-Var (seit Etappe 5b, Issue #162) — der Hub kennt keine Cloud-Credentials.

#### `upstream_auth` (401 / 403)

**Was**: API-Key ungültig oder dein Account-Tier deckt das gewählte Modell nicht ab.

**Fix**:
1. API-Key im Provider-Dashboard prüfen (Anthropic Console / OpenAI Platform / Google AI Studio)
2. Bei 403: anderes Modell in `/settings` wählen — manche Modelle (z.B. `gpt-4o`, `gemini-2.5-pro`) brauchen kostenpflichtige Tiers

#### `upstream_rate_limit` (429)

**Was**: Provider-Rate-Limit erreicht (zu viele Calls pro Minute).

**Fix**: Auto-Retry mit exponentiellem Backoff läuft schon (2 Retries). Bei häufigem Wiederauftreten:
- Quota beim Provider prüfen (Billing-Page)
- Throughput senken: weniger gleichzeitige Sessions, oder Modell mit höherem RPM-Cap wählen

#### `upstream_error` (5xx)

**Was**: Provider hat einen Server-Fehler.

**Fix**: Retry läuft automatisch. Bei wiederholtem 5xx: Provider-Status-Page checken (z.B. status.anthropic.com).

#### `spend_cap_exceeded`

**Was**: Per-User-Monats-Cap (Issue #178) für Cloud-Calls ist erreicht.

**Fix**: Admin kann den Cap in `/admin/users` hochsetzen, oder bis zum Monatsanfang warten (Cap-Reset).

### Ollama (Lokales LLM-Backend)

#### `ollama_unreachable`

**Was**: Ollama-Daemon antwortet nicht (Connection refused).

**Fix**:
```bash
ollama serve  # Daemon starten
```

Default-Port: `11434`. Firewall darf den nicht blocken. Bei Docker-Setup: `localhost` ist im Container nicht der Host — `host.docker.internal` (Mac/Win) oder `172.17.0.1` (Linux) nutzen.

#### `model_not_found`

**Was**: Das in `/settings` konfigurierte Ollama-Modell wurde nicht gepullt.

**Fix**:
```bash
ollama pull qwen2.5:7b
ollama pull <dein-modell>
```

Genauer Modell-Name in `/settings` checken. Format: `name:tag` (Tag = Quantisierung/Size).

### Netzwerk

#### `network_error`

**Was**: Worker erreicht den Provider gar nicht (DNS-Fail / Connection-Drop).

**Fix**: Internet-Verbindung, Firewall, und (bei Self-Host gegen Cloud-Hub) `HUB_BASE_URL` prüfen.

### Pipeline-Stage-Logik

#### `timeout`

**Was**: LLM hat nicht innerhalb von `http_timeout_ms` geantwortet (Default 20 min).

**Fix**: Kleineres Modell wählen, oder `http_timeout_ms` in `/settings` hochsetzen. Wenn die Extraktion hängt: `extract_chunk_tokens` senken / `extract_num_predict_cap` prüfen (#763 — degenerierende Chunks werden nach dem Cap automatisch halbiert-erneut versucht).

#### `extraction_empty` / `all_chunks_failed`

**Was**: die Fakten-Extraktion hat 0 Fakten geliefert bzw. kein Chunk hat verwertbares JSON produziert.

**Fix**: Anderes Modell mit sauberem JSON-Mode wählen (`model_stage2_<backend>` in `/settings`; die Probelauf-Heuristik unter `/admin/probelauf` empfiehlt eines). Bei reasoning-Modellen (`qwen3:30b-a3b`, gpt-oss): `model_stage2_local_endpoint` auf `:chat` stellen (#736).

#### `sidecar_offline`

**Was**: das Verify-Gate erreicht den NLI-Sidecar nicht (nur bei `grounding_method: :nli`).

**Fix**: Sidecar starten bzw. `faithfulness_sidecar_url` in `/settings` prüfen — oder `grounding_method` auf `:llm_judge` (Default) lassen.

#### `no_verified_facts`

**Was**: Render ohne verifizierte Fakten — Extraktion lieferte Fakten, aber das Verify-Gate hat keinen einzigen als `verified?` durchgelassen.

**Fix**: Ursache liegt VOR dem Render. Verify-Trichter im Probelauf ansehen (`n_facts → n_grounded → n_verified`): bei niedriger Grounding-Rate source_refs-Dichte/Extraktor-Modell prüfen, bei niedriger Attributions-Rate ein stärkeres `judge_model` setzen.

_Historische Fehlerklassen (`empty_chronik`, `no_summary`, `no_epos`) stammen aus der mit #786 entfernten Chain-Pipeline — alte Einträge in `/admin/errors` bleiben lesbar, neue entstehen nicht mehr._

### Pairing / Worker

#### `no_worker_token`

**Was**: Worker hat keinen Hub-Token (re-pair oder erste Inbetriebnahme).

**Fix**: In `/settings` → „Worker neu pairen" durchklicken. Das macht einen frischen JWT (Issue #160).

### Whisper (Stage 1 / Audio)

#### `whisper_binary_missing`

**Was**: `whisper-cli` ist nicht im PATH (Default-Setting) oder der explizite Pfad in `/settings` existiert nicht.

**Fix**: [whisper.cpp](https://github.com/ggerganov/whisper.cpp) builden + den Binary ins PATH legen, oder vollen Pfad in `/settings` → `whisper_bin` setzen.

#### `whisper_model_missing`

**Was**: Das in `/settings` → `whisper_model` konfigurierte File existiert nicht.

**Fix**: Modell downloaden (z.B. `ggml-base.bin` aus huggingface.co/ggerganov/whisper.cpp) und Pfad in `/settings` korrigieren.

#### `whisper_failed`

**Was**: Whisper-Prozess ist abgebrochen.

**Fix**: Worker-Log checken (siehe „Wo sind die Logs" oben). Häufige Ursachen:
- Korruptes WAV-File (zu kurz, falsches Format)
- Zu wenig RAM für das gewählte Modell (`ggml-large` braucht ~5 GB)
- Whisper-Binary-Version zu alt (`whisper.cpp` Update pullen)

#### `whisper_empty`

**Was**: Whisper lieferte keinen Text — Audio war stumm oder zu kurz.

**Fix**: Mikro-Setup checken. Browser-Konsole bei phx-Hook `RecordMic` zeigt RMS-Levels — wenn die immer 0 sind, ist das Mikro nicht angemeldet.

#### `whisper_sidecar_offline`

**Was**: Diarisierungs-Sidecar (Single-Source-Mode, Issue #19) ist nicht erreichbar.

**Fix**: `diarization_sidecar` (Python/uvicorn-Prozess) starten — siehe `docs/Worker-Setup.md` für den Setup-Befehl mit der venv.

## Wann ist es ein Bug?

Wenn:
- Der Error-Type **nicht in der obigen Liste** auftaucht (in `/admin/errors` als „unbekannt" gerendert) und du keinen Recovery-Pfad findest
- Der Recovery-Hint **nicht hilft**, weil dein Setup-Detail abweicht
- Der Error **mehrmals trotz Retry** wiederkommt

→ Issue auf [Codeberg](https://codeberg.org/tomloresys/lore-tracker/issues) öffnen mit:
1. Stage + Error-Type
2. Volle Error-Message + Context-Block (aufgeklappt in `/admin/errors`)
3. Worker-Log-Auszug der letzten 50 Zeilen rund um den Fehler
4. Modell + Backend in `/settings` zum Zeitpunkt des Fehlers

## Weitere Anlaufstellen

- [`docs/Worker-Setup.md`](Worker-Setup.md) — Erst-Setup für Self-Hoster
- [`docs/Spieler-Anleitung.md`](Spieler-Anleitung.md) — User-facing
- [`docs/Backup-Recovery.md`](Backup-Recovery.md) — Mnesia-Disaster-Recovery
- Codeberg-Tracker: https://codeberg.org/tomloresys/lore-tracker/issues
