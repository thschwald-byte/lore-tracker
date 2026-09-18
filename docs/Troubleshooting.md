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

**Fix**: Kleineres Modell wählen, oder `http_timeout_ms` in `/settings` hochsetzen. `http_timeout_ms` gilt für Resümee, Epos und die Registries; Jacks `/v1`-Client (Stufe 2) hat eine eigene Frist von 600 000 ms (`Worker.Agent.Modell.Ollama`), die in `/settings` nicht einstellbar ist. Die frühere Abhilfe für eine hängende Extraktion (`extract_chunk_tokens`, `extract_num_predict_cap`, #763) gibt es seit J4 (#1207) nicht mehr.

#### `extraction_empty`

**Was**: die Fakten-Extraktion hat 0 Fakten geliefert. Seit J4 (#1207) heißt das: Jacks Bestand enthielt keine gültige Aussage.

**Fix**: In der lokalen Laufsicht des Workers mitlesen, was Jack tut — der Port steht im Worker-Log (`Jack-Laufsicht: http://127.0.0.1:<port>`), Default 8099, eine Teststage nimmt Stage-Port + 10. **Antwortet dort eine leere Sicht, ist es womöglich die eines anderen Workers:** ein belegter Port lässt die eigene Sicht gar nicht starten (Warnung im Log), und der Lauf ist dann nicht beobachtbar. Anderes Modell in `/settings` → „Jack: Extract/verify“ (`model_stage2_local`) wählen — Jack arbeitet mit Werkzeugaufrufen über `/v1/chat/completions`, das Modell muss sie beherrschen. Prüfen, ob das Fenster, mit dem Ollama das Modell lädt (Modelfile `num_ctx` bzw. `OLLAMA_CONTEXT_LENGTH`), zu `ctx_jack` passt — der Worker setzt es für Jack nicht selbst.

#### Jack (Stufe 2): `ctx_jack_ungueltig` und `other` mit `{:jack, …}`

**Was**: `ctx_jack_ungueltig` — `ctx_jack` liegt unter Jacks Mindestfenster oder ist keine ganze Zahl; Jack startet für diese Session nicht. Jack-eigene Gründe haben **keine** eigene Fehlerklasse und erscheinen als `other`, mit dem Grund in der Meldung (`Fehler: {:jack, …}`):

- `:blockliste_geaendert` — „noch N Iterationen“ auf einer Sitzung, deren Blockliste sich seit Jacks letztem Lauf geändert hat (neu geglättet, ein Block `unbrauchbar`). Jacks Blocknummern gelten nur für die Liste, auf der er lief; statt verrutschter Belege lehnt der Worker ab.
- `:kein_stand` / `:blockliste_unbekannt` — für diese Sitzung liegt kein abgelegter Stand vor bzw. der Stand trägt keine Blockliste.
- `:keine_glaettung` — „noch N Iterationen“ auf einer Sitzung ohne gespeicherte Glättung.
- eine Phase ohne `fertig()` — Gedächtnis oder Extraktion endete, ohne abzuschließen (die Laufzeit hakt vorher bis zu dreimal nach).

**Fix**: `ctx_jack` in `/settings` → „Jack: Extract/verify“ auf mindestens das Mindestfenster setzen (Default 98 304), passend zu dem Fenster, mit dem Ollama das Modell lädt. Bei `blockliste_geaendert`, `kein_stand`, `blockliste_unbekannt` und `keine_glaettung`: statt „noch N Iterationen“ die Sitzung ganz neu generieren (🔄). Bei einer Phase ohne `fertig()`: in der lokalen Laufsicht nachlesen, wo Jack aufhörte, ggf. anderes Modell.

#### `sidecar_offline`

**Was**: ein Python-Sidecar ist nicht erreichbar. Heute betrifft das nur noch den Diarisierungs-Sidecar der Raummikro-Aufnahme (`:diarization_sidecar_url`); der NLI-Sidecar ist seit #1124 entfallen, das Verify-Gate, das ihn optional nutzte, seit J4 (#1207).

**Fix**: siehe `docs/Worker-Setup.md` → „Diarisierungs-Sidecar“ (venv vorhanden? `curl http://localhost:8766/health`).

#### `no_verified_facts`

**Was**: Render ohne verifizierte Fakten — der Bestand, der beim Render ankommt, enthält keinen Fakt mit `verified? = true`.

**Fix**: Ursache liegt VOR dem Render. Seit J4 (#1207) setzt Jack `verified?` für jede Aussage, und ein leerer Jack-Bestand endet schon vorher als `extraction_empty`. Bleibt die Klasse, lohnt der Blick in die Fakten-Spalte (Bearbeitenmodus: ausgeblendete Fakten, `verified?`-Override) — oder die Sitzung trägt noch Fakten aus der Zeit vor J4; dann neu generieren. Den Verify-Trichter des Probelaufs und die Stufe-3-Einstellungen gibt es nicht mehr.

_Historische Fehlerklassen (`empty_chronik`, `no_summary`, `no_epos`) stammen aus der mit #786 entfernten Chain-Pipeline, `all_chunks_failed` und `truncated_salvaged` (#1115) aus der mit J4 (#1207) entfernten Extraktion — alte Einträge in `/admin/errors` bleiben lesbar, neue entstehen nicht mehr._

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
