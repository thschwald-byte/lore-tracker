# LoreTracker — Worker auf dem eigenen Rechner einrichten

Diese Anleitung beschreibt wie du den **Worker-Teil** lokal aufsetzt. Den
**Hub** musst du nicht selbst betreiben — die Produktiv-Instanz läuft auf
<https://loretracker.gigalixirapp.com> und dein Worker verbindet sich
dorthin. Wenn du auch lokal entwickelst, läuft daneben ein lokaler Hub auf
`http://localhost:4000`.

> **TL;DR**: Erlang/Elixir + ffmpeg + whisper.cpp + Ollama installieren →
> Repo klonen → `mix deps.get` → Worker mit deinem Hub-Pairing starten.
> Audio wird auf deiner Maschine transkribiert, LLM-Stages laufen auf
> deiner Maschine, nur die fertigen Events landen am Hub.

## 1. Software-Voraussetzungen

| Was | Version | Wofür | Installations-Hinweis |
|---|---|---|---|
| **Erlang/OTP** | 27 oder neuer | BEAM-VM | CachyOS/Arch: Paket `erlang-headless` (nicht nur `erlang-core` — fehlen Module). Ubuntu: `erlang`. macOS: `brew install erlang`. |
| **Elixir** | 1.19 oder neuer | Sprache | CachyOS/Arch: `elixir`. macOS: `brew install elixir`. Prüfen mit `elixir --version`. |
| **ffmpeg** | jede Version mit Opus + WAV-Encoder | Audio-Konvertierung Browser-Opus → 16-kHz-WAV für Whisper | Standard-Paket aller Distros. |
| **whisper.cpp** | aktuell, mit `whisper-cli`-Binary | Lokale Audio-Transkription (Stage 1) | <https://github.com/ggerganov/whisper.cpp> bauen oder Distro-Paket (`whisper-cpp` auf Arch/CachyOS). |
| **Whisper-Modell** | `ggml-small.bin` (empfohlen) | wird vom whisper-cli geladen | Per `bash models/download-ggml-model.sh small` im whisper.cpp-Tree. Default-Pfad: `~/.cache/whisper/ggml-small.bin`. `ggml-medium.bin` für noch bessere Qualität (ca. 4× langsamer als small). `ggml-base.bin` läuft, aber deutlich schlechtere Erkennungsrate. |
| **Ollama** | aktuell | Lokales LLM-Backend für Stages 2-4 (Resümee/Epos/Chronik) | <https://ollama.com> — Daemon läuft auf `http://localhost:11434`. |
| **Ollama-Modell** | `qwen2.5:7b` (Default) | wird via Ollama gepullt | `ollama pull qwen2.5:7b`. Pro Stage in der UI änderbar. |
| _(optional)_ Silero-VAD | `silero-v5.1.2.bin` | Voice-Activity-Detection für Live-Modus (Stage 1) | <https://github.com/snakers4/silero-vad> — nur nötig wenn du Transkribieren-Modus `live` benutzen willst statt `batch`. |

## 2. Repo klonen + Deps installieren

```bash
git clone https://codeberg.org/tomloresys/lore-tracker.git
cd lore-tracker
mix deps.get
mix compile
```

Falls `mix` „erlang module not found" wirft → du hast nur das Erlang-Core,
nicht das Headless-Paket (siehe Tabelle oben).

## 3. Konfiguration

### `.env`-Datei

Im Repo-Root liegt `.env.example` als Vorlage. Kopiere zu `.env` und fülle
mindestens die Discord-OAuth-Credentials aus — die braucht der **Hub** für
das User-Login. Wenn du nur einen Worker gegen den Prod-Hub betreibst und
keinen lokalen Hub fährst, kannst du die meisten Variablen leer lassen.

| Env-Variable | Wofür | Pflicht? |
|---|---|---|
| `DISCORD_CLIENT_ID` | OAuth-Login am Hub | nur für lokalen Hub |
| `DISCORD_CLIENT_SECRET` | OAuth-Secret | nur für lokalen Hub |
| `LORE_JWT_SECRET` | Hub-Side: signiert Worker-Pairing-JWTs (HS256, RFC 7519). Generieren via `openssl rand -base64 32`. Hub raised beim Boot wenn nicht gesetzt (in :prod). | nur für lokalen Hub, in :prod required |
| `HUB_BASE_URL` | überschreibt das Default `http://localhost:4000`, z.B. auf `https://loretracker.gigalixirapp.com` für Prod-Pairing | optional, per Befehlszeile setzbar |
| `LORE_MNESIA_DIR` | Mnesia-Daten-Verzeichnis dieses BEAMs | optional; Default `priv/mnesia/dev` |
| `LORE_WORKER_SETUP_PORT` | Setup-Endpoint-Port (Pair-Flow im Browser) | optional; Default `4080` |

`.env` wird **nicht** committet (ist in `.gitignore`). Die Datei wird zur
Laufzeit per `dotenvy` aus dem Repo-Root gelesen.

### Worker-Settings (UI-tunbar zur Laufzeit)

Sobald der Worker läuft und gepaird ist, sind alle Worker-Settings über
`/settings` im Browser editierbar — pro Stage Backend/Modell/Sampling-
Parameter, Whisper-Pfade, System-Pfade. Defaults stehen in
`apps/worker/lib/worker/settings.ex`. Keine Code-Änderung nötig, kein
Worker-Restart bei Setting-Änderungen.

## 4. Ports

| Port | Wer | Pflicht? |
|---|---|---|
| `4000` | Lokaler Hub (`mix phx.server`) | nur bei lokalem Hub |
| `4001-4005` | PR-Test-Hubs (siehe Dev-Workflow) | nur bei lokalem PR-Test |
| `4080` | Worker-Setup-Endpoint (Pair-Flow im Browser) | bei jeder Worker-Erst-Pairing |
| `11434` | Ollama-Daemon | immer (Stages 2-4) |

Discord-OAuth-Redirects müssen in der Discord-App-Console hinterlegt sein:
`http://localhost:4000/auth/discord/callback` für den Standard-Hub, weitere
4001-4005 falls du mehrere Hub-Instanzen parallel laufen lässt.

## 5. Erster Start

### Variante A — Worker gegen Prod-Hub (gigalixir)

Du betreibst nur einen Worker, der sich mit der produktiven Hub-Instanz
verbindet. Empfohlen wenn du keine eigene Hub-Entwicklung betreibst.

```bash
cd apps/worker
LORE_MNESIA_DIR=$(pwd)/../../priv/mnesia/prod-worker \
HUB_BASE_URL=https://loretracker.gigalixirapp.com \
elixir --sname worker_prod --no-halt -S mix run
```

Beim ersten Start sieht der Worker „kein Pairing vorhanden", öffnet sein
Setup-Endpoint auf `http://localhost:4080/setup` und schreibt das in den
Log. Browser dahin → durch den Discord-OAuth-Flow klicken → das Token wird
lokal in der Worker-Mnesia abgelegt. Worker beim nächsten Start ist
bereits gepaird.

### Variante B — Lokaler Hub + lokaler Worker

Für Entwicklung. Hub und Worker laufen als **zwei separate BEAMs**, jeder
mit eigener Mnesia.

Terminal 1 — Hub:

```bash
cd apps/hub
mix phx.server
# Hub läuft auf http://localhost:4000 (Mnesia in priv/mnesia/dev/)
```

Terminal 2 — Worker:

```bash
cd apps/worker
LORE_MNESIA_DIR=$(pwd)/../../priv/mnesia/dev-worker \
elixir --sname worker --no-halt -S mix run
# HUB_BASE_URL ist nicht nötig — Default ist http://localhost:4000
```

Pair-Flow analog: Browser auf `http://localhost:4080/setup`, durch
Discord-OAuth, fertig.

### Erste Smoke

1. Browser auf `http://localhost:4000` (oder Prod-URL) → mit Discord
   einloggen.
2. „+ Kampagne gründen" → Name eintragen.
3. „Einladung erstellen" → Link kopieren → an Mitspieler.
4. In der Kampagnen-Ansicht **REC** klicken — jeder Mitspieler öffnet
   die Kampagne im eigenen Browser und klickt **Mit Mikro beitreten**.
5. **Stopp** → Pipeline läuft (Whisper transkribiert, LLM-Stages
   generieren Resümee/Epos/Chronik). Browser zeigt Fortschritt live.

## 5b. Optional — Faithfulness-Sidecar (Issue #11 Phase 2)

Der NLI-Sidecar bewertet jedes generierte Resümee gegen das Quell-Transkript
(Score pro Satz/Claim: entailment / neutral / contradiction). Im Hub erscheint
neben jedem Resümee ein farbiger 📊-Badge mit dem Gesamtscore; Klick auf
den Badge zeigt die einzelnen Claims mit Per-Claim-Label.

**Ohne Sidecar läuft die Pipeline normal weiter** — der Score-Badge taucht
einfach nicht auf. Wer den Score sehen will, einmalig einrichten:

```bash
# 1) Python-venv anlegen + Deps
python3 -m venv ~/.venvs/faithfulness-sidecar
~/.venvs/faithfulness-sidecar/bin/pip install -r apps/worker/priv/sidecar/requirements.txt

# 2) Manuell starten (für Test)
cd apps/worker/priv/sidecar
~/.venvs/faithfulness-sidecar/bin/uvicorn faithfulness_sidecar:app --port 8765
# erster Start lädt cross-encoder/nli-deberta-v3-large (~400 MB) ins
# HuggingFace-Cache; danach <2 s Startzeit.

# 3) Health-Check
curl http://localhost:8765/health   # → {"status":"ok","loaded":true,...}

# 4) Worker-Setting auf den Sidecar zeigen lassen
#    (im laufenden Worker, iex-Session):
iex> Worker.Settings.put(:faithfulness_sidecar_url, "http://localhost:8765")
```

Für Autostart als Systemd-User-Service:

```bash
cp apps/worker/priv/sidecar/faithfulness-sidecar.service \
   ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now faithfulness-sidecar.service
systemctl --user status faithfulness-sidecar.service
```

Das Unit-File geht vom venv unter `~/.venvs/faithfulness-sidecar/` und vom
Repo unter `~/Projekte/lore_tracker2/` aus — beide Pfade ggf. im Service-File
anpassen.

**Setting wieder ausschalten**: `Worker.Settings.put(:faithfulness_sidecar_url, nil)`
— Pipeline überspringt die Stage dann.

## 6. Troubleshooting

| Symptom | Wahrscheinliche Ursache | Fix |
|---|---|---|
| `** (Mix) Could not start application worker: ... schema, :unknown` | Mnesia-Schema gehört einem anderen Node-Namen | `--sname` muss zum Schema im Mnesia-Dir passen (z.B. `worker` für `dev-worker/`, `worker_prod` für `prod-worker/`). Schema in `schema.DAT` ist node-bound. |
| Worker bleibt bei „kein Pairing vorhanden" | Browser-Tab beim Pair-Flow vorher zu früh geschlossen | Browser nochmal auf `http://localhost:4080/setup` → durchklicken |
| Discord-OAuth `redirect_uri mismatch` | Hub läuft auf nicht-registriertem Port | In der Discord-App-Console unter „Redirects" alle benutzten Ports + `/auth/discord/callback` eintragen |
| LLM-Pipeline-Stages laufen ewig | Modell zu groß für deine Hardware, oder Ollama nicht erreichbar | In `/settings` ein kleineres Modell wählen (z.B. `qwen2.5:0.5b`) oder `local_endpoint` prüfen |
| Whisper transkribiert nichts | falscher Modell-Pfad oder Whisper-CLI nicht im `$PATH` | `which whisper-cli` und `ls ~/.cache/whisper/ggml-base.bin` prüfen; in `/settings` Stage 1 → `whisper_bin` / `whisper_model` setzen |
| Kein 📊-Badge an den Resümees, aber Sidecar läuft | `:faithfulness_sidecar_url` ist nicht gesetzt | `Worker.Settings.put(:faithfulness_sidecar_url, "http://localhost:8765")` in der Worker-iex |
| `Faithfulness sidecar returned 503` im Worker-Log | Sidecar startet noch, Modell lädt aus dem HF-Cache | Einmal `curl http://localhost:8765/health` ausführen und warten bis `loaded: true` — Pipeline überspringt die Stage graceful |

## Weiterführend

- **Dev-Workflow + Architektur**: `CLAUDE.md` im Repo-Root
- **Spieler-Sicht** (Browser-UI nutzen): `docs/Spieler-Anleitung.md`
- **Mehrere Hub-Instanzen parallel** (PR-Test-Pattern): Abschnitt
  „PR-test instances" in `CLAUDE.md`
