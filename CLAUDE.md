# ⛔ HARTE REGELN (nicht verhandelbar, gelten in JEDER Session)

1. **SPRACHE: Antworte in JEDER Chat-Ausgabe auf Deutsch.** Ausnahmslos — auch
   technische Erklärungen, Status-Updates, Rückfragen. Gilt unabhängig davon, in
   welcher Sprache Code, Logs oder frühere Nachrichten sind. Diese Regel gilt auch
   direkt nach einer Context-Compaction weiter; wenn du unsicher bist, ob eine frühere
   Sprachanweisung noch im Kontext steht, gilt: Deutsch.

(Weitere harte Regeln folgen hier später — Platzhalter, noch nicht befüllen.)

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Language

Tom (the maintainer) is most fluent in German — sorry about that. The rest of this file, plus most CLAUDE.local.md notes, commit messages, issue bodies and PR descriptions, are written in German for that reason. External readers (non-German contributor, public repo audit) may encounter this file in a language they don't speak — that's expected and not something Claude Code should work around by replying in a different language.

## Architecture

Umbrella layout (apps share `_build/`, `deps/`, `mix.lock`, and `config/config.exs` at the repo root):

- **`apps/shared`** — library app (no `mod:` in `application/0`), intended for code reused by the others. Add it as `{:shared, in_umbrella: true}` in sibling `deps/0` when consuming it.
- **`apps/hub`** — OTP application, supervisor tree rooted at `Hub.Supervisor` via `Hub.Application`.
- **`apps/worker`** — OTP application, supervisor tree rooted at `Worker.Supervisor` via `Worker.Application`.

Children lists in both `Application.start/2` callbacks are empty — adding processes to a tree means editing those files.

Requires Elixir `~> 1.19` (declared per-app, not at the umbrella root).

## Commands

Run from the repo root unless noted. `mix` walks every umbrella app.

- `mix deps.get` — fetch deps into shared `deps/`
- `mix compile`
- `mix format` — formatter config at root recurses into `apps/*` via `subdirectories:`
- `mix test` — runs the whole umbrella
- `mix cmd --app hub mix test` — run only one app's tests (or `cd apps/hub && mix test`)
- `mix test apps/hub/test/hub_test.exs:5` — single test by file:line (path is relative to repo root)
- `mix credo --checks LoreTracker.Credo.Check` — AST-Linter (Issue #544). Die 5 vormaligen lore.audit-Regeln + ein God-Module-Check (`module_too_long`, #544-Headline) + zwei Präventions-Checks (Issue #614: `raw_event_bridge_publish` flaggt rohes `EventBridge.publish` in LiveViews → erzwingt den `Publisher.publish/2`-Cold-Fail-Flash, schließt die Silent-Failure-Klasse #613; `unescaped_markdown_render` flaggt `Earmark.as_html(…, escape: false)` im hub_web-Layer → schließt die Stored-XSS-Klasse #604 am Definitionspunkt, deckt damit auch `.heex`-konsumierte Render-Pfade) als Custom-Checks (`tools/credo/*.ex`, via `.credo.exs` `requires:`). **CI nutzt Full-Scan, blockend** (seit #793): `mix credo --checks LoreTracker.Credo.Check` scannt das ganze Umbrella; **JEDER** Verstoß rotet den PR-Check und blockt den Merge (exit 16 bei Findings, 0 sauber). Der Bestands-Backlog wurde vorher auf 0 geräumt (#789: 21 Event-Kind-Literale in `legacy_event_backfill` → `Shared.Events`-SSoT; #791: `transcribe.ex`-God-Module-Split → `Transcribe.Confidence`). Kein `failure: ignore` mehr (analog Dialyzer #619 / Coverage #658; #557-Lesson erfüllt: erst beobachten, dann blockieren). Der Full-Scan braucht keinen merge-base → die frühere Diff-Scope-`git-fetch`/unshallow-Mechanik samt Flake-Risiko ist entfallen. Der Regex-basierte `mix lore.audit` (#535) wurde schon früher **abgelöst + entfernt**.
- `mix dialyzer` — Typ-Analyse (Issue #540). Fängt Spec-Drift / unmögliche Guards / dead `{:error,_}`-Pfade. Erster Lauf baut den PLT (`priv/plts/`, ~2,5 min, gitignored); danach ~1 min. **Findings-Cleanup ist durch (Issue #589: 80 → 0 actionable Findings über 4 Cuts).** `mix dialyzer` läuft sauber durch (`done (passed successfully)`). Die `.dialyzer_ignore.exs`-Baseline hält **genau einen** bestätigten Dep-FP (`Phoenix.Tracker.update/5`-Success-Typing, Cut 2); alle anderen Suppressions sind co-lokierte `@dialyzer {:nowarn_function}`/`{:no_opaque}`-Attribute mit Begründung am Code (intentionale Boundary-Defense, anon halt-Closures, dev-Tooling-Confusion). CI-Step läuft **auf PRs + master-Push** und ist seit #619 **blockend** (kein `failure: ignore` mehr) — ein neues actionable Dialyzer-Finding rotet den PR-Check und blockt den Merge (echtes Merge-Gate; der #603-warn-Soak ist gelaufen, #557-Lesson erfüllt: erst beobachten, dann blockieren). Neue Dep-FPs gehören **vor** dem Merge mit Begründung in `.dialyzer_ignore.exs`. Kein PLT-Cross-Pipeline-Cache auf Codeberg, daher ~3,5 min/PR (sequenziell **nach** `test`, seit Issue #668 — die frühere `depends_on: [compile]`-Parallelität sprengte den Codeberg-Runner-RAM, weil zwei Dep-Compiles in unterschiedlichen MIX_ENVs gleichzeitig liefen → graceful-stop ohne echten Fehler).
- `mix lore.coverage_floor` — Per-Modul-Coverage-Floors (Issue #537; ExCoveralls kennt nur einen globalen `minimum_coverage`). Ratchet auf dem heutigen Stand pro kritischem Modul (Permissions 80 %, EventBridge 88 %, Commands 30 %, Materializer 70 %, Pipeline 35 %, Repo 68 %, CloudHelper 60 %). Braucht vorher `mix coveralls.json` pro App. CI-Step **seit #658 blockend** (vorher `failure: ignore`-Warn-Soak, der einen CloudHelper-Breach still durchließ — `failure: ignore` entfernt, analog Dialyzer #619). Deterministisch (kein LLM) → kein Flaky-Risiko; ein Floor-Unterschritt rotet den PR-Check.
- `iex -S mix` — start all apps in an IEx session

## Hub: zero persistent state

**Seit Issue #164 (Etappe 5c, hub-v1.0.0) hat der Hub keine Datenbank mehr.** Keine Postgres-Dep, keine Mnesia-Tabellen, kein Ecto-Repo. Application-Tree: nur Phoenix.PubSub + Phoenix.Tracker + Phoenix.Endpoint + RAM-Caches.

Etappen-History der Hub-State-Reduktion:

- Issue #154 (Etappe 4c) → `events`-Tabelle weg. Kanonische Events leben in den Workern (per-Campaign-Stores `worker_campaign_events_<uuid>` + `worker_events_global`), via Pull-Mechanik (Issue #131 + #141) zwischen Workern synchronisiert. Hub ist nur noch PubSub-Router (`Hub.Events.broadcast/3`).
- Issue #160 (Etappe 5a) → `worker_tokens`-Tabelle weg. Pairing/Channel-Auth läuft über JWT (RFC 7519, HS256) via `Hub.WorkerJWT`, signiert mit `LORE_JWT_SECRET`.
- Issue #162 (Etappe 5b) → `cloud_keys`-Tabelle weg. Worker calls Cloud-LLMs (Anthropic) direkt mit pro-Worker `ANTHROPIC_API_KEY`-Env-Var. Kein Hub-LLM-Proxy mehr.
- Issue #164 (Etappe 5c) → `Hub.Repo` + `Hub.Release` + ecto_sql/postgrex/cloak-Deps + `apps/hub/priv/repo/migrations/` + `LORE_STORAGE_BACKEND`/`DATABASE_URL`/`LORE_CLOAK_KEY` alles weg.

**Required env-vars für den Hub:**
- `LORE_JWT_SECRET` (Base64, ≥32 Bytes). `openssl rand -base64 32`. Im :prod-Block der `runtime.exs` required.
- `SECRET_KEY_BASE` (Phoenix-Cookie-Signing).
- `DISCORD_CLIENT_ID` + `DISCORD_CLIENT_SECRET` (OAuth).

**Required env-vars pro Worker** (nur wenn der Worker Cloud-LLM-Backends nutzt):
- `ANTHROPIC_API_KEY`. Setting `:backend_stage{n} == :anthropic` ohne Env-Var → Pipeline-Stage scheitert mit `:no_key_configured`.
- `OPENAI_API_KEY`. Setting `:backend_stage{n} == :openai` ohne Env-Var → Pipeline-Stage scheitert mit `:no_key_configured`. (Issue #174, Phase 1)
- `GEMINI_API_KEY`. Setting `:backend_stage{n} == :google` ohne Env-Var → Pipeline-Stage scheitert mit `:no_key_configured`. (Issue #175, Phase 1)
- `DISCORD_BOT_TOKEN` (optional, nur für Discord-Bot-Voice-Capture, Epic #985 — s. Abschnitt unten). Settings-first-then-ENV-Fallback wie die LLM-Keys (`Worker.Discord.BotToken`).

Event-Producer im Hub (LiveViews, Controllers, Mix-Tasks) erzeugen Events nicht mehr selbst — sie delegieren via `Hub.EventBridge.publish/1-2` an einen online Worker, der Worker-First-Apply'd + via `publish_intent` zurück-broadcastet. Cold-Fail (kein Worker online): Logger.warning + Flash-Error für UI / Mix.raise für CLI.

**Disaster-Recovery für Hub:** trivial. `git pull` + Secrets aus dem Vault + Re-Deploy. Keine Restore-Story, kein Backup, kein Schema.

**Disaster-Recovery für Worker:** Mnesia bleibt der kanonische Speicher pro Worker. Wenn ein Worker seine Mnesia verliert: re-pair + der Pull-Sync holt alle Events aus anderen Workern derselben Campaigns zurück. Mechanik seit #690+#693: persistente **Sync-Wasserlinie** pro Scope (`Worker.SyncWatermark` — nur Pull-Batches schieben sie vor, Live-Events nie → kein Cursor-Poisoning), Quell-Worker antwortet 1 Byte-Budget-Chunk pro Request (`pull_chunk_max_bytes`), Empfänger loopt bis leer; periodischer Sync-Tick (`sync_tick_ms`, 60 s) heilt verpasste Responses/Live-Events dauerhaft. Invariante: jeder Worker hält alle Member-Campaigns seiner User vollständig synchron, solange ein Peer online ist. Details: `docs/Backup-Recovery.md`.

## Rollen-Modell (Issue #140)

Zwei orthogonale Achsen:

**Globale Rolle** (`worker_users.role`, instance-weit):

- `:admin` — Universal-Allow. Userverwaltung, Worker-Config, sieht jede Kampagne.
- `:spielleiter` — darf eigene Kampagnen erstellen (`:create_campaign`). KEINE automatischen GM-Rechte in fremden Kampagnen.
- `:spieler` — Default. Darf einer Einladung folgen, Mikro beitreten, eigene Utterances bearbeiten.

**Per-Campaign-Rolle** (`campaign_members.role`, pro Membership):

- `:spielleiter` — GM dieser Kampagne. Ersteller wird automatisch eingetragen (`CampaignCreated` → Auto-Member). Weitere Co-SL werden vom GM via `MemberRolePromoted` befördert (Promote-Button am Member-Pill in der CampaignLive; derselbe Event-Kind dient der Rück-Demotion `:spielleiter → :spieler`). Der letzte Spielleiter einer Kampagne ist nicht demote-/removebar.
- `:spieler` — Mitspieler-Default (`InviteRedeemed` + `AdminMemberAdded` schreiben das).

GM-Rechte (`:edit_summary`, `:delete_campaign`, `:invite_to_campaign`, `:regenerate_*` etc.) hängen **ausschließlich** an der per-Campaign-`:spielleiter`-Rolle (oder globalem `:admin`). Globale `:spielleiter` ohne Membership in einer Kampagne ist dort gleichgestellt mit `:spieler`. Permission-Check ist `HubWeb.Permissions.can?/3` mit `user.campaign_role`, gesetzt aus `Worker.Repo.campaign_role/2` beim LV-Mount.

`campaign.owner_discord_id` ist seit #140 KEIN persistiertes Feld mehr — `Worker.Repo.get_campaign/1` liefert den ersten Spielleiter als abgeleiteten Wert (für Recording-Leader-Routing und Dashboard-SL-Pille). Permission-Gating geht nie über dieses Feld.

### Admin-Debug-Endpoint (Issue #144)

Wenn ein User über fehlende GM-Buttons oder seltsame Permission-Symptome klagt: Admin-only HTTP-GET dumpt für die (target_did, campaign_id)-Paarung den Worker-Snapshot + die aus `HubWeb.CampaignLive.derive_assigns/2` berechneten LV-assigns + die Permission-Matrix (`HubWeb.Permissions.can?` für alle GM- und Member-Actions) als JSON.

**URL-Schema:**

```
GET /admin/debug/campaign/<campaign_id>?target_did=<discord_id>[&include_live=1]
```

**Konkrete Beispiele:**

```bash
# Prod (gigalixir):
https://loretracker.gigalixirapp.com/admin/debug/campaign/romeo-julia-demo?target_did=615614311255244801

# Lokal (PR-Test-Hub auf 4003):
http://localhost:4003/admin/debug/campaign/romeo-julia-demo?target_did=615614311255244801

# Mit curl + Session-Cookie:
curl -b "_lore_tracker_key=<sess-cookie>" \
  "https://loretracker.gigalixirapp.com/admin/debug/campaign/<cid>?target_did=<did>"
```

Einfacher im Browser: einloggen, dann die URL direkt aufrufen — der Browser schickt das Session-Cookie automatisch mit.

**Gate**: Target-User muss vorher in `/settings → Debug-Zugriff` einen Grant (5/15/60 min) aktiviert haben (`Hub.DebugConsent.grant/2`). Ohne valid Grant → 403 mit Hint. Auto-Expire via `Process.send_after`, kein Postgres-Persist (Hub-stateless seit #164). Audit-Log via `Logger.info` mit `admin_did + target_did + campaign_id`.

**Response-Shape** (JSON):
- `snapshot` — Worker-Reader-Output (campaign + sessions + members + utterances + epos + chronik + ...)
- `derived_assigns` — `{role, campaign_role, is_member?, owner?, can_edit_meta?, can_regenerate_*, perm_user}`
- `permissions.gm_actions` — Map mit allen 12 GM-Actions (`edit_summary, delete_campaign, ...`) → `true`/`false`
- `permissions.member_actions` — `join_mic, set_own_alias` → `true`/`false`

LV-Process-Iteration (`?include_live=1`) ist v1-out-of-scope — der Endpoint returnt einen Hint-Stub. Snapshot + derived-Assigns + Permissions-Matrix reichen für die meisten Permission-Bug-Diagnosen.

## Deploy (Gigalixir + Codeberg-Woodpecker)

- CI-Config lebt seit #764 im Verzeichnis `.woodpecker/`: **`woodpecker.yml`** (compile + credo + test + dialyzer + coverage + deploy — der Dateiname hält den Required-Status-Kontext `ci/woodpecker/pr/woodpecker` stabil) + **`audit.yml`** (`deps_audit` als eigener, nicht-required Workflow — ein Runner-/Daemon-Fehler dort cancelt den Deploy nicht mehr; genau das passierte 2026-07-09 zweimal trotz `failure: ignore`). Seit Issue #31 ist die Pipeline auf den stateless-Hub angepasst: **compile** läuft `mix compile --warnings-as-errors` über das ganze Umbrella (Drift-Gate für hub + worker + shared), **test** fährt die hub- **und** die worker-Suite (`mix cmd --app hub mix test` + `mix cmd --app worker mix test` — beide gated; shared hat keinen eigenen Test-Step, weil es standalone nicht bootet [config/runtime.exs importiert Dotenvy, kein shared-Dep] → shared-Logik wird aus der hub-/worker-Suite mitgetestet, z.B. der Wire-Drift-Guard unter `apps/hub/test/wire/`), **deploy** pusht zu Gigalixir ohne `ps:migrate` (kein Schema). **Seit Issue #31 ist Woodpecker aktiv** (CI-Zugriff via `Codeberg-e.V./requests` #2016 auto-granted nach der AGPL-Relizenzierung #477; Repo in ci.codeberg.org aktiviert, Webhook gesetzt, die drei Secrets `gigalixir_email`/`gigalixir_api_key`/`gigalixir_app_name` als push-scoped Secrets hinterlegt). **Jeder master-Push deployt jetzt automatisch nach Gigalixir** — der manuelle `git push gigalixir HEAD:refs/heads/master` ist damit **überflüssig** (würde doppelt deployen). compile + test laufen zusätzlich auf jedem PR.
- `mix release.hub` (alias) builds the prod release (`lore_tracker`, hub+shared only — worker stays local-install).
- Required Codeberg secrets: `gigalixir_email`, `gigalixir_api_key`, `gigalixir_app_name`.
- Buildpack pins live in `elixir_buildpack.config` + `phoenix_static_buildpack.config`.

### Branch-Protection als Merge-Gate (Issue #485)

`master` ist **Branch-protected** mit dem Woodpecker-PR-Check als Required-Status — der Merge-Button bleibt gesperrt, solange `ci/woodpecker/pr/woodpecker` (compile + test) rot oder pending ist. Erst **CI grün + Maintainer-Merge** lässt nach master (und damit per Auto-Deploy nach Prod). Kein roter/ungetesteter Stand kommt mehr durch — genau das „CI-OK, dann mein OK"-Modell. Praktische Folge fürs Mergen: erst den CI-Status pollen (grün abwarten), dann mergen — Merge-Versuche auf rot/pending werden geblockt.

Die Settings leben in der Codeberg-Web-UI (**Repo → Settings → Branches → `master`**, Maintainer-only, nicht per API/Commit automatisierbar):

- **Push deaktivieren** — direkte Pushes auf master gesperrt, alles läuft über PRs.
- **Statuscheck-Muster** = `ci/woodpecker/pr/woodpecker` — der PR-Check muss grün sein.
- **Ungeschützte Dateimuster** = `.woodpecker.yml;.woodpecker/**` — siehe Ausnahme unten (seit #764 liegt die Config unter `.woodpecker/`; das Muster muss das Verzeichnis abdecken, sonst ist die CI-Selbstreparatur-Ausnahme wirkungslos).

**Ausnahme — CI-Config kann sich nicht selbst grün prüfen:** Woodpecker nutzt für PR-Events die CI-Config aus dem **Ziel**-Branch (master), nicht aus dem PR-Branch. Eine kaputte CI-Config reparierende Änderung kann ihren eigenen Fix daher nie per PR validieren — der Check bliebe ewig rot. Lösung: die CI-Config-Pfade (`.woodpecker/**`, historisch `.woodpecker.yml`) stehen in den **Ungeschützten Dateimustern**, d.h. PRs, die *nur* diese Dateien ändern, umgehen den Required-Status (Admin-Bypass alternativ). Bei reinen CI-Config-Fixes also bewusst trotz noch-rotem/abwesendem Check mergen.

### Free-Tier-Grenzen + Guards (Issue #876)

Prod läuft auf dem Gigalixir-**FREE**-Account: max size **0.5** (aktuell 0.4 = 400 MB RAM / ~8 % CPU-Kern), **genau 1 Replica**, kein SSH/Clustering, und **30 Tage ohne Deploy → App wird auf 0 Replicas skaliert** (Warnmail nach 23 Tagen; jeder master-Push deployt = zählt als Aktivität). Drei Guards sichern das ab:

- **`deploy_verify`-CI-Step** (`.woodpecker/woodpecker.yml`, nach `deploy`): pollt via `tools/ci/deploy_verify.py` die Gigalixir-API bis das Release mit dem CI-Commit-SHA live ist, prüft Pods Healthy + replicas 1/1 + kein `OOMKilled`-lastState + size ≤ 0.5 + HTTP 200/301/302/303 auf `/` + Grace-Recheck nach 30 s. Ein kaputtes Deploy (z.B. OOM-Crash-Loop am 400-MB-Limit) rotet die Pipeline statt still tot zu sein.
- **`freetier`-Cron-Workflow** (`.woodpecker/freetier.yml` + `tools/ci/freetier_check.sh`, braucht KEINE Secrets — die gigalixir_*-Secrets sind push-scoped): HTTP-Check auf Prod + rot ab 21 Tagen ohne master-Commit (Frühwarnung vor dem 30-Tage-Downscale). Einmaliges Maintainer-Setup: Cron-Eintrag in der Woodpecker-UI (ci.codeberg.org → Repo → Settings → Cron, Branch master, wöchentlich).
- **pending-Map-Regressionstests** (`reader_pending_test.exs`, `prompt_preview_pending_test.exs`): nageln die Aufräum-Pfade der einzigen praktisch unbounded-fähigen Hub-RAM-States fest (Cache-Inventar 2026-07-17; RateLimit-Sweep + DebugConsent-Expire waren schon getestet).

### Deploy-Gate: aktive Aufnahme erkennen (Issue #703)

Ein Auto-Deploy restartet den Prod-Hub mitten in einer laufenden Session-
Aufnahme (Browser-Mikro → Hub → Worker). Der Restart wird technisch überlebt
(Browser reconnectet, Worker-First-Apply, Hub ist stateless), aber der
Audio-Pfad ist für die Restart-Dauer unterbrochen — bei schlechtem Timing
entstehen unbemerkte Transkript-Lücken. **Bewusst warn-only, kein Blocking-
Gate**: Sessions laufen stundenlang, ein hartes Warten/Retry auf dem
Free-Tier-Single-Replica-Setup wäre ein Verfügbarkeits-Risiko und würde
Merges am Spielabend faktisch verhindern.

- `GET /health/recording` — unauthentifizierter, prod-live Endpoint
  (`HubWeb.HealthController`, eigene `:public_api`-Router-Pipeline, da CI
  sich nicht als Hub-User einloggen kann). Liefert nur
  `{"active_recording": true|false}` — bewusst kein Session-/Campaign-Detail
  an einem öffentlich erreichbaren Endpoint. Backing-Signal:
  `Hub.WorkerRegistry.any_active_recording?/0`, nutzt das bestehende
  `held_sessions`-Tracking (Issue #468) — keine neue State-Quelle.
- **`tools/ci/deploy_gate_check.py`**, als erste Commands im bestehenden
  `deploy`-Step (`.woodpecker/woodpecker.yml`, vor dem `git push --force
  gigalixir`) — immer `exit 0`, gibt bei aktiver Aufnahme nur eine laute
  Log-Zeile aus, deployt aber sofort weiter. Netzwerk-/HTTP-Fehler sind
  fail-open (u.a. der erwartete Fall beim allerersten Deploy nach diesem
  Feature-Merge, wo die noch laufende alte Prod-Version den Endpoint noch
  nicht kennt).
- **Ehrliche Grenze**: kein echtes Blocking-Gate, kein Graceful-Shutdown —
  ein Merge während einer Session restartet den Hub weiterhin, nur jetzt
  sichtbar im CI-Log statt lautlos. Flankierend bleibt Merge-Disziplin am
  Spielabend (vor Merges `curl https://loretracker.gigalixirapp.com/health/recording`
  prüfen).

### Rollback + Live-Logs (Gigalixir)

Wenn ein Deploy kaputt geht — Live-Logs anschauen, Release zurückrollen:

```bash
gigalixir logs -a loretracker -f                # tail -f auf die prod-Logs
gigalixir releases -a loretracker               # alle Releases mit Versionsnummer + Commit
gigalixir releases:rollback -a loretracker      # auf den vorherigen Release zurück (oder: --version <N>)
gigalixir ps -a loretracker                     # wie viele Replicas, Status, Replica-Health
gigalixir ps:restart -a loretracker             # soft-restart aller Replicas (selber Code)
```

Voraussetzung: `pip install gigalixir` + `gigalixir login -e $EMAIL -k $API_KEY` einmalig. Die Creds liegen in den Codeberg-CI-Secrets, müssen für CLI-Nutzung separat im Shell-User gesetzt werden.

## Issue tracker + URLs

- Issues live on Codeberg at https://codeberg.org/tomloresys/lore-tracker — use `tea issues …`. Dein Codeberg-Login + Token-Setup gehört nach `CLAUDE.local.md` (siehe „Tea CLI" Abschnitt).
- Prod hub: https://loretracker.gigalixirapp.com (Auto-Deploy via Codeberg-Woodpecker bei jedem master-Push, seit Issue #31).
- Local dev hub: http://localhost:4000 (`cd apps/hub && mix phx.server`).
- **Issue-Audit-Snapshot**: `docs/issue-audit-2026-07-22.md` — letzter Relevanz-Snapshot (Milestone-Fit / Gültigkeit / Reihenfolge über alle offenen Issues, Stichtag: nach Abschluss der Epics #829 + #861 und dem Wahrheitsschicht-E2E auf Prod; löst `docs/issue-audit-2026-07-09.md` ab). Bei der nächsten Refinement-Runde aktualisieren oder durch ein neueres Stichtag-Doc ersetzen, damit die Liste nicht stale wird.

## Development workflow

**Goldene Regel: jede Zeile Sourcecode hängt an einem Issue. Jedes Issue bekommt genau einen Branch. Bevor der Branch geöffnet wird, holt man sich das Ticket (`tea issues edit -a <dein-codeberg-login> <N>` — Assignee setzen).**

**Session-Start: einmal `git fetch origin master` (via HTTPS-Token wenn SSH-Agent nicht greifbar — siehe `CLAUDE.local.md` für den Token-Trick).** Sonst arbeitet man gegen einen stale `refs/remotes/origin/master`-Ref, `git status` lügt über „N Commits vor origin", und man baut Branches auf einem master der eigentlich schon längst weiterbewegt wurde. Konfliktreiche PRs + redundante Bug-Fixes sind die Folge.

**Coordination-Scan vor Issue-Pick / bei Multi-Session-Fragen** (Issue #330): wenn du ein Issue anpacken willst, oder der User fragt was lokal/woanders läuft → **erst** `ls ~/Projekte/.claude-issue-locks/` + `epmd -names`. **Nicht** den Codeberg-Tracker, **nicht** die per-Worktree `CLAUDE.local.md` (die ist strukturell blind für andere Worktrees). Dateinamen-Konventionen im Lock-Verzeichnis:

| Datei | Bedeutung |
|---|---|
| `<N>.lock` | Issue N wird in einem Worktree bearbeitet (Inhalt: worktree\|pid\|ts\|branch) |
| `pr-test-<PORT>.lock` | PR-Test-Stack auf Port PORT läuft (Inhalt: worktree\|hub_pid\|worker_pids\|branch\|ts) |

Beide werden von den Workflow-Schritten/Mix-Tasks automatisch geschrieben/entfernt. Wenn `epmd -names` mehr Nodes zeigt als das Lock-Verzeichnis listet → andere Session(en) sind crash-gestorben oder eine Mix-Task hat Lücken, nachpflegen.

For every development task the user assigns, follow this loop:

1. **Find a matching issue.** Run `tea issues list -r tomloresys/lore-tracker --state open` and pick the one that fits. If none fits, ask the user whether to file a new one (Default: ja, anlegen via `tea issues create -t … -d … -L <label-csv> -m "<milestone>"`). Ohne Issue keine Codezeile — Ausnahme nur für die unten gelisteten Doc-/Typo-/Hotfix-Sonderfälle.
   - **Neue Issues bekommen immer mindestens einen Label** aus der bestehenden Liste (`tea labels list -r tomloresys/lore-tracker`): primär `feature` oder `bug`; zusätzlich Domain (`llm` / `ui` / `audio` / `infra` / `docs` / `permission` / `mobile` / `i18n` / `architecture` / `live-transcription`); `blocked` falls auf ein anderes Issue wartend. Ungelabelte Issues fallen aus der Filterbarkeit raus und werden vergessen — Labels sind nicht optional.
2. **Take the ticket.** Vor dem Branch das Issue dem aktiven Bearbeiter zuweisen: `tea issues edit -a <dein-codeberg-login> <N>`. So sieht jeder im Tracker wer woran arbeitet, kein doppeltes Anpacken.
3. **Branch-Check + Lock vor Branch-Anlage.** Prüfen ob das Issue schon einen Branch hat — sonst entstehen zwei parallele Branches auf demselben Ticket (z.B. wenn eine andere Claude-Session schon dran ist oder eine alte Session unterbrochen war). Zusätzlich Filesystem-Lock setzen, weil der Codeberg-Comment-Marker einen Race-Window hat (zwei Sessions können gleichzeitig anfangen, bevor eine den Comment postet):
   ```bash
   git fetch origin "refs/heads/issue-<N>-*:refs/remotes/origin/issue-<N>-*" 2>/dev/null
   git branch -a | grep -E "(^|/)issue-<N>-"   # lokal + remote
   tea issues <N> | grep -iE "^[[:space:]]*Branch:"   # Comment-Marker

   # Issue-Lock-Check (Multi-Clone-Schutz):
   LOCKDIR=~/Projekte/.claude-issue-locks
   mkdir -p $LOCKDIR
   LOCK=$LOCKDIR/<N>.lock
   [ -f $LOCK ] && { echo "Issue <N> locked by:"; cat $LOCK; exit 1; }
   ```
   - **Existiert ein Branch ODER ein Lock** → STOP. Bei Branch: an dem bestehenden weiterarbeiten (`git checkout` + `git pull`/`git rebase master`). Bei Lock: andere Session hängt schon dran — anderes Issue picken. Bei stale Lock (PID nicht mehr existent + Timestamp > 6h alt): manuell prüfen, ggf. löschen.
   - **Kein Branch + kein Lock da** → Lock setzen + neuen Branch `issue-<N>-short-slug` anlegen (e.g., `issue-11-self-critic`) **und sofort als Issue-Comment hinterlegen** damit's beim nächsten Check auffindbar ist:
     ```bash
     echo "$(pwd)|$$|$(date -Iseconds)|issue-<N>-short-slug" > $LOCK
     tea comment <N> "Branch: \`issue-<N>-short-slug\`"
     ```
   Genau ein Branch pro Issue — wenn der Scope sich auf etwas anderes ausweitet, neues Issue + neuer Branch. Never work directly on `master`.
4. **Build the change.** Commit each time the code compiles cleanly (`mix compile` passes — tests staying green is preferred but not required for intermediate commits). Small focused commits beat one big WIP commit. Don't push during this phase.
   - **Version bumpen** in `apps/<app>/mix.exs` wenn die Änderung App-Verhalten / Wire-Protocol / Schema berührt. Pre-1.0: Minor (`0.3.0`) bei Feature / rückwärtskompat. Wire-Erweiterung, Patch (`0.2.1`) bei Bugfix / Polish ohne Verhaltens-Änderung. **`shared`-Bump erzwingt `hub` + `worker` mit-bumpen** (Wire/Schema-Sync). Reine Doc-/Doku-/Tooling-PRs brauchen keinen Bump — **ebenso reine Dependency-/Security-Bumps ohne Verhaltensänderung** (z.B. ein CVE-Patch-Update wie #952, der keine Call-Site-Semantik ändert): die Versionszeile in `mix.exs` bleibt unangetastet. Grund: bei parallelen Branches/Worktrees kollidiert sonst dieselbe Zeile unnötig oft beim Merge (jede Berührung ist potenzielle Konfliktfläche); das Signal "diese Version enthält den Fix" steht ohnehin im Commit/PR. Wo doch gebumpt wird: möglichst spät machen (kurz vor dem Merge, nach dem letzten Rebase gegen `master`), nicht schon beim ersten Commit — sonst bumpt man von einem beim Merge längst überholten Stand. Nach Merge auf master: Tags `hub-v<N>` / `worker-v<N>` / `shared-v<N>` lokal setzen + pushen (`git tag … && git push origin --tags` — Token-Trick siehe `CLAUDE.local.md`).
5. **Doku mit-pflegen.** Wenn die Änderung etwas berührt, das in `CLAUDE.md`, `README.md`, `apps/hub/README.md`, `apps/worker/README.md`, `apps/shared/README.md`, `docs/Worker-Setup.md`, `docs/Spieler-Anleitung.md`, `docs/Backup-Recovery.md`, `CONTRIBUTING.md` oder einem Modul-`@moduledoc` beschrieben ist, **im selben PR** die Doku nachziehen — nicht in einem Folge-PR. Doku-Drift sammelt sich sonst unsichtbar an, und die nächste Session arbeitet auf falschen Annahmen. Faustregel: wenn ein bestehender Doku-Satz nach deinem PR nicht mehr stimmt, ist es Teil deines PRs ihn zu fixen. Gilt auch für gelistete Befehle, Pfade, Env-Vars, Architektur-Skizzen und Workflow-Schritte.
6. **Test-Instanz hochfahren** mit `mix lore.pr_test.spawn` (Issues #186 + #190, ab Issue #167). Detect current branch via `git rev-parse`, räumt stale Stacks auf den eigenen Slot-Ports ab, wählt freien Port aus dem cwd-Slot in `CLAUDE.local.md` (siehe Local-Setup-Skelett unten), spawnt Hub + pre-gepairten Worker als detached BEAMs, seedet die Romeo-Schlegel-Demo (Owner = Caller), öffnet den Browser. **Volle Stack-Anatomie + Spawn-Flow + Tear-Down: `docs/PR-Test-Setup.md`.** **Pflicht** bevor die Review-Frage gestellt wird — User muss den Branch klickbar im Browser haben können. Reine Doc-/Typo-/Config-PRs ohne UI-Wirkung dürfen das überspringen; im Zweifel hochfahren. Manuelle Variante mit anderen Flags (`--admins`, kein Seed, expliziter Branch): `mix lore.pr_test <branch> [--seed] [--admins id1,id2]` — siehe `mix help lore.pr_test`.
7. **Ask for review.** Tell the user what was built und **benenne die laufende Test-Instanz konkret** — immer in der Form „**Teststage auf Port `<PORT>` bereit unter http://localhost:`<PORT>`**" (mit der echten Port-Nummer aus Schritt 6). Nie vage „ich teste auf PR-Test" / „getestet auf PR-Test" — der User muss den klickbaren Port direkt vor sich haben, ohne nachfragen zu müssen. Danach frag explizit ob's gut ist („ist das so gut?"). Wait for confirmation.
   - **If yes** → open a pull request to `master` via `tea pulls create`, merge it (`tea pulls merge`). **Der Gigalixir-Deploy passiert ab Issue #31 automatisch** über Codeberg-Woodpecker beim master-Push — **kein manueller `git push gigalixir` mehr** (sonst Doppel-Deploy). Danach Test-Instanz runterfahren + Worktree/Mnesia-Dirs aufräumen + **Issue-Lock entfernen** (`rm -f ~/Projekte/.claude-issue-locks/<N>.lock`). **Den gemergten Branch lokal + remote löschen** — Codeberg behält sonst Branch-Leichen (typischer Backlog wenn niemand putzt):

     ```bash
     git checkout master                       # auf master wechseln (sonst greift -d nicht)
     git branch -d <branch>                    # lokal
     git push origin --delete <branch>         # remote (HTTPS-Token-Trick wenn SSH-agent nicht greifbar — siehe CLAUDE.local.md)
     ```

     Codeberg-Woodpecker deployt seit Issue #31 automatisch beim master-Push (siehe „Deploy"-Sektion) — der frühere manuelle Gigalixir-Push entfällt. **Falls der PR Worker-Code verändert hat** (`apps/worker/` oder `apps/shared/`): den User darauf hinweisen, dass der lokale `worker_prod`-Daemon neu gestartet werden muss (`cd apps/worker && LORE_MNESIA_DIR=… HUB_BASE_URL=https://loretracker.gigalixirapp.com elixir --sname worker_prod --no-halt -S mix run`), damit er den neuen Code gegen den frisch deployten Hub läuft. **Ausnahme**: läuft `worker_prod` als self-updating systemd-Daemon (#492, `LORE_WORKER_AUTOUPDATE=1`), zieht er sich nach dem Hub-Deploy automatisch nach — dann entfällt der manuelle Restart-Hinweis.
   - **If no** → the user will say what to change. Iterate from step 4 (Code + Doku); Test-Instanz weiterlaufen lassen.

Exceptions (don't enforce the branch+PR-loop, kein Issue nötig): pure docs-only tweaks (CLAUDE.md, README, docs/*), trivial typo fixes, or explicitly user-driven hot-fixes can go straight on `master`. When in doubt, branch.


```bash
mix lore.pr_test.spawn                          # Default: current branch, Hub + 1 Worker + Romeo-Schlegel, cwd-Slot-Port
mix lore.pr_test <branch> --seed                # explizite Variante (Branch + Flags)
mix lore.pr_test <branch>                       # leere Mnesia — nur für Onboarding-Flow-Tests
mix lore.pr_test <branch> --seed --admins id1,id2   # Multi-Worker (z.B. pull_since-Tests)
```

**`mix lore.pr_test.spawn`** (Issue #186) ist der Default-Befehl in Schritt 6 — er automatisiert Branch-Detect + Port-Slot-Lookup + Romeo-Seed + Browser-Open. Refuse auf `master` (Sicherheits-Gate gegen Versehen). Port kommt aus dem **cwd-spezifischen Slot** in `CLAUDE.local.md` (siehe Local-Setup-Skelett) — jeder Worktree hat zwei reservierte Ports.

**`--seed` ist Default**: ohne Daten zeigt die UI praktisch nichts (leeres Dashboard, kein Klick auf REC / Edit / Promote / Regenerate möglich). Romeo-Schlegel hat 5 Sessions à mehrere Utterances, pre-generated Resümees / Epos / Chronik — voll-bestückt für jeden Spalten- und Button-Test.

Default-Admin-Discord-ID kommt aus `LORE_LOCAL_ADMIN_DISCORD_ID` (.env). Der Task:

- Wählt freien Port aus dem cwd-Slot in `CLAUDE.local.md` (Discord-OAuth-Redirect-URIs sind für 4000-4007 eingetragen, davon 4001-4006 in 3 Slot-Paare aufgeteilt + 4007 als Reserve)
- Legt Worktree `../lore-pr-$PORT` an
- Mintet JWT direkt aus dem lokalen Hub-Secret (kein Discord-Pair-Klick), pre-seedet das Worker-Mnesia
- Startet Hub + Worker als detached BEAMs (PIDs in `/tmp/pr-$PORT/{hub,worker-0}.pid`, Logs daneben)
- Öffnet Browser auf `http://localhost:$PORT/`
- Trägt den Stack ein in `~/Projekte/.claude-issue-locks/pr-test-<PORT>.lock` (Issue #330, cross-worktree sichtbar)

**PR-Test-Worktrees haben detached HEAD** (Issue #190) — sie zeigen auf den Feature-Branch-Commit, aber ohne Branch-Ownership. Damit kann derselbe Branch auch im aktuellen Worktree ausgecheckt sein (typisch wenn `mix lore.pr_test.spawn` aus dem Arbeits-Worktree heraus läuft). Konsequenz: im PR-Test-Worktree commiten ist nicht gedacht — Änderungen passieren im Arbeits-Worktree, dann normaler `git push` + Hub im PR-Test-Worktree reload.

**Tear-down nach PR-Approval:**

```bash
mix lore.pr_test_down 4001
```

Killt BEAMs via PID-Files, entfernt Worktree, löscht `/tmp/pr-$PORT`, räumt CLAUDE.local.md auf.

**Logs anschauen wenn was schiefläuft:** `tail -f /tmp/pr-$PORT/hub.log /tmp/pr-$PORT/worker-0.log`.

## Local setup recommendation (`CLAUDE.local.md`)

Neue Claude-Code-Sessions auf einer neuen Maschine sollten als ersten Schritt eine eigene **`CLAUDE.local.md`** im Repo-Root anlegen. Die Datei ist in `.gitignore` und gehört dem jeweiligen Entwickler — sie hält maschinen-spezifische Pfade, Ports, Workarounds und Operational-Do-Nots fest, die nirgendwo sonst hingehören (CLAUDE.md = Repo-weit, `docs/Worker-Setup.md` = User-Onboarding, `CONTRIBUTING.md` = Code-Contributor-Onboarding).

Empfohlenes Sektions-Skelett:

```markdown
# CLAUDE.local.md — <name> @ <hostname>

Gitignored. Machine-local context für Claude Code.

## PR-Test-Port-Slots pro Worktree

Jeder Claude-Code-Worktree bekommt einen festen 2-Port-Slot reserviert. `mix lore.pr_test.spawn` matched den aktuellen `git rev-parse --show-toplevel` gegen diese Tabelle und allokiert daraus den ersten freien Port. Format pro Zeile: `- <abs-pfad> → <port1>, <port2>`.

- /home/<user>/Projekte/lore_tracker → 4001, 4002
- /home/<user>/Projekte/lore_tracker2 → 4003, 4004
- /home/<user>/Projekte/lore_tracker_issues → 4005, 4006

Reserve / ad-hoc: 4007. Discord-OAuth-Redirect-URIs müssen für **alle** verwendeten Ports einmalig in der Discord-Developer-Console eingetragen sein.

## This machine
- **OS**: <distro/version>
- **Hostname**: <hostname>
- **Repo cwd**: <abs path>
- **Erlang-Note**: <distro-spezifische Stolpersteine, z.B. `erlang-headless` statt `erlang-core` auf Arch>

## Local services + paths
- **Ollama**: default endpoint + gepullte Modelle
- **Whisper**: `whisper-cli` im PATH? Modell-Pfad?
- **Hub local dev**: http://localhost:4000
- **Discord guild ID** für Test-Server: <id>
- Andere lokale Apps/Ports die mit Lore-Tracker-Ports kollidieren könnten

## Mnesia dirs (eine pro BEAM)
| BEAM | sname | data dir | hub it talks to |
|---|---|---|---|
| Hub local dev | `nonode@nohost` | `priv/mnesia/dev` | _(self)_ |
| Worker against local hub | `worker` | `priv/mnesia/dev-worker` | http://localhost:<ports> |
| Worker against gigalixir prod | `worker_prod` | `priv/mnesia/prod-worker` | https://loretracker.gigalixirapp.com |

## Git push to Codeberg
SSH-Agent oft nicht reachable in non-interactive Shell. HTTPS-Token-Push-Snippet:

\`\`\`bash
TOKEN=$(awk '/- name: codeberg/{flag=1} flag && /token:/{print $2; exit}' ~/.config/tea/config.yml)
git -c credential.helper='!f() { echo "username=<user>"; echo "password='"$TOKEN"'"; }; f' \
  push https://codeberg.org/<user>/lore-tracker.git <branch>
\`\`\`

## Operational do-not's (user-specific)
- **Don't read `~/.env`** (oder andere sensitive Pfade)
- **Don't `rm -rf` Mnesia data dirs** ohne explizite Erlaubnis
- **Don't push to gigalixir unprompted**
- **Don't start Docker containers without explicit auth**
- (weitere user-spezifische Verbote)

## Test seeding scripts / ad-hoc artifacts
- Kurz-Notizen über `/tmp/`-Skripte die noch nützlich sind und welche bereits durch committed Mix-Tasks ersetzt wurden.
```

Wichtig: **CLAUDE.local.md anlegen ist explizit `.gitignored`** — niemals committen, auch nicht den Beispiel-Inhalt aus diesem Block 1:1 als File einchecken. Sensible Tokens, Discord-IDs, Mnesia-Pfade gehören in keinen Git-History.

## Local multi-BEAM setup

Hub + worker run in **separate** BEAMs locally because each owns its own Mnesia schema. Schemas are node-name-bound — start each BEAM with the sname matching the schema in its data directory.

- **Hub** (no sname → `nonode@nohost`): `cd apps/hub && mix phx.server` — uses `priv/mnesia/dev/`.
- **Worker against local hub** (sname `worker`): `cd apps/worker && LORE_MNESIA_DIR=$(pwd)/../../priv/mnesia/dev-worker elixir --sname worker --no-halt -S mix run`.
- **Worker against gigalixir prod hub** (sname `worker_prod`): same but with `LORE_MNESIA_DIR=…/prod-worker` and `HUB_BASE_URL=https://loretracker.gigalixirapp.com`. **Seit #492** kann `worker_prod` stattdessen als **self-updating systemd --user Daemon** laufen (`LORE_WORKER_AUTOUPDATE=1` + `LORE_WORKER_DEPLOY_REPO=…`) — er zieht sich nach jedem Hub-Deploy automatisch nach (git→`compile --force`→`hard_halt` = `:erlang.halt(0, flush: false)` (#776), nur wenn idle; `--force` seit #516, damit die SHA auch ohne Worker-Versions-Bump neu gebacken wird → kein Drift-Loop). Drei Robustheits-Säulen: **#512** systemd-Watchdog (`WatchdogSec=`+`NotifyAccess=main`, `Worker.SystemdWatchdog`) killt Zombie-BEAMs, wenn der Halt nicht durchkommt (seit **#776** hält der Node flush-frei → sauberer `exit 0` statt SIGABRT-Core-Dump: der Default-flushende `System.halt/1` deadlockte am pending IO, der 60s-Watchdog war de facto zum Update-Vollstrecker geworden; jetzt wieder echter Backstop); **#516** `compile --force` garantiert SHA-Konvergenz; **#500** Boot-Crash-Rollback (`Worker.Updater.boot_guard/1` beim Start) — bootet eine frisch self-updatete SHA wiederholt nicht durch (>2 Versuche, nie via Hub-Join als „good" markiert), rollt der Worker selbst auf die letzte gute SHA (`:last_good_sha`) zurück. Setup: `apps/worker/priv/systemd/worker_prod.service` + `docs/Worker-Setup.md`.

Dev-only HTTP endpoint `POST /dev/event` (mounted only in `:dev`/`:test`) accepts `%{"payload" => map}` and appends the payload raw to the event log — used by `mix lore.fake_session` and ad-hoc seeding scripts.

## Seeding events into prod

Prod has **no `/dev/event` endpoint** (route is dev-only, 404 on gigalixir). Two paths exist for getting events into the prod EventLog:

1. **Worker-RPC bridge** — drive the local `worker_prod` BEAM, which is already paired+joined to gigalixir, and call `Worker.Intents.publish/1` via Erlang distribution. Each call returns `{:ok, seq}` after the prod hub has assigned a seq.

   ```bash
   # Node name = worker_prod@<short-hostname>
   elixir --sname seeder --cookie "$(cat ~/.erlang.cookie)" --hidden \
     -e ":rpc.call(:\"worker_prod@$(hostname -s)\", Worker.Intents, :publish, [PAYLOAD])"
   ```

   Use this for anything programmatic (bulk imports, replays, fixtures). The Folger English Romeo & Juliet import (1157 events, 1060 utterances, 26 sessions, 35 character-members) ran this way — see issue #58 comment for the PDF-parser + push scripts. Resulting prod campaign: `706d3352-9d68-4417-87df-cb2d5022a0b4`.

2. **`mix lore.seed.romeo`** (issue #58, dev-only) — the local-hub canonical path: JSONL files committed under `apps/hub/priv/seeds/romeo/`, mix-task applies them via the dev `/dev/event` endpoint. **Guarded against `Mix.env() == :prod`** so it can't accidentally seed against prod. For prod, the RPC-bridge above remains the only path.

### Die Pipeline: Wahrheitsbild (Issue #651; seit #786 der einzige Pfad)

> **Visueller Flow-Überblick** (Audio → Whisper → Wahrheitsbild → Chronik/Epos/Resümee, mit Datei:Zeile + Events + Settings): `docs/Pipeline-Flow.md` (Mermaid-Diagramm + Schritt-Tabelle; interaktive HTML-Fassung `docs/pipeline-flow.html`). Der folgende Absatz ist die dichte Referenz dazu.

`Worker.Recording.Pipeline.run_for_session/1` (bzw. der `UtterancesTranscribed`-Trigger) fährt pro Session den Wahrheitsbild-Pfad — die frühere Chain (Stage 2→3→4 Prosa-Kette) und das `pipeline_mode`-Setting sind mit #786 **komplett entfernt** (kein Fallback; die Chain fabrizierte auf echtem Tisch-Deutsch nahezu vollständig):

- **Glättung (Stage 1.1)** (`smooth_transcript`, Status `"smooth"`, Epic #861: #862+#863+#864) — **deterministische** Transkript-Glättung VOR allem anderen (kein LLM): Sprecher-Merge (Adjazenz + `merge_gap_seconds`, Default 8 s), Stotter-Dedup, Füllwort-Strip, ⚠-Propagation; **OOC bricht den Merge-Run** (Verworfenes auditierbar in `ooc_verworfen`). Output = **Blöcke** mit **content-adressierten IDs** (`b_<hash(sorted quell_utterance_ids + rules_version)>`; die `rules_version` ist compile-zeit-**abgeleitet** aus den Regeldaten). Persistiert als `TranscriptSmoothed`-Whole-Snapshot (`worker_smoothed_blocks`, 1 Row/Session, LWW). **FAIL-LOUD**: scheitert die Glättung, stoppt die Pipeline (kein degradierter Pfad). **Die ganze Pipeline rechnet ab hier auf Blöcken** — `source_refs` der Fakten zitieren Block-IDs; `restrict_to_refs` restringiert auf Block-Texte; `Smoothing.to_context/3` ist der Adapter (Block → utterance-förmige Map mit `effective_text`, EINMAL pro Lauf aufgelöst). **Fakt-IDs sind ebenfalls content-adressiert** (`f_<hash(⋃ Roh-Utterance-Mengen der Refs + normalize(claim))>`, `Parsing.fact_content_id/2`) — transform-**entkoppelt** (Adress-Invariante: keine versionsbehaftete Adresse als Input einer anderen); der frühere `extraction_event_id`-Generation-Pin der Fakt-Overrides ist damit **entfallen** (Override matcht gdw. der Fakt inhaltlich derselbe ist). `SessionFactsExtracted` trägt zusätzlich `extraction_saw` (`%{block_id => text_hash}`, eigene Spalte) — die **Zeit-Adresse**, gegen die die künftige Dirty-Weiche (#866) Text-Identität prüft; **JEDER** `SessionFactsExtracted`-Republish schleppt sie feldkonservativ mit (`verify_session`, Entity-Registry-Re-Key seit #879 — der ließ sie weg und clobberte die Adresse per LWW 4 s nach jeder Extraktion → Erst-Kuration routete immer in die Voll-Adoption; Publisher-Tripwire-Test pinnt das). Re-Smoothing von Bestandssessions passiert **on-demand über den Regenerate-Button** (kein Deploy-Trigger; versionsgemischter Korpus ist akzeptiert + im Snapshot auditierbar).

- **Gap-Fill + Kuration (Stage 1.1, Fortsetzung — #865, Epic #861 D+E)** — Blöcke mit erkannter ASR-Lücke (`hat_luecke`, deterministische Signale aus #862; Satzzeichen am Ende schließt den Satz — kein Funktionswort-Fehlalarm) bekommen **asynchron** (GpuQueue, hinter dem Lauf) einen **Verflüssigungs-Vorschlag** (flüssige, inhaltstreue Neuformulierung des ganzen Blocks; `original` = ganzer Block-Text, Wort-Ebene-Skip gegen kosmetische Edits, Längen-Deckel gegen Fabulieren) von einem **lokalen** Modell (`Worker.Recording.Pipeline.GapFill`; Setting `gapfill_model`, leer = Feature aus, LOCAL-only by design). Vorschlag = separates :generiert-Artefakt (`LueckenVorschlagGeneriert` → `worker_luecken_vorschlaege`, Key = Block-Content-ID, LWW; nur für Blöcke OHNE existierenden Vorschlag/Override). **Explizite Nicht-Kante: das Eintreffen eines Vorschlags triggert NIE eine Re-Extraktion.** Fehler → eigene `/admin/errors`-Klasse `gapfill` (best-effort pro Block). **~~ANY-Klemme (E3)~~ — mit #917 (Cut 3) ENTFERNT (vertrauen-aber-markieren):** die frühere Klemme (`Verify.apply_gap_clamp/2` + `Smoothing.clamp_block_ids/2`) hielt jeden Fakt zurück, dessen `source_refs` einen uncurierten Lücken-Block berührten — auf frischen Sessions die Masse. Der #911-Flip nimmt bei uncurierter Lücke den Vorschlag (sonst Original), klemmt NICHTS; `verified?` = nur noch `grounded? AND attributed?` (Verify-Gate). Reader-sichtbare Mitigation: der 🕳-**Gap-Trust-Marker** auf den Ableitungen (Chronik/Resümee/Epos, `HubWeb.CampaignLive.GapMarker` — Join `entry.source_refs ∩ {hat_luecke ∧ uncuriert}`) + die #915-⚠-Falsifikation. Ehrliche Grenze: eine echt verstümmelte ASR-Lücke kann einen falschen Fakt erzeugen, der als wahr zählt bis jemand ihn flaggt — Mitigation, keine Garantie; betrifft NUR die Gap-Schicht, nicht Grounding/Attribution. **Kuration (Zwei-Klassen-Welt, :kuratiert):** ALLE Member dürfen (`:curate_luecken`, E4) — INLINE in der „Geglättet"-Spalte (#871; Snapshot-Key `smoothed`, schmaler Reload-Scope `campaign_luecken`; seit #883 liefert der Reader ALLE Blöcke und die Spalte fenstert render-seitig wie das Protokoll — gleitendes #709-Fenster über die gefilterte Ansicht-Liste, Scroll-Sentinels „ältere/neuere anzeigen", Ansicht-Wechsel resettet aufs Tail); Status-Enum `bestaetigt | manuell_korrigiert | original_bestaetigt` (kuratiert) `| unbrauchbar` (der EINZIGE subtraktive Akt seit #917 — Block fällt aus der Extraktions-Oberfläche, `to_context` filtert ihn, F5; Badge bleibt). Event `LueckenKurationSet` → `worker_luecken_overrides` (LWW, NIE delete, `quell_utterance_ids` sortiert-kanonisch gesnapshottet, `set_by` sichtbar). **Re-Attach ist reine Read-Zeit-Berechnung** (`Worker.Repo.Luecken.luecken_overrides_effective/2`): nach einem Rules-Bump paart der Override über die identische Utterance-Menge auf die neue Block-ID (`original_bestaetigt` nur bei exaktem Text-Match); nicht-paarende Overrides landen als `verwaist` in der Review-Anzeige, nie still weg; Mehrfach-Paarung → LWW-by-event_id. `/settings` hat dafür ein Stage-1.1-Panel (`merge_gap_seconds` mit Warnung „berührt N Kurationen (Review nötig)" bei bestehenden Kurationen + `gapfill_model`).

- **Dirty-Mechanismus (Stage 1.1, Abschluss — #866, Epic #861 Slice F)** — Kuration triggert die Neuableitung automatisch: `Worker.Recording.Pipeline.Dirty` (eigener GenServer, gleiche `:applied`-PubSub-Quelle wie die Pipeline, `elected?`-gegated) hält die EINE Kanten-Tabelle `@dependency_graph`: `LueckenKurationSet` → **Text-Identitäts-Weiche** (debounced, `dirty_debounce_ms` Default 15 s — Kuration ist ein Batch-Vorgang), `SessionFactDateSet` → deterministischer Timeline-Republish (aus der Pipeline hierher gezogen). Die Weiche keyt auf TEXT-Identität, nie aufs Status-Label: `hash(effective_text) == extraction_saw[block_id]` → **Re-Verify** = deterministische Klemm-Neuberechnung aus den persistierten `grounded?`/`attributed?`-Verdikten (KEIN LLM; Fakt-IDs stabil, Fakt-Overrides überleben); sonst — oder bei fehlendem `extraction_saw`-Eintrag (fail-closed, benannte Regel) — **Re-Extract mit Carry-over** (session-scoped LLM-Lauf; nur Fakten text-geänderter Blöcke adopted + einzeln nachverifiziert, unveränderte verbatim samt Verdikten, `unbrauchbar` zählt als ENTFERNT). NICHT-Kanten (Negativtests): `LueckenVorschlagGeneriert`, `TranscriptSmoothed`, `SessionFactsExtracted` triggern nie. Ehrliche Grenze v1: Prosa-Renders (Resümee/Epos) ziehen erst beim nächsten Regenerate nach — Fakten + Timeline sofort.

- **Extraktion** (`extract_facts`, Status `"extract"`) — Original-Utterances → strukturierte Fakten; Map-Reduce für lange Sessions (#683) + Halbierungs-Retry degenerierter Chunks (#763). Der EINE Generativschritt. **Seit #831 (Epic #829 Slice B)** trägt jeder Fakt zwei Handlungsbogen-Felder: `fact_type` (Enum `ereignis|zustandsänderung|beziehung|absicht|enthüllung|auflösung`, Default `ereignis`) + **seit #953 `threads` (LISTE von Kurzlabels, `[]` = keiner — vorher Skalar `thread`; N:M: ein Fakt kann mehreren Erzählsträngen gehören)**. Beide `required` im GBNF-Schema (#676-Lektion), rekonstruiert in `normalize_fact/4` (die EINE Stelle mit fixer Feldliste — die Republish-Pfade sind feldkonservativ). Migration feldkonservativ: `Parsing.fact_threads/1` (die EINE Leser-Quelle) liest `threads` und den Alt-Skalar `thread` als 1-Element-Liste — kein Regenerate-Zwang für Bestandsfakten. Laufzeit-**ungegated** (das Verify-Gate prüft `claim`/Attribution, nicht Labels), offline eval-gegated via `mix lore.eval.threads`. **Seit #976 (Epic #911 Slice 3)** gibt es zusätzlich `cast_match`: ein required Enum-Feld (GBNF-erzwungen) gegen den bekannten Kampagnen-Cast (`Worker.Repo.character_roster_for/1` — PCs aus `character_names_for/1`, NPCs aus einer Häufigkeits-Ernte über verifizierte Fakten früherer Sessions, Schwelle ≥2 verschiedene Sessions, Startwert ohne echte Kalibrierung) + einem festen Escape-Sentinel `"(kein Cast-Treffer)"` (`Parsing.no_cast_match_sentinel/0`) für Figuren außerhalb des Rosters — Enum ist dadurch nie leer. Löst das "Alias-Chaos" (Discord-Handle statt Figurenname in `character_alias`): das bestehende Freitext-Feld `character` bleibt unverändert (Ist-Zustand als Fallback), `cast_match` gewinnt in `normalize_fact/4` nur bei einem echten Treffer (nicht blank, nicht der Sentinel). Roster wird EINMAL pro Session-Extraktion gebaut, nicht pro Map-Reduce-Chunk. Ehrliche Grenzen: Einmal-Figuren (nur 1 Session) bleiben dauerhaft im Freitext-Pfad; Cloud-Backends (kein GBNF-Zwang, #783) bekommen keine strukturelle Garantie für `cast_match`, dort bleibt es effektiv unvalidiertes Freitext-Vertrauen wie `character` selbst.
- **Entity-Registry** (best-effort, kein Status) — campaign-weites Guise-Merging (`EntityRegistry.resolve_campaign_entities`, #714; Cluster-Fehler lässt die Fakten unverändert).
- **Thread-Registry** (best-effort, im selben `resolve`-Schritt, #832) — campaign-weites **Handlungsbogen-Clustering** der rohen `thread`-Labels (#831) zu kanonischen Strängen. **Whole-Snapshot-Artefakt** (`ThreadRegistryComputed` → `worker_thread_registry`, 1 Row/Kampagne) — anders als die Entity-Registry re-keyt es die Fakten NICHT; die Map lebt separat, der Reader (`campaign_threads/1`, Slice D1) wendet sie zur Lesezeit an. **Seit #885 klassifiziert das Clustering jeden Kanon-Strang als `arc` (auflösbarer Handlungsbogen) oder `context` (zeitloses Weltwissen — schließt nie ab), seit #901 (Epic #900, kinds-Trichotomie) zusätzlich als `rauschen` (Meta-/Tisch-/Werkzeug-Gerede — fällt aus den inhaltlichen Sichten)**: die `kinds`-Map reist im selben Snapshot (JSON-Envelope `{map, kinds}` im Blob, Alt-Rows/Alt-Events bleiben lesbar → kind `arc` fail-safe; unbekannte kind-Werte kollabieren auch am Reader sichtbar auf `arc`), das Fäden-Panel listet Arcs zuerst, Contexte als eigenes „📚 Themen"-Register OHNE Auflösungs-Semantik (kein auflösen-Button/🏁; `false_resolve` ist für Contexte undefiniert — Vorbedingung fürs #837-Gate) und Rauschen-Stränge in einem zugeklappten „🔇 Rauschen"-Unter-Register mit Rettungs-Buttons (raus aus Hauptliste + Header-Zähler), Member stufen per dritter Override-Dimension `kind` um (`mark_arc | mark_context | mark_rauschen | clear_kind`, gleiche LWW-Overlay-Mechanik wie #836). Cluster-Fehler → eigene `/admin/errors`-Klasse `resolve_threads` (wie #820), Fakten behalten ihr Roh-Label. **Seit #903 (Epic #900 S2) ist der Arc ein erstklassiges Objekt** (`worker_arcs`, eine Row pro Bogen, drei fold_meta-Gruppen `:arc_created`/`:arc_act` (geteilt Closed+Reopened)/`:arc_leitfrage`): Geburt maschinell im selben resolve-Schritt (arc-kind-Stränge ohne paarenden Arc; `arc_id` content-adressiert über campaign_id + sortierte Seed-Roh-Labels; Leitfrage-Draft deterministisch, kein LLM), Status NIE geschrieben sondern am Reader ABGELEITET (offen | geschlossen(geloest|versandet); versandet reopent automatisch gdw `max_fakt_session > wasserlinie_session` — die Wasserlinie reist ZUR SCHREIBZEIT im ArcClosed-Payload, max `last_touched_session` der campaign_threads), Arc-Felder reiten flach in den `campaign_threads`-Maps. Panel: Arc-Stränge schließen/öffnen über `ArcClosed`/`ArcReopened` (Member-Recht `:curate_threads`), Legacy-`resolve`-Override nur noch für arc-lose Stränge lesbar (Akt-Präzedenz: irgendein Arc-Akt überstimmt Legacy); Leitfrage inline kuratierbar (`LeitfrageSet`, leer = Undo → Draft). **#539 ist mit #903 erledigt:** `Shared.Events.k/1`-Compile-Zeit-Makro (Pattern-Head-tauglich, validiert gegen die 0-arity-Konstanten) — Consumer-Matches (CampaignLive/Updates/Seed-Tasks) laufen darüber; neue Event-Kinds in Emits als Funktions-Call, in Pattern-Heads via `k(:...)`. **Seit #907 (Epic #900 S4)** gibt es die **Nachlese-Seite** `/campaigns/:id/nachlese` (`HubWeb.NachleseLive`, 📖-Link in der CampaignLive): die erste REINE Ableitung der Wahrheitsbasis für den #687-Use-Case — Recap der letzten Session (+#715-Flagging), offene Bögen (aktiv zuerst, Leitfrage + Prosa-Progressions-Chronik #838, s.u.; Abgeschlossene zugeklappt), Who's-who (deterministisch aus verifizierten Fakten; `pc?` = Alias-Match gegen Member-Figurennamen — benannte Heuristik) + zugeklapptes 📚-Themen-Register; eigener schmaler member-gated Snapshot-Scope `campaign_nachlese` (`Worker.Repo.Nachlese`), kein LLM (die Blöcke selbst, Prosa-Progressionen sind bereits fertig gerenderte Artefakte aus dem Pipeline-Schritt unten), kein Live-Refresh in v1. **Seit #838** rendert die Pipeline zusätzlich pro in einer Session berührtem Handlungsbogen EINEN Prosa-Absatz (`render_arc_progressions`, Status-Name im Pipeline-Log; s.u. „Geschwister-Render"), gespeichert als EIN eigenständiger, NIE überschriebener Eintrag pro `{arc_id, session_id}` (`worker_arc_progressions`) — die Nachlese zeigt pro Bogen ALLE bisherigen Einträge chronologisch (nicht nur einen zuletzt überschriebenen „Stand"), Fallback auf die alte „N Fakt(en)…"-Zeile solange ein Bogen noch keinen Eintrag hat. **Seit #905 (Epic #900 S3)** dazu: **Arc-Merge als Read-Zeit-Redirect** (`ArcMergeSet` → `merged_into`-Spalte, Fold-Gruppe `:arc_merge`; Redirect wirksam gdw. Ziel existiert UND selbst un-gemerged — Ein-Level, Zyklen/Ketten degradieren zu wirkungslos-aber-sichtbar), **⚠-Arc-Review-Register** im Fäden-Panel (verwaiste Bögen mit sichtbarem Close-Status + Merge-Select mit Seed-Überlapp-Vorauswahl = Duplikat-Heilung; Gemergte mit Undo; die Listen „atmen" im Verify-Fenster — benannte Grenze) und **Fakt→Arc-Override** (`FactArcSet`, `worker_fact_arc_overrides`; `max_fakt_session` ist seit #905 FAKT-genau — ein Override rein/raus kippt das versandet-Gate präzise; Fakt-Liste id+claim pro Strang reitet im Snapshot). **Seit #953 ist der Override ein SET (N:M): Payload `arc_ids: [ids] | null` mit DREI sauber getrennten Zuständen (#766-Klasse): `[ids]` = Override auf genau diese Bögen · `[]` = explizit KEINE Bögen · `null`/absent = RÜCKNAHME (Extraktions-Label-Kette gilt wieder — löst „einmal übersteuert = taub gegen Re-Extraktion"). `overridden?` wird am Reader aus dem Set-Wert abgeleitet, NIE aus Row-Präsenz (H1). Alt-Skalar `arc_id` (`""` = Rücknahme, `"X"` = 1-Element-Set) feldkonservativ mitgelesen. Verwaiste arc_ids (Ziel weg-geclustert/gemergt) bleiben im Storage (NIE bereinigt) und fallen erst am Read fürs Rendern raus (flag-not-drop), im Fäden-Panel als „⚠ N verwaist" sichtbar. UI: Multi-Select-Checkboxen pro Bogen + „🔄 Auto"-Rücknahme-Button. Das arc-STATUS/versandet-Gate (#903) bleibt bewusst 1:1 (erstes Set-Element), nur der Render (`fact_render_assignments/2`) + die Panel-Anzeige gehen N:M.** **Seit #842 läuft das Clustering inkrementell** statt bei jedem Pipeline-Lauf komplett neu: nur die Roh-Labels, die seit dem letzten Lauf neu dazugekommen sind, werden gegen die bestehenden Kanon-Stränge als Kontext geclustert (`resolve_campaign_threads/2`) — bestehende Kanon-Texte werden dabei nie verändert (schützt die ältere `worker_thread_overrides`-Kuration #836 vor Verwaisen im Normalfall, auch wenn diese Tabelle selbst weiterhin auf dem kanonischen Anzeigetext keyt, kein Re-Attach analog Arc). Der frühere Vollpfad (`full_recluster_campaign_threads/2`) bleibt als seltener, expliziter, GM-getriggerter Button im Fäden-Panel („Fäden neu clustern") erhalten — dabei KÖNNEN sich Kanon-Texte ändern (bekanntes Restrisiko, Confirm-Warnung im UI).
- **Verify-Gate** (`Verify.verify_session`, Status `"verify"`) — Quell-Grounding + Attribution auf kanonischen Entitäten, Flag-statt-Drop (`verified? = grounded? AND attributed?`).
- **Geschwister-Render** (Status `"render"`/`"timeline"`/`"render_epos"`) — Resümee/Timeline/**Epos-KAPITEL pro Session** aus den **verifizierten** Fakten, mit Render-Gating; #752: Kapitel strikt isoliert aus E_n, deterministischer Kapitel-Kopf aus der Timeline-Tag-Range, Datenmodell entry_id=session_id/parent_id=campaign_id, Legacy-Buch („Alt-Epos") koexistiert in der UI. Timeline+Epos sind fehler-entkoppelte best-effort-Geschwister. **Seit #838 kommt ein drittes Geschwister dazu: die Prosa-Progression pro Handlungsbogen** (`publish_wahrheitsbild_arc_progressions/3`, Stage 4 wiederverwendet — kein eigener Stage 6, analog dem ursprünglichen Epos-Precedent) — EIN LLM-Call pro (Session × in dieser Session berührtem Bogen), Fehlerisolierung PRO BOGEN innerhalb des Schritts (nicht nur am äußeren best-effort-Wrapper, Design J: ein fehlschlagender Bogen darf weder andere Bögen noch den Rest der Pipeline mitreißen). Speicherung: EIN eigenständiger, NIE überschriebener Eintrag pro `{arc_id, session_id}` (`worker_arc_progressions`, `ArcProgressionGenerated`) statt einer stets überschriebenen kumulativen Zeile — macht das Feature strukturell replay-sicher (ein Regenerate einer älteren Session rührt spätere Einträge desselben Bogens nie an, `Repo.get_prior_arc_entry/3` bestimmt den „vorherigen Eintrag" zur Lesezeit über die größte `session_number < aktuelle`, nie über einen gespeicherten Zeiger) und ist die Grundlage der Nachlese-Chronik oben. Prompt sieht nur den unmittelbar vorherigen Eintrag + die Session-Delta-Fakten (Backfill-Fall: volle Arc-Historie beim ersten Lauf nach dem Feature-Rollout für einen Bestandsbogen); das Render-Gate prüft dagegen immer gegen die VOLLE Arc-Fakt-Historie (`Repo.arc_fact_claims/2`, Design H). **Seit #909 (Epic #900 S5) rendern Stage 4+5 ARC-STRUKTURIERT statt als flacher Fakt-Dump**: `render_with_gate` annotiert die Fakten via `Repo.fact_render_assignments/2` (Label-Kette + FactArcSet-Override + Merge-Redirect — exakt dieselbe Präzedenz wie das Fäden-Panel, geteilte `Threads.effective_kind/3`). **Seit #953 ist die Zuordnung N:M** (`%{fact_id => [%{titel, kind}, …]}`): ein Fakt mit mehreren `threads`-Labels (oder einem Override-Set) wird unter JEDEN zugeordneten Bogen dupliziert (`annotate_boegen` flat_map). Ehrliche Grenze: derselbe Claim geht N-mal in den Render-Kontext → **Prompt-Gewichtsverzerrung** (ein Zwei-Bogen-Fakt wiegt doppelt); Prosa-Dedup ist Folge-Arbeit. Das Render-**Gate** bleibt auf dem Original-verified-Set (`fact_claims(verified)`, NICHT der duplizierten Liste) → keine Claim-Inflation, keine False-⚠. Reine Sekundär-Labels ohne eigenen Thread (das Panel gruppiert 1:1 übers Primär-Label) werden fürs Render synthetisiert (Titel = Kanon, kind aus der Registry). Der Resümee-Prompt gruppiert nach Handlungsbögen mit **sichtbaren fetten Bogen-Abschnitten** (1–2 Sätze pro Bogen, strang-lose unter „Weiteres", Ein-Fakt-Bögen wandern dorthin — Anti-Fragmentierung), der Epos-Prompt nutzt die Bögen als rote Fäden bei fließender Erzählung. **rauschen-Fakten fliegen immer raus, context-Fakten beim Resümee** (die Free-Seattle-Regelwerk-Ursache); beim Epos reist context als „Hintergrund (nur Farbe)"-Sektion mit. Die Leitfrage ist NIE Prompt-Input (Gruppen-Kopf = kanonischer Bogen-Titel). Fallback-Kaskade statt Fehler: nur-context-Session → context flach, alles-rauschen → Voll-Liste + Warning; ohne Kampagnen-Kontext/Annotation (Stil-Vorschau, `mix lore.eval.summary`) rendert der flache Alt-Prompt unverändert. Das Render-Gate strippt reine Titel-Zeilen vor dem Claim-Split (Titel sind Struktur, keine Claims — sonst False-⚠). Dazu der **fail-loud Prompt-Größen-Guard** (#889): Local-Backend + `estimate_tokens(prompt) > ctx_stage4/5` → Fehlerklasse `render_prompt_too_large` in `/admin/errors` statt Ollama-Silent-Truncation mit persistierter Entschuldigung (Cloud-Backends bewusst ungeguarded — sie ignorieren `num_ctx`, Oversize failt dort als `http_error`).

### CampaignLive: Lesen|Bearbeiten-Modus + Falsifikations-Flags (Epic #911 „Ernte statt Pflege", Cut 1 = #915)

Die CampaignLive hat **einen Layout mit einem Lesen|Bearbeiten-Toggle** (Header, neben „Pipeline neu starten"). Der Modus lebt in `HubWeb.CampaignLive.ViewMode` (`view_mode.ex`), Default **`:lesen`** (der Erfolgs-Prüfstein „öffnet ein Spieler es freiwillig?"), per-Gerät in localStorage gemerkt (`view_mode_persist.js`, Muster `PersistCols`). Der Toggle ist nur für Kuratoren sichtbar (`can_edit_mode?` aus `HubWeb.CampaignLive.Derive` — GM ODER Member-Kurator; `derive_assigns/2` wanderte in #915/Slice 1 aus `campaign_live.ex` in `Derive`, God-Module-Entlastung). Der Modus schaltet **Palette + Affordances = f(Modus)**, NIE die Autz-Schranke (jeder Edit prüft sein `can?/3`-Recht serverseitig selbst): Lesemodus = Nachlese-Band (Recap + offene Bögen, lazy über den bestehenden `campaign_nachlese`-Scope) + read-only Prosa-Spalten; Bearbeitenmodus = zusätzlich die Protokoll-Spalte, das Fäden/Themen-Panel, die Review-Queue, die Kurations-Tabs und die Prosa-Edit-Pencils. Ehrliche Grenze: die read-only **Fakten-Spalte ist Cut 2 (#916)** — dort wird sie editierbar; Epos-Edit-Pencil + geglättet-Kuratieren-Affordance sind in Cut 1 noch ungegated (Kurator-in-Lesemodus-Leak, serverseitig weiter geschützt); der Moduswechsel-Anker ist best-effort.

**Falsifikations-Flag** (der EINZIGE erlaubte Spieler-Signal-Pfad, „stimmt nicht" — meldet, korrigiert nicht): Events `FlagRaised`/`FlagResolved`/`FlagDismissed` (Shared.Events). Ein Member flaggt ein **rebuild-stabiles Objekt** (`target_kind ∈ {session, arc, fact}`, `target_id ∈ {session_id, arc_id, fact-content-id}` — NICHT ein gerenderter Span), ein Kurator löst/verwirft. Worker-Seite: EINE `worker_flags`-Row pro Objekt (Key `cid:target_kind:target_id`), die drei Events konkurrieren um den geteilten Fold `:flag_status` (LWW-by-event_id, `Worker.Materializer.FlagFolds`); der Lesepfad (`Worker.Repo.Flags.flags_effective/1-2`) berechnet den effektiven Status zur **Lesezeit** — insbesondere **Auto-Resolve für Fakt-Flags**, deren fact-content-id nicht mehr existiert (weg-regeneriert → `auto_resolved`, kein Write, `luecken`-`verwaist`-Muster). Member-gated `campaign_flags`-Snapshot-Scope liefert nur die offenen Flags (⚠-Marker + Kurator-Queue). Hub-Seite: `:flag_raise` = Member-Recht, `:resolve_flag` = **GM-only in Cut 1** (`permissions.ex`); Melden-Button pro Session im Recap, ⚠-Marker wenn offen, Kurator-Queue (GM, Bearbeitenmodus) mit erledigt/verwerfen (`HubWeb.CampaignLive.Flags`, serverseitiges Gate). Melden-UI ist in Cut 1 auf Session-Ebene verdrahtet (Arc/Fakt-Melden-Buttons = Folge-Arbeit; Backend + Queue tragen alle drei target_kinds bereits).

**Editierbare Fakten-Spalte (Cut 2 = #916).** Die Fakten-Spalte (Bearbeiten-Palette) ist die direkte L1-Wahrheitsbasis-Kuration: **claim / character / thread / verified?-Override / löschen(ausblenden)**, je als LWW-Overlay-Event `FactCurationSet` (kein In-Place-Edit). **Anker = die Utterance-Menge** eines Fakts (`⋃ source_ref_block.quell_utterance_ids`), NICHT die content-adressierte Fakt-ID — der claim-Edit ändert die ID, die Utterance-Menge bleibt stabil → der Override re-attacht nach einem Regenerate (`Worker.Repo.Artifacts.apply_fact_curation/2`, `by_quell`-Paarung wie die Lücken-Overrides). Worker: **neue** Tabelle `worker_fact_overrides` (getrennt von `session_fact_overrides` #724 = Datum/dismiss), EINE Row pro (Anker, Feld) → unabhängige LWW-Slots. **Mehrdeutigkeit** (zwei Fakten identische Utterance-Menge): mengen-sichere Felder (character/thread/verified) angewandt, claim/dismissed geblockt + `override_mehrdeutig`-Flag (nie stille Falschzuordnung); nicht-paarende Overrides bleiben sichtbar. `list_campaign_facts/1` filtert `curation_dismissed` (Render/Verify/Timeline), `list_campaign_facts_curation/1` hält sie sichtbar (Fakten-Spalte, Un-Dismiss). Member-gated `campaign_facts`-Scope (lazy im Bearbeitenmodus). Hub: `:curate_facts` Member-Recht (`HubWeb.CampaignLive.Facts`, serverseitiges Gate; `anchor_hash` deterministisch aus der sortierten Menge). **Span-Flag-Upgrade (Cut 2):** additives `target_kind "span"` (tid = komma-verkettete Utterance-Menge), Span-Melden auf der Fakt-Zeile; Auto-Resolve gdw. die Menge keine aktuelle Fakt-Utterance mehr berührt (`flags_effective/3` `covered_utts`, disjoint). Bestehende `fact`-Flags unberührt. **Cut-2-Nebenfix:** `session_fact_overrides` war in KEINER Cascade — jetzt in beiden geräumt. Ehrliche Grenzen: Mehrdeutigkeit blockt claim/dismissed statt zu raten; Span-Melden nur aus der Fakten-Spalte; Anker-Drift bei Smoothing-Kompositions-Änderung → verwaiste (sichtbare) Overrides, Re-Attach nicht automatisch.

Jeder Schritt läuft in `with_status` → eigene Fehlerklassen in `/admin/errors` (#716). **Seit #783 Phase 2 (+ Nachtrag) hat jeder LLM-Schritt sein eigenes Backend + Modell**: `backend_stage2`/`model_stage2_<backend>` (Extraktion), `backend_stage3`/`model_stage3_<backend>` (Verify — Grounding + Attribution), `backend_stage4`/`model_stage4_<backend>` (Render-Resümee), `backend_stage5`/`model_stage5_<backend>` (Render-Epos-Kapitel — Nachtrag, war anfangs Teil von Stage 4). Damit kann der Verify-Judge gezielt stärker sein als der Extraktor ("fox guarding henhouse"-Vermeidung, der #783-Ursprungs-Usecase), Resümee und Epos können unterschiedliche Modelle nutzen (kurz/faktentreu vs. länger/literarisch), und Kosten lassen sich gezielt verteilen (Extraktion billig/lokal, Verify/Render ggf. Cloud). Die früheren Phase-1-Overrides `judge_model`/`render_model` (gleiches Backend, nur anderes Modell) sind mit der vollen Trennung entfernt. **Provenance-Stempel:** `SessionFactsExtracted` trägt `verify_backend`/`verify_model`, `SessionSummaryGenerated` trägt `render_backend`/`render_model`, `EposEntryEdited` trägt `epos_backend`/`epos_model` (additiv, reine Persistenz — macht einen Backend-Wechsel zwischen zwei Sessions sichtbar, ist aber kein Pin-Mechanismus; der bleibt Phase 4 der Multi-Worker-Architektur-Arbeit). **Migration für Bestandsworker:** `Worker.Application.migrate_stage2_to_stage34_if_unset!/0` kopiert beim ersten Boot nach dem Update Stage 2s Werte einmalig nach Stage 3/4, `migrate_stage4_to_stage5_if_unset!/0` (Nachtrag) analog Stage 4 nach Stage 5 (beide idempotent, gated auf einem rohen `backend_stage{3,5}`-Store-Read) — ohne das würde ein Bestandsworker mit `:no_model_configured` brechen. **Stil-Flavors (#787):** die Campaign-Flavors (`base` + `summary`/`epos`) wirken in den **Render-Prompts** (hinter dem Verify-Gate — Stil kann keine Fakten einschleusen, das Render-Gating fängt Dazudichtung); die Extraktion ist stilfrei, die Timeline deterministisch (kein Ton-Slot). Der Stil-Editor in der CampaignLive hat Tabs Resümee/Epos/Chronik mit Live-Prompt-Vorschau für die zwei Render-Slots (`preview_prompt/2`, byte-genau dieselben Builder wie die Pipeline). Die Überschrift (`vorgaben[stage].name`) setzt bei allen drei den **Spaltentitel**; nur beim Resümee wirkt sie zusätzlich als Textsorte-Direktive im Prompt (Epos-Kapitel-Köpfe sind deterministisch #752, die Timeline hat keinen Prompt). Historie: Default-Flip auf Wahrheitsbild 2026-07-08 nach dem Free-Seattle-Real-Lauf; Retention: historische Chain-Events/-Artefakte bleiben lesbar (Materializer-Folds + Event-Schemas unangetastet, nur die Producer sind weg).

**Zeitstrahl / Datums-Auflösung (#724).** Der Timeline-Publish ist verdrahtet: `run_wahrheitsbild` datiert die verifizierten Fakten deterministisch und schreibt sie als Chronik-Einträge (`publish_wahrheitsbild_timeline` → `Timeline.Graph.resolve` → `Render.timeline` → `ChronikEntryChanged`). Kernprinzip: das LLM liefert pro Fakt **Anker + Offset + Präzision + narration_time** (Erzählzeit vs. erzählte Zeit — Flashback/Prophezeiung), **Elixir rechnet das Datum** deterministisch auf einem Tageszähler (`Worker.Timeline.{Calendar,Resolver,Graph}`) — so landet eine erzählte Rückblende chronologisch in der Vergangenheit statt zur Aufnahmezeit. Persistenz: eigene Tabellen `@campaign_calendars` (per-Campaign-Kalender, Default Gregorian) + `@session_anchors` (In-Game-Datum-Anker pro Session), gesetzt via Events `CampaignCalendarSet` / `SessionInGameAnchorSet`; `chronik_entries` trägt `in_game_day` (Sort-Schlüssel) + `precision`. UI: pro Session ein 📅-Datumsfeld, ein „Kalender"-Config-Tab, und ein `~`-Präzisions-Marker in der Chronik. Ehrliche Grenze (#686): `narration_time` (required) ist das verlässliche Signal; relative Offsets sind modell-abhängig (Eval-Frage). **Seit #911/#958 filtert `publish_wahrheitsbild_timeline/3` VOR `Graph.resolve` zwei Vorstufen weg**, die die Chronik sonst zum Fakten-Dump machten (Free-Seattle-Befund: 544 von 548 verifizierten Fakten wurden Chronik-Einträge): `Graph.time_signal?/1` (pure) verlangt ein EIGENES Zeit-Signal des Fakts (Anker/Offset/`in_game_date`-Bridge #676/#729) statt des reinen Präsens-Fallbacks (`narration_time == "present"` ohne jedes Signal sitzt sonst automatisch am Session-Anker-Tag), und `Repo.filter_arc_kind/2` lässt nur `kind == "arc"`-Fakten durch (gleiche Zuordnung wie Resümee/Epos seit #909, `fact_render_assignments/2`) — die Chronik ist ein Bogen-Zeitstrahl, kein Protokoll-Abzug.

**Review-Queue für undatierte/unsichere Fakten (#724 Slice F).** `Worker.Repo.campaign_review_facts/1` zeigt verifizierte Fakten, die der Zeitstrahl nicht platzieren kann (Flashback/Zukunft/unklare Erzählzeit ohne Datum/Offset — das #686-Sicherheitsventil). Der GM kann pro Fakt in der Kampagnen-Ansicht ein Datum setzen oder ihn dauerhaft ausblenden (Event `SessionFactDateSet`). Fold ist ein reiner LWW-Upsert in einer eigenen Overlay-Tabelle (`worker_session_fact_overrides`) statt eines Patches am `session_facts`-Blob — ein Read-Modify-Write wäre order-sensitiv gewesen UND hätte `Verify.verify_session`s Set-Semantik-Re-Publish die GM-Korrektur zermahlen lassen. **Niemals ein `:mnesia.delete`**: auch der Undo-Fall (leeres Datum) schreibt eine reguläre Row, sonst divergiert ein vertauschtes Set→Undo-Paar zwischen Workern (#698-Klasse). Der Read-Merge (`Worker.Repo.Artifacts.merge_override/3`) pinnt jeden Override zusätzlich an die **Extraktions-Generation** (`extraction_event_id` = das `event_id` der `SessionFactsExtracted`-Row, gegen die der GM den Fakt sieht) — Fakt-IDs sind rein positional (`"f<index>"`, nicht run-eindeutig), ohne diesen Anker würde ein Override nach einem Regenerate auf einen unbeteiligten neuen Fakt an derselben Position durchschlagen. Ein gesetztes Datum forciert `time_anchor => "absolute"` (der Resolver nimmt den Absolut-Branch sonst nicht, Review-Fakten haben oft `time_anchor == "unknown"`). Ein Override-Datum, das `Calendar.parse` nicht auflöst, bleibt bewusst in der Queue (`date_parse_error`-Flag, flag-not-drop) statt den Fakt fälschlich als erledigt auszubuchen. Der Zeitstrahl-Republish nach einer Korrektur ist rein deterministisch (`Pipeline.republish_timeline_for_session/1`, kein LLM) und läuft race-frei über denselben Author-Worker-Election-Mechanismus wie der reguläre `UtterancesTranscribed`-Trigger (`elected?/2`, #365) — kein neues Hub-Command nötig. Ehrliche Grenzen: ein Regenerate vergibt neue Positions-IDs und lässt bestehende Overrides orphanen (Verhalten konsistent zum Chronik-Edit); stirbt der Author-Worker zwischen Fold und Republish, heilt der nächste Trigger/Regenerate.

### LLM-Pipeline-Backfill für nachgereichte Sessions

`Worker.Recording.Pipeline` feuert nur auf `UtterancesTranscribed`-Events während einer **echten Aufnahme**. Für seeded oder nachträglich importierte Sessions muss man die Pipeline pro Session manuell triggern — seit Issue #121 als direkter Pipeline-Call ohne Hub-Event-Roundtrip:

```elixir
:rpc.call(:"worker_prod@#{hostname}", Worker.Recording.Pipeline, :run_for_session, [SESSION_ID])
```

**Pro Session warten bis fertig bevor die nächste getriggert wird** — sonst rennen N LLM-Calls gleichzeitig durch den Ollama-Backend (mit großem Modell ~1 Inferenz auf einmal sinnvoll). Completion-Signale (von schnell nach robust):

- `Worker.Recording.Pipeline`-GenServer-State (`:sys.get_state(…).running`) listet aktive `session_id`s — gone = done. Reicht für sequentielles Trigger-Skript (oder `Pipeline.busy?/0`, #775).
- `Worker.Repo.get_session_summary(session_id)` ≠ `nil` bestätigt dass die Extraktion+Render mindestens liefen.
- Korrektes Signal für volle Pipeline-Completion: `pipeline_status`-PubSub-Events watchen, auf `render_epos` terminal (`ended`/`failed`) warten.

Nur der **Owner-Worker** (`campaign.owner_discord_id == worker.admin_discord_id`) führt die Pipeline aus — bei Multi-Worker-Setups muss der Trigger den richtigen Worker erwischen. Das `--regenerate-llm`-Flag aus Issue #58 wird genau diesen Pattern abbilden.

### Cloud-LLM-Backends (Issue #27, ab Etappe 5b direkt vom Worker)

Seit Issue #162 (Etappe 5b) calls der Worker Cloud-LLM-APIs **direkt** — Hub kennt keine Cloud-Credentials mehr. Kein Proxy, kein Vault.

Setup pro Worker-Maschine: passende Env-Var in der Worker-Start-Umgebung (`.env` neben dem Worker oder direkt vor `mix run`). Dann in `/settings` Stage-Backend auf das gewünschte Backend + ein Modell aus dessen `models/0`. Wenn die Env-Var fehlt, scheitert die Pipeline-Stage mit `:no_key_configured` (Logger-Warning, kein silent Fallback auf Ollama). **Seit #784** hat auch die Modellwahl keinen Fallback mehr: ein Backend ohne gesetztes `model_stage{n}_<backend>` (pro-Backend-Key, keine Legacy-`model_stage{n}` mehr) scheitert fail-loud mit `{:no_model_configured, stage}` — statt still einen lokalen Ollama-Namen an die Cloud-API zu schicken. Der Local-Endpoint (`local_endpoint`) sowie `whisper_bin` / `ffmpeg_bin` haben ebenfalls keinen Default mehr; frische Worker setzen sie in `/settings` (Bestandsworker mit persistierten Legacy-Werten sehen beim Boot ein `Worker: stale Legacy-Setting …`-Warning und müssen ihre Modelle einmal pro Backend nachziehen). Zusätzliche Range-Sanity: `*_ms`-Keys werden im Settings-Save gegen ein 24-h-Ceiling geclamped (verhindert Tippfehler-Blockaden wie das reale `http_timeout_ms=1_200_000_000`, ~13 Tage, auf worker_prod).

Unterstützte Backends:
- **Anthropic** (`ANTHROPIC_API_KEY=sk-ant-...`) — `Worker.LLM.Anthropic.complete/2` ruft `https://api.anthropic.com/v1/messages` mit `x-api-key: $ANTHROPIC_API_KEY`. Modelle: `Worker.LLM.Anthropic.models/0`.
- **OpenAI** (`OPENAI_API_KEY=sk-proj-...`) — `Worker.LLM.OpenAI.complete/2` ruft `https://api.openai.com/v1/chat/completions` mit `Authorization: Bearer $OPENAI_API_KEY`. Modelle: `Worker.LLM.OpenAI.models/0`.
- **Google Gemini** (`GEMINI_API_KEY=...`) — `Worker.LLM.Google.complete/2` ruft `https://generativelanguage.googleapis.com/v1beta/models/<MODEL>:generateContent?key=$GEMINI_API_KEY` (Auth via Query-Param, nicht Header). Modelle: `Worker.LLM.Google.models/0` (gemini-2.5-pro / -flash / 2.0-flash / -flash-lite). Body-Shape unterscheidet sich (`contents/parts` statt `messages`).

**Gemeinsamer Code** (Issue #463): Retry-Loop, HTTP-Error-Mapping, `LLMCallBilled`-Spend-Event und Stage-→-Modell-Lookup leben in `Worker.LLM.CloudHelper`. Backend-spezifisch bleibt nur die Request-Shape, das Response-Parsing und die Auth-Mechanik. Neue Cloud-Backends spiegeln das Anthropic-Modul (~50 Zeilen) und reusen den Helper. **`stage_label`-Bedeutungsverschiebung (#783 Phase 2):** historische `LLMCallBilled`-Events mit `"stage" => "stage3"`/`"stage4"` (Chain-Ära, vor #786) bedeuteten Epos/Chronik — seit diesem Umbau bedeuten dieselben String-Labels Verify/Render. Für die Admin-Anzeige (rendert `r["stage"]` roh) irrelevant, für zeitraumübergreifende Spend-Auswertungen zeitstempel-bewusst lesen.

HTTP-Error-Mapping einheitlich für alle drei Backends: 401/403 → `:upstream_auth`, 429 → `:upstream_rate_limit`, 5xx → `{:upstream_error, status, msg}`, Netz/Timeout → `{:network_error, reason}`. Retry: 2× exponentielles Backoff (500ms / 1s) bei 429/5xx/Network, sofort hart bei :upstream_auth + 4xx ≠ 429 (Client-Fehler).

Folge-Issues (separate Tickets): `LLMCallBilled`-Event für Spend-Tracking (#177), Streaming (#176), Per-User-Spend-Caps (#178).

### Campaign-Pipeline-Trigger (Issue #104)

In der Campaign-LV gibt es zwei Buttons (sichtbar je nach Rolle):

- **`🔄 neu generieren`** pro Session (in der Resümee-Spalte): Owner, Spielleiter-mit-Membership oder Admin. Triggert direkt `Worker.Recording.Pipeline.run_for_session/1` im Owner-Worker via `Hub.Commands.request_session_regenerate/3` (Channel-Push, kein Event-Roundtrip — siehe Issue #121).
- **`🔄 Pipeline für alle Sessions neu starten`** im Campaign-Header: Spielleiter-mit-Membership oder Admin. Triggert `Worker.Recording.CampaignReplay` im Owner-Worker, der sequentiell alle Sessions durchschickt + via `pipeline_status` (kind: `"campaign_replay"`) live einen Banner mit Fortschritt liefert.

Lock im Worker — nur ein Campaign-Replay pro Worker gleichzeitig. Bei laufendem Replay sind beide Buttons disabled. Stage-Failures werden geloggt (`Pipeline: failed for session=…`) aber der Replay macht trotzdem mit der nächsten Session weiter — sonst würde eine misslungene Stage 2 das ganze Backfill blockieren.

### LLM-Probelauf (Issue #74; seit #786 Wahrheitsbild-nativ)

Statt manuell pro Session zu triggern: unter `/admin/probelauf` (nur :admin) gibt es einen „Probelauf starten"-Button. `Worker.Probelauf` seedet eine eigene `probelauf-<uuid>`-Kampagne (Sessions à 10/30/100/~800 Utterances — short/medium/long/real), schickt sie sequentiell durch die Wahrheitsbild-Pipeline und misst pro Schritt (`extract`/`verify`/`render`/`timeline`/`render_epos`) Wall-Clock + Outcome (`ok`/`failed`/`timeout`/`skipped`) + #716-Fehlerklasse, dazu pro Session den **Verify-Trichter** (`n_facts → n_grounded → n_verified` — das wichtigste Signal) und Output-Größen. Publisht `ProbelaufFinished` und cascade-deleted die Kampagne. UI zeigt Heatmap pro Session × Schritt (Spalten dynamisch — alte Chain-Reports mit stage2/3/4-Spalten bleiben renderbar) + Trichter-Zeile + Heuristik-Empfehlung; „Empfehlung übernehmen" schreibt direkt in `Worker.Settings`. Dazu ein **Extraktor-Modell-Sweep** (variiert `model_stage2_<backend>` über eine Modell-Liste, pro Modell ein voller Lauf; Ranking nach Verify-Rate). Die früheren Chain-Werkzeuge (Stage-Wahl, Isolated-/Param-/Multi-Stage-Sweep, Goldstandard-Pre-Seed #201) sind mit #786 entfernt.

Probelauf-Campaigns sind aus `campaigns_for`/`all_campaigns` rausgefiltert (Prefix-Match `probelauf-`). Lock im `Worker.Probelauf`-GenServer — nur ein Lauf gleichzeitig pro Worker.

#### LiveView-Gotchas (gesammelt beim Bau von /admin/probelauf)

- **`fetch_live_flash` muss im `:browser`-Pipeline sein**, sonst crasht jeder LiveView der `put_flash(socket, ...)` im mount/load_data ruft mit `ArgumentError "flash not fetched"`. Andere LiveViews funktionieren oft „zufällig" weil sie put_flash nur im Fehlerpfad nutzen — neuer LiveView ohne den Plug fällt auf die Nase sobald der reload-Pfad einen Flash schreibt.
- **HEEx `@assigns` ≠ Modul-Attribute**: `@stages` im Template referenziert immer `socket.assigns.stages` — Modul-`@stages` muss explizit als `assign(:stages, @stages)` in mount durchgereicht werden. Sonst `KeyError :stages` bei render.
- **`Worker.Repo.serialize/1` braucht `nil`-Klausel** wenn Snapshot-Felder optional sind (z.B. `running == nil` wenn nichts läuft). Sonst FunctionClauseError beim Snapshot.
- **Modal-Pattern: `<.lt_modal on_close="...">` benutzen, NIEMALS `onclick="event.stopPropagation()"` (Issue #352)**: Phoenix-LiveView registriert seine Click-Listener delegated auf document-Level. Wenn man im Modal-Body ein `onclick="event.stopPropagation()"` setzt um Backdrop-Klick-Schließen-Bubbling zu unterdrücken, killt das **alle** `phx-click`/`phx-change`/`phx-submit`-Events innerhalb des Containers — Buttons im Modal scheinen tot, kein Crash, kein Log. Der korrekte Pattern ist die `HubWeb.UIComponents.lt_modal/1`-Komponente: backdrop = `phx-click`, content = `phx-click-away`, KEIN JS-stopPropagation. Iron-Law-Regel #6 scant nach dem Anti-Pattern.

### Modell-Inkompatibilitäten + Pipeline-Robustheit (Issue #75/#786)

Die Extraktion läuft im strict JSON-Schema-Mode (Ollama-GBNF, `facts_json_schema/0` — invalides JSON ist token-seitig unmöglich, `<think>`-Blocks werden strukturell eliminiert); für Cloud-Backends/ältere Modelle bleiben die defensiven Parser-Fallbacks (`strip_and_note/1`: think-strip, Code-Fence-strip, JSON-Extract). Liefert ein Chunk kein verwertbares JSON oder degeneriert er, greifen `extract_num_predict_cap` (#763-Deckel) + Halbierungs-Retry; eine leere Extraktion meldet `failed` mit Klasse `extraction_empty` statt stillem `ended`. Bei großen Modellen + langem Prompt kann ein Call am HTTP-Timeout scheitern — Default `Worker.Settings.get(:http_timeout_ms, 600_000)`, per Worker tunbar.

Empfohlener Sanity-Check pro Worker-Setup vor dem ersten Backfill:

```elixir
# Modell antwortet überhaupt im JSON-Mode? (:summary = der eine LLM-Slot)
:rpc.call(node, Worker.LLM, :complete, [:summary, "Antworte mit {\"ok\":true}", [format: "json"]])
```

### Chronik-Anzeige (Issue #385)

Chronik-Einträge werden in der UI als gerendertes Markdown angezeigt. Der Edit-Form hat zwei kleine Inputs (`in_game_date`, `label` — bleiben strukturiert für Sortierung + Refs) plus eine große Markdown-Textarea (`markdown_body`).

**Storage:** additives Mnesia-Schema — `chronik_entries` hat seit #385 eine 8. Spalte `markdown_body` (analog zur `source_refs`-Migration aus #114). Alte Einträge haben `nil`, Lazy-Migration beim ersten Edit füllt das Feld. `summary` bleibt als Backward-Compat-Spalte unverändert (wird vom Edit-Save **nicht** überschrieben — Plaintext-Vertrag der Spalte bleibt).

**Rendering:** **seit #604 nur noch EIN Render-Pfad** — `render_md_safe/1` in `HubWeb.CampaignLive.Components` (`apps/hub/lib/hub_web/live/campaign_live/components.ex`, seit #434 dort, nicht mehr im LiveView-Modul). Resümee, Epos **und** Chronik laufen alle darüber.

- `render_md_safe/1`: Defense-in-Depth via Earmark `escape: true` + `HtmlSanitizeEx.basic_html/1`. Erste Schicht neutralisiert literales HTML schon vor dem Sanitizer (`<script>` → `&lt;script&gt;`), zweite Schicht ist die Standard-XSS-Politur (strippt `<iframe>`, `<style>`, `on*`-Handler, `javascript:`-URLs).

Der frühere `render_md/1` (`escape: false`, kein Sanitizer) wurde mit #604 **entfernt**: Resümee + Epos waren GM-editierbar, liefen aber noch über `render_md/1` → Stored-XSS (ein GM konnte `<script>` injizieren, das allen Mitgliedern + reviewenden Admins ausgeliefert wurde). Die unsichere Variante ist bewusst gelöscht, damit sie nicht versehentlich wieder verdrahtet wird (Regressionstest in `render_md_safe_test.exs` asserted ihre Abwesenheit). **Für jeden Markdown-Anzeige-Pfad `render_md_safe/1` nutzen.**

### Stage 1 (ASR) — Whisper-Prompt ist AUS (Issue #1000)

**`whisper_use_prompt` ist per Default `false` — der `--prompt` wird nirgends mehr übergeben.** Grund ist eine A/B-Messung an echtem Session-Audio (2026-08-11): der Prompt kann die Dekodierung einer ganzen Spur in eine **Wiederholungsschleife** kippen, die den echten Inhalt verdrängt — gemessen 63 Zeilen, davon **61× derselbe Satz**, gegenüber 40 Zeilen mit 13 verschiedenen ohne Prompt. Verloren gingen dabei nachweislich echte Spielinhalte (Karten-Beschreibungen, Dialog). Der Effekt ist **audio-abhängig**: auf einer zweiten Spur desselben Mitschnitts trat er nicht auf (dort war der Prompt sogar leicht nützlich — feinere Segmentierung). Aber wenn er eintritt, ist die Spur **still** verloren: es gibt kein Fehlersignal, das Transkript sieht bloß kurz aus.

Damit ist die frühere Annahme widerlegt, der Batch-Pfad sei wegen längerer Segmente unbedenklich (für den Single-Source-Pfad war dasselbe Phänomen schon mit #304 erkannt und der Prompt dort abgeschaltet). Beide Prompt-Quellen hängen jetzt an dem EINEN Schalter — Vokabular (`whisper_initial_prompt` bzw. per-Kampagne `vocab_hint`) UND rollierender Kontext aus `PromptBuilder`. **Die Settings zu leeren reicht nicht**: `PromptBuilder.context_part/1` (letzte 10 Utterances) hängt an keinem Setting.

Wer den Vokabular-Nutzen („Initiative" statt „Demonstrative", „W20" statt „wie 20") bewusst gegen das Schleifen-Risiko abwägen will, setzt `whisper_use_prompt` auf `true` — das ist eine informierte Einzelfall-Entscheidung, kein Default. `opts[:no_prompt]` (Single-Source, #304) bleibt als engerer Schalter davon unabhängig wirksam.

Die Argumentliste baut `Worker.Recording.Transcribe.build_whisper_args/2` — bewusst `def` statt `defp`, damit Tests und Vorher/Nachher-Vergleiche exakt die Produktions-Argumente fahren statt eines Nachbaus.

**Nicht die Ursache** (systematisch ausgeschlossen, nicht vermutet): Flash Attention (in whisper.cpp 1.9.1 neu default-an, liefert bei echter Sprache Wort für Wort identische Zeilen), ROCm/GPU (läuft), `--max-len`/`--split-on-word` (einzeln getestet, unschädlich). **Ehrliche Grenze**: ob der Defekt eine Regression von whisper.cpp 1.8.3 → 1.9.1 ist, lässt sich nicht mehr belegen — das alte Paket (`whisper.cpp-hip`) ist deinstalliert und aus dem AUR verschwunden.

### Stage 1 (ASR) — Per-Token-Confidence (Issues #376/#381)

Whisper-CLI läuft seit #376 mit `-ojf` (Full-JSON) statt `-oj`. Pro Segment wird aus `tokens[].p` ein Confidence-Aggregat im `UtteranceAppended`-Payload publisht. Special-Tokens (ID ≥ 50257 = `[_BEG_]`, `[_TT_*]`, EOT) werden vor der Aggregation rausgefiltert, weil sie p≈1.0 haben und den Mean verzerren würden.

**Aggregat-Felder** (seit #381):

- `mean_p` — arithmetisches Mittel aller Token-p (für Diagnostik).
- `min_p` — niedrigste Token-p im Segment (für Diagnostik). **Vorsicht Längen-Bias**: das Minimum über N Tokens sinkt statistisch mit N, lange Utts haben fast immer ein niedriges min_p auch bei sauberer Transkription. NICHT als Flag-Signal für lange Sätze nutzen.
- `low_token_fraction` — Anteil der Tokens mit `p < threshold`. Längen-normalisiert, primäres Flag-Signal des Hub-UI. Threshold per Worker konfigurierbar via `Worker.Settings.put(:confidence_low_token_threshold, 0.5)` (Default 0.5).
- `token_count` — N (nach Special-Token-Filter). Marker `0` = Platzhalter aus `to_confidence_map/1` (Seed/Probelauf/Manual), Hub-UI skipt diese.

**Eingefrorenes Aggregat:** der `:confidence_low_token_threshold`-Lookup passiert in `aggregate_token_confidence/1` zur **Transkriptionszeit**, das Resultat ist persistiert. Späteres Drehen des Settings wirkt nur auf neue Utterances — alte Aggregate behalten den damaligen Threshold. Für Rück-Effekt: Pipeline neu laufen lassen.

**Zwei-dimensionales Tuning** (Issue #381):

- Per-Token-Schwelle (Worker, Default 0.5): "Was zählt als wackeliges Token"
- Utterance-Fraction-Schwelle (Hub, `@low_token_fraction_threshold = 0.2`): "Wie viele wackelige Tokens braucht es, um zu flaggen"

Interaktion: tieferer Per-Token-Cut → mehr Tokens fallen rein → höhere Fractions → mehr Flags. Höherer Fraction-Cut → strenger flaggen. Beim Tunen beide Knöpfe im Blick haben, ggf. an einem festhalten und am anderen drehen.

**Kurzes-Ende-Caveat (#381):** bei sehr kleinem `token_count` (n<8) ist `low_token_fraction` grob (z.B. N=2 → nur 0/0.5/1.0 möglich) und über-sensitiv für Clip-Rand-Tokens. Hub-Tooltip warnt bei n<8 explizit. Adressierbar später via `n >= N_min`-Guard im Primary-Gate, sobald Real-Data zeigt wie oft das auftritt.

**Wichtig — confidence ist Routing-Signal, kein Rejection-Signal:** der `filter_hallucinations`-Filter ist bewusst NICHT confidence-aware. Whisper-Halluzinationen auf Stille (`"Untertitel von Amara.org"`, Repetition-Loops) werden confident generiert — ein min_p-Drop fängt die nicht. Wo min_p wirklich niedrig ist, sind meist seltene-aber-korrekte Eigennamen oder Code-Switching — also genau die Tokens, die für Stage 3 erhalten bleiben müssen. Ein Drop dort produziert Deletions → WER hoch, nicht runter. Confidence soll später zum **Targeting** dienen (low-fraction-Spans an einen Glossar-/Refinement-Pass weiterreichen statt sie still zu verwerfen).

Seed/Probelauf-Pfade die confidence als Float schreiben werden über `Worker.Recording.Transcribe.to_confidence_map/1` auf das Map-Format normalisiert (`low_token_fraction: 0.0, token_count: 0`), damit später kein `confidence["min_p"]` an einem Float-Altwert crasht. Catch-all loggt + nil bei unbekannten Typen.

### Multi-Source-Goldstandard (Issue #377)

End-to-End-Eval für den Multi-Source-Pfad (AudioBuffer → Transcribe → `UtterancesTranscribed`). Goethe Faust I (Librivox CC0) als Audio-Quelle; bewusste Lücken: literarisches Lese-Register, In-Distribution-Namen → WER als untere Schranke, Entscheidungen am Delta + Bucket-Ranking.

Fixture-Setup (einmalig pro Maschine): `bash apps/worker/test/fixtures/stt/setup.sh` lädt Librivox-MP3s, schneidet Per-Turn-WAVs, baut Per-Sprecher-Multitrack-Spuren in drei Varianten:

- `clean` — Stille (anullsrc) + sequentielle Turns via `adelay`/`apad`, dann `amix=normalize=0` (kein 1/N-Pegel-Confound)
- `realistic` — clean + Inter-Mic-Bleed der anderen Sprecher bei -25 dB + Pink-Noise-Raumton -50 dB lowpass 4 kHz
- `overlap` — wie clean, aber 2 Turns starten früher → echte Simultanrede

Master-Clock-Timeline + Sprecher-Mapping leben in `apps/worker/test/fixtures/stt/faust/sessions/gartenszene.json`. Werte in `setup.sh` müssen synchron bleiben.

**ExUnit-Korrektheits-Smoke** (kein WER-Gate): `mix test --only stt_bench`. Asserts auf Routing (worker-internal smoke), Timeline-Drift < 5 s, Output > 0. WER wird ausgegeben, nicht asserted.

**WER-Regression-Gate**: `mix lore.eval.multisource --session gartenszene --variant clean --max-rel-degradation 0.20` vergleicht aktuellen `global_wer` gegen `apps/worker/test/fixtures/stt/baselines.json`. Exit 1 bei >20% relativer Verschlechterung. Baseline schreiben: `--output-baseline test/fixtures/stt/baselines.json`. Vor jedem Lauf werden `whisper_lang=de`, `whisper_initial_prompt=""`, `whisper_max_len=0` gepinnt (deterministisch in beide Richtungen).

Aggregation: **Micro-Average** (Σ Edits / Σ Referenzwörter, KEIN Macro-Mittel). Bucket-WER via **Backtrace-Attribution** auf der Referenz-Seite — Insertions zwischen ref_i und ref_{i+1} werden ref_{i+1} zugeordnet. Konvention konsistent in `Worker.MultiSourceEval.Wer`.

Routing-Test ist explizit als **Worker-internal Smoke** etikettiert. Hub-side End-to-End-Routing (`Hub.Commands.forward_audio_chunk` → `pick_leader`) ist Folge-Issue. Realistic-Variant misst Cross-Talk-Robustheit als WER-Delta clean→realistic (Content-Kontamination, nicht Routing-Härte).

### Discord-Bot-Voice-Capture (Epic #985, Slice 1)

Alternative zum Browser-Mic-Pfad: ein Discord-Bot (Nostrum + DAVE) tritt einem Voice-Channel bei und speist die Aufnahme in denselben `AudioBuffer.append/5`-Pfad ein (`mic_mode: :per_player`). Machbarkeit bewiesen durch den #941-Spike (Gateway-Join + DAVE-Decrypt + SSRC→User-Mapping funktionieren); die Integration in dieses Repo lief als **eine** durchgängige PR über sechs Stages.

**Kampagnen-Config (Stage A):** GM hinterlegt Guild-ID + Voice-Channel-ID pro Kampagne (`CampaignDiscordConfigSet`, eigene Mnesia-Tabelle `worker_campaign_discord_configs`, Muster `CampaignCalendarSet`). Reader normalisiert `""` UND fehlende Row auf `nil` — „nicht konfiguriert" hat genau EINE Repräsentation. Eigener schmaler Live-Refresh-Scope `campaign_discord_config` (NICHT `campaign_meta` — dessen Snapshot liefert nur die `worker_campaigns`-Row, kein `discord_config`-Key).

**Bot-Token (Stage B):** Deployment-Eigenschaft des Workers (nicht pro Kampagne) — `Worker.Discord.BotToken`, Settings-first/ENV-Fallback wie `Worker.LLM.ApiKey`. Nie im Snapshot durchgereicht, nur der Status.

**Nostrum-Dependency + Boot (Stage C):** `{:nostrum, github: "Kraigie/nostrum"}` (DAVE-Receive-Decrypt existiert nur auf nostrum-main, nicht im letzten Hex-Release) — der reale Pin lebt im committeten `mix.lock`. **Kein `config :nostrum, :token`** (aktiviert Nostrums Alt-Auto-Start-Pfad, kollidiert mit der eigenen Supervision). `{Nostrum.Bot, bot_options}` wird nur als Supervision-Child aufgenommen, wenn beim Boot ein Bot-Token konfiguriert ist (`Worker.Application.discord_bot_child/0`) — Token-Änderung in `/settings` wirkt erst nach Worker-Neustart.

**Prozess-Lifecycle (Stage D):** `Worker.Discord.Registry` + `Worker.Discord.BotSupervisor` (`DynamicSupervisor`) — das ERSTE dynamische Prozess-Pattern in `apps/worker` (alle anderen Recording-Prozesse sind Singleton-GenServer). Per-Kampagne `Worker.Discord.VoiceSession` (`restart: :transient`). Ein abnormaler Exit publisht ein `PipelineErrorLogged` (Stage `"discord_voice"`, sichtbar in `/admin/errors`) — ein Init-Fehler VOR Prozessstart (z.B. Token erst nach dem letzten Boot gesetzt) erreicht diesen Pfad NICHT, landet nur im Log (empirisch verifiziert, `DynamicSupervisor.start_child` fängt das sauber ab). **Seit #987** trägt der Registry-Wert die besitzende Kampagne + den belegten Voice-Channel (`VoiceSession.via/2`/`owner/0`, nicht nur die Guild-ID) — zwei Kampagnen auf derselben Guild konnten sich vorher sonst gegenseitig die Session stehlen/killen (echter Live-Test-Fund: Kampagne B sah „Guild belegt" und tat nichts, `Recorder` merkte sich trotzdem eine `discord_guild_id` für B, ein späterer Stop von B hätte As aktive Session gekillt). Ein Konflikt wird jetzt LAUT (Logger.error + `PipelineErrorLogged`, nennt die belegende Kampagne UND den belegten Channel) statt stillschweigend übernommen; `stop_voice_session/2` terminiert nur die eigene Session. **Ehrliche Grenze bleibt bestehen** (kein Bug, echtes Discord-Protokoll-Limit): Nostrums Voice-API ist selbst guild-skaliert, ein Bot-Account kann pro Guild nur in einem Voice-Channel gleichzeitig sein — zwei Kampagnen auf derselben Guild können nie beide gleichzeitig bedient werden, nur der Konflikt ist jetzt sichtbar statt destruktiv.

**Hook-Punkte + Aufnahme-Modus-Wahl (Stage E, seit #987 kein Auto-Join mehr):** der Discord-Bot-Join passiert NICHT mehr automatisch beim Session-Start, sondern über eine explizite, EINMALIGE Session-Wahl — sobald eine Session offen ist und noch niemand gejoint hat, zeigt der Hub 3 Buttons (🤖 Discord / 🎙 Single / 🎙👥 Multi). Discord schließt Browser-Mikro (Single+Multi) für die GANZE Session und ALLE Teilnehmer aus, und umgekehrt (`SessionCaptureModeSet`-Event, eigene Mnesia-Tabelle `worker_session_capture_modes`, Muster `CampaignDiscordConfigSet` nur session- statt campaign-geschlüsselt; `Worker.Recording.Recorder.choose_capture_mode/3` prüft den aktuellen Zustand VOR dem Publish). Schlägt der Discord-Bot-Join fehl (kein Token/Config/Nostrum.Bot, oder Guild-Konflikt), wird KEIN Modus gesetzt — die Buttons bleiben für einen erneuten Versuch offen, statt den GM ohne funktionierenden Aufnahme-Pfad einzusperren. Best-effort wie zuvor: ein Fehler blockiert nie den Kern-Recording-Start.

**Zeitkorrektur + Audio-Bridging (Stage F):** Discord sendet Pakete pro Sprecher nur während gesprochen wird — naive Konkatenation lässt die Pro-Sprecher-Spuren gegeneinander driften (genau das Problem, das der #941-Spike NICHT gelöst hatte). `Worker.Discord.FrameBuffer` nutzt Ankunftszeit (nicht RTP-Timestamp — der ist pro SSRC nicht sprecherübergreifend vergleichbar) als gemeinsame Referenz. `Worker.Discord.OggOpusMuxer` (eigener, gegen echte ffmpeg-Ogg-Pages CRC-verifizierter Ogg-Opus-Muxer) + `Worker.Discord.AudioBridge` (Decode → Stille auf PCM-Ebene einfügen, NICHT als Opus-Paket-Trick — eine Granule-Lücke im Container wird von ffmpeg nachweislich nicht automatisch mit Stille aufgefüllt → Re-Encode über das bestehende `Worker.MultiSourceEval.AudioBuilder.wav_to_webm_b64/2`, #377) bauen daraus den finalen WebM-Blob. **Seit #987 gegen einen echten Discord-Server PR-getestet, End-to-End erfolgreich** (Bot joint → nimmt auf → verlässt den Kanal → Clip → Whisper-Transkript → Utterance) — dabei fiel ein echter Bug auf: `splice_silence/2`s festes `binary-size(@bytes_per_frame)`-Pattern-Match nahm an, JEDES dekodierte PCM-Segment habe exakt 960 Samples (nur gegen synthetische ffmpeg-Test-Pakete verifiziert) — echte, live dave_decrypt'te Discord-Pakete halten das nicht durchgängig ein und crashten den Clip-Bau. `take_frame/1` nimmt jetzt best-effort was tatsächlich da ist.

**Prozess-Lifecycle-Nachtrag (#987): `trap_exit` fehlte.** `DynamicSupervisor.terminate_child/2` sendet ein reguläres `exit(pid, :shutdown)`-Signal — ein GenServer OHNE `Process.flag(:trap_exit, true)` wird davon HART gekillt, `terminate/2` läuft dann NIE (per `Process.monitor` empirisch verifiziert: der Prozess stirbt mit `reason: :shutdown`, aber kein `terminate/2`-Zweig feuert). Das erklärte, warum der Bot den Voice-Channel nach dem Stop nie verließ, obwohl `terminate/2` bereits korrekt `Voice.leave_channel/1` aufrief — der Code wurde schlicht nie erreicht. Fix: `Process.flag(:trap_exit, true)` in `init/1` (einzige Verlinkung ist der `DynamicSupervisor` selbst, keine Nebenwirkungen auf andere Signale).

**Consent pro Sprecher, Klick statt Stimme (#1005 — löst #1002 ab).** Der erste Live-Lauf von #1002 hat zwei Dinge widerlegt, die dort noch stimmten:

1. **Der Audio-Pfad war kaputt, nicht die ASR.** `FrameBuffer.segment_ssrc/1` rechnete `max(arrival_ms - prev_end, 0)` mit `prev_end = arrival + 20 ms`. Discord sendet alle 20 ms; der gemessene Abstand ist `20 ± Jitter`. Damit wurde **jeder positive Jitter zu eingefügter Stille**, jeder negative auf 0 geklemmt — ein systematischer Bias, der zusammenhängende Rede alle 20 ms zerschnitt. Gemessene Folge: Whisper lieferte Bruchstücke („Das wäre jetzt. auch mit zu. Aufnahme."), `mean_volume -40 dB`, VAD fand keine Sprachsegmente, Session hatte 0 Utterances. Das betraf **jeden** Discord-Mitschnitt. Fix: `gap_silence/1` (pure) — Lücken unter `@min_gap_ms` sind Jitter und erzeugen keine Stille, darüber echte Pausen, quantisiert auf 20-ms-Vielfache. Die Schwelle ist **hergeleitet**: die Abstandsverteilung ist bimodal, weil Discord in Pausen gar keine Pakete sendet (~20 ms innerhalb einer Passage vs. ≥150 ms bei echten Pausen). Der Session-Start-Offset des ersten Frames bleibt ungeschwellt (sprecherübergreifende Ausrichtung, keine Jitter-Frage).
2. **Gesprochene Zustimmung trägt nicht.** Akustik ist **nicht identitätsgebunden**: sagt A den Satz und B hat Lautsprecher statt Kopfhörer, landet A's Stimme in B's Spur — die Erkennung machte daraus B's Einwilligung. Das ist eine *unterstellte* Einwilligung und rein akustisch nicht ausschließbar. Dazu wurde der Satz im Live-Lauf gesagt und nicht erkannt. Deshalb ist der Weg jetzt ein **Discord-Button** (`interaction.user.id` ist von Discord authentifiziert); `ConsentPhrase`/`ConsentCheck` bleiben für einen späteren Sprach-**Auslöser** (Satz → Nachfrage → Klick bestätigt), werden aber derzeit nicht aufgerufen. Die Ansage nennt konsequent nur den Knopf — eine Bitte um etwas, das nichts auslöst, wäre schlimmer als keine.

**Kein Zeitfenster mehr, sondern eine Zeitachse pro Sprecher.** Das globale 45-s-Fenster ist weg (es galt für alle → kurze Sessions endeten leer; und Late-Joiner konnten prinzipiell nie zustimmen). `Worker.Discord.ConsentState` (pure) rechnet auf der **Übergangs-Historie**: die gedeckte Menge ist ein Intervall `[grant, revoke)`, bei Grant→Revoke→Re-Grant eine Intervall-Menge (ein einzelner `since_ms` verlöre das erste Intervall). Der Flush filtert pro Sprecher (`keepable_frames/2`) — **die Einwilligung wirkt nur nach vorn:** wer in Minute 12 zustimmt, dessen Audio aus 0–12 wird verworfen, nicht nachträglich freigegeben. Ein Widerruf schneidet ab seinem Zeitpunkt ab, lässt den gedeckten Teil aber stehen. Grenzsemantik: Grant inklusiv, Widerruf exklusiv. **Eine Uhr, nicht zwei:** der Klick-Zeitstempel ist die lokale monotone Ankunftszeit beim Worker, nicht die Discord-Serverzeit (ein Vergleich über Uhrengrenzen wäre bei Skew genau an der Kante falsch). Der Hot-Path (`handle_cast({:packet, …})`, 50 Casts/s/Sprecher) hat **keine** Zustandsweiche mehr — divergierte sie, landeten Frames eines Zugestimmten im falschen Eimer.

**Identität am Paket, nicht am Flush** (#988 gebaut, #1005 nutzt es): die `ssrc_map` liegt im `VoiceWSState` des Events. Eine Auflösung erst beim Flush war nach einem Voice-Reconnect nicht bloß unvollständig, sondern **falsch** — neue SSRC-Vergabe hätte Audio unter fremder Einwilligung gespeichert. Frames tragen die aufgelöste `did`; ohne Identität werden sie verworfen und gezählt.

**Widerruf (Art. 7 Abs. 3 DSGVO) ist Teil desselben Wurfs**, nicht später: sobald Zustimmung ein Klick ist, muss der Widerruf genauso einfach sein. Event `AudioConsentRevoked`, Tabelle `worker_audio_consent_status` (`discord_id, verdict, version, event_id, ts`) hält **beide** Verdikte. Auflösung per **LWW über `event_id`** — nicht „granted gewinnt" und **nicht terminal**: ein terminales `:granted` machte den Widerruf unrepräsentierbar, und eine alte Zustimmung überlebte je nach Zustellreihenfolge jeden Widerruf (#766-Klasse: Delete↔Wiederkehr). `Worker.Repo.audio_consent_status/1` ist Read-both/Write-new — die neue Tabelle hat Vorrang, `worker_audio_consents` bleibt Legacy-Lesequelle. Daraus folgt eine **bewusste Umkehr der üblichen Degradation**: eine Alt-Zustimmung ohne `event_id` verliert gegen jeden Widerruf (bei Einwilligung ist fail-closed richtig). `ConsentGate.allow?/2,3` ist die einzige Lesestelle. Ein persistierter Widerruf schlägt auch ein frisches Sprach-`:granted`; umgekehrt hebt ein gesprochenes `:declined` eine persistierte Zustimmung **nicht** auf (Akustik darf keine Einwilligung zurücknehmen).

**Der Button wird beim Join in den Voice-Kanal gepostet** (Discord-Text-in-Voice → kein zusätzliches Config-Feld, keine Schema-Erweiterung). `ConsentButton` ist pure: `payload/2`, `custom_id/2`, `parse_custom_id/1`, `verdict_for_click/3`. Die `custom_id` trägt Aktion, Wortlaut-Version **und** Session — Discord-Nachrichten bleiben liegen, ein Klick auf die Nachricht von letzter Woche würde sonst eine Zustimmung für die heutige Aufnahme erzeugen. Der `components`-Block ist eine handgebaute Map: Nostrums Component-Struct serialisiert alle 18 Felder inkl. `null`, und `:components` ist in der `Api.Message.create/2`-Doku nicht gelistet (Passthrough, im Nostrum-Repo ungetestet). `ConsentInteraction` hält die Reihenfolge: Registry-Kontext (kein `GenServer.call` — eine Interaction verfällt nach 3 s und die Session blockiert beim TTS) → pure Prüfung inkl. Kanal → **antworten** → Session informieren → persistieren (im Consumer-Task, nicht im GenServer).

**Ehrliche Grenzen (#1005):** Text-in-Voice ist **nicht verifiziert** — klappt der Post nicht, steht `consent_button_unavailable` in `/admin/errors` und wer noch nicht zugestimmt hat, kann es in dieser Sitzung nicht (Aufnahme läuft für die Gedeckten weiter). Die **namentlichen Ansagen** („X ist beigetreten", Sammelform bei mehreren Ungeklärten, Bestätigung nach Zustimmung) existieren als **pure, getestete Texte** (`Announcement.text_for_join/1`, `text_for_pending/1`, `text_for_granted/1`), sind aber **noch nicht verdrahtet**: der Consumer verwirft das `member`-Objekt des `VOICE_STATE_UPDATE` (dort lägen `nick`/`global_name` ohne HTTP-Call und ohne privilegierten Intent), und `Voice.play/4` liefert bei laufender Wiedergabe `{:error, …}`, was der Code als `:ok` behandelt — mit mehreren Ansagen wäre das ein Silent-Failure-Generator, es braucht also eine Wiedergabe-Queue. Ein Worker-Neustart verliert die Session-Historie (RAM-only); persistierte Zustimmungen sind davon nicht betroffen. Der Widerruf regelt die Zukunft und den ungeflushten Puffer — **bereits geflushtes Material bleibt liegen** (Art. 7 Abs. 3 berührt die bisherige Rechtmäßigkeit nicht); ein Lösch-Pfad ist eigenes Thema.

**Historie (#1002, von #1005 überholt).** #1002 führte die Einwilligung überhaupt ein: gesprochener Satz, ausgewertet in einem globalen 45-Sekunden-**Fenster** nach dem Bot-Join (Vorbild war die Mikro-Setup-Prüfung #400, wo man ein Filmzitat spricht). Beide Bausteine des Ansatzes sind mit #1005 ersetzt — das Fenster durch die Zeitachse pro Sprecher, der Sprechakt durch den Klick —, weil der erste Live-Lauf zeigte, dass das Fenster kurze Sessions leert und Late-Joiner ausschließt und dass akustische Zustimmung nicht identitätsgebunden ist. Die Bausteine der Sprach-Auswertung (`ConsentPhrase.evaluate/1` mit Negations-Veto über Wortstämme, `ConsentCheck`, `Transcribe.transcribe_clip/1`) sind erhalten und getestet, aber nicht verdrahtet; sie sind die Grundlage für einen späteren Sprach-**Auslöser** (Satz → Nachfrage → Klick bestätigt). **Der Fund, der bleibt:** `HubWeb.CampaignLive.Mic.phrase_match?/2` ist ein Bag-of-Words-Match mit 60 %-Schwelle — bei Soll „ich stimme der Aufnahme zu" liefert „ich stimme der Aufnahme **nicht** zu" **100 % Match**. Für einen Mikro-Test ist diese Toleranz richtig, für eine Einwilligung fatal; ein Test baut die tolerante Logik nach und pinnt den Unterschied gegen späteres Zusammenlegen.

**Warum eine EIGENE Match-Logik** (der zentrale Fund): `HubWeb.CampaignLive.Mic.phrase_match?/2` ist ein Bag-of-Words-Match mit 60 %-Schwelle (MapSet, Reihenfolge egal, Zusatzwörter irrelevant) — bei Soll „ich stimme der Aufnahme zu" liefert „ich stimme der Aufnahme **nicht** zu" damit **100 % Match**, eine Ablehnung würde als Zustimmung zählen. Für den Mikro-Test ist die Toleranz richtig, für Einwilligung fatal. `ConsentPhrase` prüft deshalb **erst** ein Negations-Veto (über Wort**stämme**, nicht exakte Wörter — eine exakte Liste ließ prompt „keinesfalls" durch), **dann** den Zustimmungs-Match, und liefert `:granted | :declined | :unclear`. Nur `:granted` erlaubt Speichern; die Übervorsicht ist gewollt (falsches `:granted` = Aufzeichnung gegen den Willen, § 201 StGB; falsches `:unclear` = ein zweiter Versuch). Ein Test baut die tolerante Logik nach und pinnt den Unterschied gegen späteres Zusammenlegen.

**Durchsetzung + Speicher:** `Worker.Discord.ConsentGate.allow?/2` (pure, eigenes Modul — die `VoiceSession` ist ohne echten Nostrum-Bot kaum testbar) entscheidet an genau EINER Stelle in `handle_clip`, ODER-verknüpft aus (1) dem Urteil dieses Fensters — es zählt sofort, weil das `AudioConsentRecorded`-Event den Weg über den Hub noch nicht zurückgelegt hat und eine kurze Session sonst fälschlich verwerfen würde — und (2) dem persistierten Consent (`worker_audio_consents`, gekeyed auf `discord_id`, Max-Version-Lattice #824) — **nur wenn dessen Version zum aktuellen Wortlaut passt** (`ConsentPhrase.version/0`, verglichen über `Materializer.version_rank/1`): ändert sich, worin eingewilligt wird, zählt eine ältere Zustimmung nicht mehr und es wird neu gefragt. Ohne diese Prüfung wäre die Versionierung Dekoration (geschrieben, nie ausgewertet) — ein Test pinnt zusätzlich das `v<n>`-Format, weil `version_rank/1` sonst still 0 liefert und die Prüfung lautlos aushebelt. **Derselbe Speicher wie der Browser-Mikro-Pfad**: wer dort zugestimmt hat, muss im Voice-Kanal nichts sagen, und ab dem zweiten Spielabend wird niemand mehr gefragt. Fehlt die Zustimmung, wird die Spur verworfen und das **sichtbar** gemacht (`/admin/errors`, Stage `discord_consent`, Klasse `consent_missing`) — eine fehlende Spur ist für den GM wichtige Information, kein stiller Verlust. Die Aufnahme der anderen läuft weiter (Alternative wäre, dass eine AFK-Person den Spielabend blockiert).

**Prod-Crash-Loop beim ersten Live-Lauf (Hotfix, Lehre):** `begin_listening/1` schrieb `%{state | consent_timer: ref}`, aber `init/1` legte das Feld nie an — Map-Update-Syntax wirft bei fehlendem Key ein `KeyError`, der GenServer starb, `restart: :transient` startete ihn neu, `init` jointe erneut und spielte die Ansage: **die Ansage lief im Voice-Kanal endlos in Schleife.** Die Tests konnten das nicht fangen, weil sie die pure Logik prüfen und die `VoiceSession` ohne echten Nostrum-Bot nicht startbar ist. Fix: der State-Aufbau ist jetzt die pure Funktion `VoiceSession.initial_state/3`, und ein Test liest den Quelltext, sammelt alle per `%{state | …}` geschriebenen Keys und vergleicht sie gegen die angelegten — er fängt damit auch künftige Felder, nicht nur `consent_timer` (Gegenprobe: ohne den Fix wird er rot und nennt das Feld). **Regel für dynamisch aufgebaute GenServer-States: jedes Feld, das eine Klausel per Map-Update schreibt, MUSS im initialen Aufbau stehen.**
**Live-Präsenz im Hub (#988).** Neben den Aufnahme-Buttons zeigt die CampaignLive die Teilnehmer des Voice-Channels als Avatar-Leiste: **farbig** = Einwilligung liegt vor, die Spur wird gespeichert, und **pulsierend**, solange die Person spricht; **grau + roter Balken** = keine Einwilligung, die Spur wird verworfen. Die Anzeige liest denselben `ConsentGate.allow?/2`-Zustand, nach dem auch `handle_clip` handelt — sie verspricht also keinen Ausschluss, den es nicht gibt. Der Tooltip trägt die Aussage zusätzlich in Worten (Farbe allein ist kein zugängliches Signal).

Zwei Signal-Quellen, beide **öffentliche** Nostrum-API (kein Zugriff auf `connected_clients` o.ä. Interna, die beim nächsten Dependency-Update still brechen): Anwesenheit über das dokumentierte `:VOICE_STATE_UPDATE`-Consumer-Event plus das `voice_states`-Feld der Guild-Struct als Anfangsbestand beim Join (`:VOICE_STATE_UPDATE` kommt nur für Änderungen — ohne den Snapshot bliebe die Leiste leer, bis jemand den Kanal wechselt). Sprechen aus dem Paketstrom: **es gibt kein brauchbares Sprech-Event** — `VOICE_SPEAKING_UPDATE` meldet laut Nostrum-Doku ausschließlich den Bot selbst. Stattdessen sendet Discord pro Sprecher nur *während* gesprochen wird (dieselbe Eigenschaft, auf der die #985-Zeitkorrektur aufbaut), und Nostrums Doku benennt die SSRC→User-Zuordnung ausdrücklich als vorgesehenen Weg dafür. Ein Paket heißt also „spricht jetzt", mit 400 ms Nachlauf gegen Flackern zwischen Silben. **Gedrosselt auf 5 Hz** (`Worker.Discord.Presence.tick_ms/0`): Nostrum beziffert den Strom auf „about 50 events per second per speaking user", ein Broadcast je Paket würde die LiveViews fluten. Die Zustandsberechnung liegt pur in `Worker.Discord.Presence` (ohne Nostrum/GenServer testbar, Muster `ConsentGate`).

**Einwilligung macht zum Mitspieler (#988).** Wer im Voice-Kanal einwilligt und noch kein Mitglied ist, wird als `:spieler` aufgenommen (`Worker.Discord.AutoMember`): `UserUpserted` trägt Name + Avatar ein (von der Discord-API geholt — die Person war womöglich nie im Hub eingeloggt), `AdminMemberAdded` legt die Member-Row an. Beide Folds bewahren `avatar_url`/`joined_at`, die Reihenfolge ist deshalb egal (#879-Klasse). Produktentscheidung: wer im Voice-Channel sitzt, wurde ohnehin auf den Discord-Server eingeladen — will der GM ihn nicht dabeihaben, entfernt er ihn nachträglich, statt jeden Spielabend einen Bestätigungs-Schritt zu blockieren. Damit entfällt im UI ein eigener „Gast"-Zustand. Idempotent (ein Spielleiter wird **nicht** auf `:spieler` zurückgestuft) und best-effort: scheitert der Discord-Profil-Abruf, bleibt die Discord-ID als Anzeigename — ein Mitglied ohne schönen Namen ist besser als ein verlorener Teilnehmer (der Name korrigiert sich beim ersten Hub-Login). `added_by` trägt den Spielleiter; die tatsächliche Herkunft steht im zeitgleichen `AudioConsentRecorded`-Event.

**Historisch (#1002-Grenzen, von #1005 aufgehoben — nicht mehr gültig):** dieser Absatz nannte drei Lücken, die es nicht mehr gibt: „Widerruf wirkt nicht", „Late-Joiner werden nicht gefragt", „wer im Fenster schweigt, verliert seine Spur". #1005 hat alle drei geschlossen (persistierter Widerruf mit LWW-Konvergenz, Klick statt Sprechakt, Fenster ersetzt durch die Zeitachse pro Sprecher — s.o.). Der Absatz stand nach dem #1005-Merge noch da und behauptete das Gegenteil des gebauten Zustands; er ist bewusst als Historie erhalten statt gelöscht, weil er sonst in einer späteren Session als „ungelöst" wieder auftaucht.

**Gesprochene Consent-Ansage beim Join (#989).** Der Bot betrat den Kanal bis dahin lautlos — außer dem GM wusste niemand, dass aufgezeichnet wird (der Browser-Mic-Pfad hat mit `AudioConsentRecorded` ein Äquivalent, der Discord-Pfad hatte keins). Jetzt sagt er beim Beitreten hörbar an: „Der Lorspai hat den Kanal betreten und nimmt die Sitzung für die Kampagne **X** auf." (**„Lorspai" ist kein Tippfehler**, sondern phonetische Schreibweise für die TTS — Live-Fund: „LoreSpy" wurde deutsch als „Schpei" gesprochen, weil `sp-` am Wortanfang im Deutschen zu „schp" wird, in der Wortmitte nicht. Lautschrift wäre sauberer, geht aber nicht: piper interpretiert espeak-`[[…]]`-Phoneme nicht, sondern liest sie vor.) Seit #1002 folgt die Bitte um Einwilligung im selben Atemzug (Wortlaut aus `ConsentPhrase.canonical_phrase/0`, s.o.). **Der Kampagnenname macht die Ansage dynamisch** — deshalb Laufzeit-TTS statt einer vorgenerierten Datei im Repo, und deshalb ist **piper** (lokales neuronales TTS) die dritte externe Binary des Workers neben `whisper-cli`/`ffmpeg` (`piper_bin` + `piper_model` als `:no_default`-Settings, #784-Muster; beide leer = keine Ansage). Erzeugt wird **einmal pro Text**, nicht pro Join (`Worker.Discord.Announcement`, Cache-Key = Hash über den fertigen Ansagetext, Datei unter `<mnesia_dir>/tts/` — dieselbe per-Worker-Ableitung wie `audio_dir` seit #948; Kampagne umbenannt → neuer Hash → neue Datei). **`self_mute` ist jetzt `false`** (vorher `true`, „Bot sendet nie eigene Audio") — ein gemuteter Client kann nicht sprechen; bewusst dauerhaft nicht-gemutet statt nach der Ansage zurückzuschalten (ein zweiter `join_channel/4` auf einer laufenden Verbindung wäre ein Risiko für den als fragil bekannten Empfangspfad). Reihenfolge: join → settle → **Ansage → warten bis fertig → dann `start_listen_async`** (Einwilligung vor Aufzeichnung; die eigene Ansage kann so nicht im Mitschnitt landen), Poll-Kette statt blockierendem Warten, hart gedeckelt (`@announce_max_ms` 30 s — wird die Voice-Verbindung nie bereit oder `playing?` nie false, wird lieber ohne Ansage aufgezeichnet als gar nicht). Der GM kann sie **nicht abschalten** (Consent ist kein Feature-Schalter). Der GM-getippte Kampagnenname geht in einen Subprocess-Aufruf: er wird normalisiert + auf 80 Zeichen gedeckelt, und erreicht piper **über eine Datei auf stdin, nie über die Kommandozeile** (piper nimmt Text nur auf stdin, `System.cmd/3` kann kein stdin füttern → `sh -c '… < textfile'`; Shell-Injection über Kampagnennamen ist im Test mit fünf Angriffs-Varianten + Canary-Datei gepinnt).

**Vier Live-Befunde nach dem ersten echten Spielabend (#1011 + #1009 + #1008 + #1007, eine PR).**

**#1011 — der Kern: die Stop-Reihenfolge war vertauscht.** `Recorder.handle_call({:stop, …})` finalisierte den `AudioBuffer` **vor** dem Stoppen des Bots. Weil der einzige Schreibpfad des Bots `flush_frames/1` aus `VoiceSession.terminate/2` ist, kam Discord-Audio damit **garantiert** nach dem Finalize an (`files=0` → kein Transcribe-Task → keine Pipeline). Dass überhaupt Transkripte entstanden, lag allein am Late-Append-Notpfad #949, der die beendete Session wieder aufmacht — im Prod-Log dreimal in Folge belegt. Ein Notfallnetz als Regelpfad. Fix ist der Tausch der beiden Zeilen: `terminate_child/2` ist synchron, die `append`-Casts der Session liegen bei seiner Rückkehr schon in der AudioBuffer-Mailbox, `finalize` wird erst danach gesendet und landet dahinter (dass `terminate/2` überhaupt läuft, hängt am `trap_exit` aus #987). Ein Quelltext-Wächter pinnt die Reihenfolge (`recorder_stop_order_test.exs`, gegenbewiesen). **Das Stop-Timeout-Budget hängt daran:** `stop_for_campaign/1` ist ein `GenServer.call`, und der Flush läuft synchron darin — solange er läuft, ist der Recorder für JEDEN anderen Call blockiert (ein `start_for_owner/3` einer zweiten Kampagne stünde dahinter und liefe selbst ins Timeout). Die früheren 10 s waren nie mit ffmpeg-Arbeit im Blick gewählt; sie sind jetzt 60 s. Der eigentliche Grund, warum das reicht, ist #1009 (Flush-Menge auf ein Fenster begrenzt statt auf die ganze Sitzung) — bewiesen ausreichend ist es nicht, deshalb **loggt jeder Flush seine Dauer** und warnt ab 5 s (`VoiceErrors.log_flush_duration/3`). Ein Timeout wäre übrigens nicht der Verlust des Mitschnitts: der Recorder arbeitet den Stop vollständig ab, nur die Antwort geht ins Leere — es entstünde ein Crash-Report, der wie ein Datenverlust aussieht, obwohl das Audio heil ist.

**#1009 — die ganze Sitzung lag im RAM eines GenServers.** `state.frames` wuchs bis zum Stop; ein `kill -9`, ein OOM oder ein Stromausfall kostete den kompletten Abend. Jetzt wird periodisch geflusht (`:flush_tick`, `discord_flush_interval_ms`, Default 60 s). Getragen wird das von zwei bestehenden Mechanismen, statt einen Zwischenspeicher zu erfinden: der Clip jedes Fensters trägt einen frischen EBML-Header → `AudioBuffer.write_chunk/6` rotiert auf ein eigenes Segment (#469), und `ChunkManifest` (#757) gibt jedem Segment seinen eigenen Zeitanker. **Die Zeitbasis ist fenster-relativ** (`FrameBuffer.rebase/2`) — und das ist keine Bequemlichkeit: `ChunkManifest.resolve/4` interpoliert **rückwärts** vom Ankunfts-Wall-Clock der Chunk (`wc - slice_ms + frac * slice_ms`), also würde jede über die Fenstergrenze fortgeschriebene Stille `slice_ms` verlängern und den Anker vor den Fensterbeginn ziehen. Ein pro Sprecher „lückenlos weitergeführtes" Ende wäre damit aktiv falsch, nicht bloß unnötig. Der Fensterschnitt ist pure (`FrameBuffer.split_window/2`, Grenze exklusiv, damit ein Frame auf der Kante in genau einem Fenster landet). **Ehrliche Grenze:** der Anker eines Segments ist das Fenster-**Ende**; ein Sprecher, der früh im Fenster verstummt, hat einen kürzeren Clip als das Fenster und wird um die Differenz zu spät einsortiert. Der Fehler ist damit auf eine Fensterlänge begrenzt — vorher auf die Sitzungslänge (wer eine Stunde vor Schluss verstummte, lag eine Stunde daneben). Ganz weg wäre er nur mit einem Wall-Clock-Argument an `AudioBuffer.append/5`; das ist ein eigener Schnitt. Nebenwirkung: die #469-Rotationswarnung erscheint jetzt einmal pro Fenster und Sprecher (kosmetisch, aber Log-Rauschen).

**#1008 — „Aufnahme lief, kein Transkript" war ein stiller Totalverlust.** Ursache dieses Vorfalls war #1011; das Symptom-Ticket ist damit erledigt, aber „behoben" ist keine Zusicherung, dass der als fragil bekannte Empfangspfad nie auf andere Weise nichts liefert. Deshalb wird der Ausgang jeder Aufnahme jetzt aktiv bewertet, statt auf den nächsten Zufallsfund zu warten — drei vorher nur geloggte Ausfälle sind jetzt Fehlerklassen in `/admin/errors` (Stage `discord_voice`): `no_frames_captured` (kein einziges Paket empfangen — typisch serverseitig stummgeschalteter Bot), `unresolved_ssrc_frames` (Audio kam an, aber kein Paket war zuordenbar — typisch nach Voice-Reconnect) und `clip_build_failed` (ffmpeg/Decode). Bewusst nur **eindeutige** Totalausfälle: der Teilausfall bleibt eine Log-Warnung, weil einzelne unauflösbare Frames normal sind (~200 ms zu Sprechbeginn) und jede Schwelle darüber erfunden wäre. Die Klassifikation ist pure (`VoiceSession.capture_outcome/2`). Nachgezogen: die Discord-Fehlerklassen hatten in `/admin/errors` **nie** ein `type_label` und standen als roher Code in der Liste.

**#1007 — die Avatar-Leiste blieb nach dem Stop stehen.** Die Präsenz-Liste ist ephemer und wird nur *gesetzt*, solange der Worker sendet; nach dem Stop hörte er auf und der letzte Stand blieb im Assign — die Leiste behauptete weiter „diese Leute sitzen im Kanal und werden aufgezeichnet". Das Gate hängt jetzt an der aktiven Session und sitzt in der Komponente selbst, nicht im Aufrufer (robuster als das Leeren des Assigns: es gilt auch für einen frisch gemounteten Betrachter, bei verlorener Abschlussmeldung, und es verhindert das Aufblitzen der alten Avatare beim Start der nächsten Session). In der **Pause** bleibt die Leiste sichtbar — der Bot bleibt im Kanal.

**Ehrliche Grenzen:** kein aktiver Liveness-Check (nur Prozess-Crashes werden erkannt); eine Discord-Gateway-Session kann pro Guild nur einem Voice-Channel gleichzeitig beitreten (s.o., seit #987 laut statt destruktiv); `VoiceSession` ist RAM-only (Worker-Neustart verliert die Session ohne Re-Attach — seit #1009 ist der Audio-Verlust dabei auf ein Flush-Fenster begrenzt, die Session selbst wird weiterhin nicht wieder angeheftet). **Zur Ansage (#989):** scheitert sie (piper nicht eingerichtet, Binary/Modell kaputt), läuft die **Aufnahme weiter** und der Fehler ist sichtbar (`/admin/errors`, Klassen `tts_failed`/`announce_play_failed`/`piper_not_configured`, Stage `discord_ansage`) — dann zeichnet der Bot aber **ohne hörbares Signal** auf, das Consent-Ziel ist in diesem Fall verfehlt, nur eben sichtbar statt lautlos (bewusste Abwägung: Aufnahme am Spielabend abzubrechen, weil TTS fehlt, wäre schlechter). Für deutsche weibliche Stimmen gibt es bei piper nur `low`-Qualität (kein `medium`).

## Demo-Daten seeden (Romeo & Julia)

Reproduzierbare 5-Akt-Test-Kampagne — committed in `apps/hub/priv/seeds/romeo/*.jsonl`. Lädt eine voll-bestückte Kampagne ("Romeo & Julia", GM "Erzähler" + 6 Spieler) inkl. pre-generated Resümees / Epos / Chronik in einen frischen lokalen Hub.

```bash
# Hub + Worker müssen vorher laufen (Worker für Materializer-Apply!):
cd apps/hub && mix phx.server
cd apps/worker && LORE_MNESIA_DIR=… elixir --sname worker --no-halt -S mix run

# Dann seeden:
mix lore.seed.romeo                            # gegen http://127.0.0.1:4000
mix lore.seed.romeo --hub http://127.0.0.1:4001 # gegen PR-Test-Hub
mix lore.seed.romeo --reset                    # erst CampaignDeleted, dann re-seed

# Caller als Owner+Admin (Issue #78) — sonst sieht der eigene Account die
# Demo-Kampagne nicht im Dashboard, weil per default ein Dummy-Erzähler
# Owner ist:
mix lore.seed.romeo --as-admin <discord-id> --display-name "<name>"
mix lore.seed.romeo --as-admin <discord-id> --mode protocol-only  # Resümee/Epos/Chronik leer (für LLM-Lasttests)
```

Refuses `MIX_ENV=prod`. Berührt nur die Kampagne `romeo-julia-demo` — kollidiert nicht mit echten Daten. Use Cases: Klick-Demos, LLM-Lasttests (vgl. #69 + `--mode protocol-only`), Onboarding einer fremden Claude-Code-Instanz (mit `--as-admin <eigene-discord-id>` ist der Caller sofort Owner+Admin der Romeo-Demo).

## Demo-Daten seeden (Die drei Musketiere — D&D, Issue #423)

Reproduzierbare D&D-Tisch-Kampagne, lose nach Alexandre Dumas, „Les trois mousquetaires" (1844, gemeinfrei seit 1940). 4 Sessions à 25-40k Wörter (≈ 100k Wörter total). **Nur Protokoll** — keine Resümees/Epos/Chronik in den Seeds, damit das LLM die als Stage 2-4 generiert (LLM-Eval-Fokus).

PCs: D'Artagnan (Rogue/Swashbuckler), Athos (Fighter/Champion), Porthos (Barbarian/Berserker), Aramis (Cleric/War). Alle NPCs (Tréville, Königin Anne, Cardinal Richelieu, Milady de Winter, Rochefort, Constance Bonacieux, Buckingham, Lord de Winter, Henker von Lille etc.) werden vom SL gespielt. Discord-IDs reserviert im `20000000000000000`-Range (Romeo nutzt `10000000000000000`, also kollisionsfrei).

```bash
mix lore.seed.musketiere                              # gegen http://127.0.0.1:4000
mix lore.seed.musketiere --hub http://127.0.0.1:4005  # PR-Test-Hub
mix lore.seed.musketiere --reset                      # erst CampaignDeleted, dann re-seed
mix lore.seed.musketiere --as-admin <discord-id>      # Caller als Owner+Admin
```

Refuses `MIX_ENV=prod`. Berührt nur `drei-musketiere-demo`. JSONL-Files unter `apps/hub/priv/seeds/musketiere/`, regeneriert via `elixir apps/hub/priv/seeds/musketiere/generator.exs` (deterministisch — fester `:rand`-Seed pro Session).

Use Cases primär: LLM-Stage-2/3/4-Eval (anderes Genre als Romeo — Mantel-und-Degen-Banter + OOC-Wechsel + Würfelproben statt Schlegel-Verse), Pipeline-Lasttest mit langen Sessions. Die Quelle (Dumas 1844) ist analog zur Schlegel-Übersetzung (1797) firmly Public Domain — Plot-Beats und Charakter-Namen aus dem Roman, Dialoge eigenständige deutsche D&D-Tisch-Kompositionen.

PCs: Edgin (Bard), Holga (Barbarin), Simon (Sorcerer), Doric (Druidin), Xenk (Paladin), Kira (Rogue, ab S3). Discord-IDs reserviert im `20000000000000000`-Range (Romeo nutzt `10000000000000000`, also kollisionsfrei).

```bash
mix lore.seed.ehre                              # gegen http://127.0.0.1:4000
mix lore.seed.ehre --hub http://127.0.0.1:4005  # PR-Test-Hub
mix lore.seed.ehre --reset                      # erst CampaignDeleted, dann re-seed
mix lore.seed.ehre --as-admin <discord-id>      # Caller als Owner+Admin
```

Refuses `MIX_ENV=prod`. Berührt nur `ehre-unter-dieben-demo`. JSONL-Files unter `apps/hub/priv/seeds/ehre/`, regeneriert via `elixir apps/hub/priv/seeds/ehre/generator.exs` (deterministisch — fester `:rand`-Seed pro Session).

Use Cases primär: LLM-Stage-2/3/4-Eval (anderes Genre als Romeo — D&D-Tisch-Banter + OOC-Wechsel + Würfelproben statt Schlegel-Verse), Pipeline-Lasttest mit langen Sessions, Tabula-Wiederbelebung als Plot-Strang den die Chronik konsistent abbilden muss.

## Demo-Daten seeden (Vox Machina — Critical Role, Issue #106)

Reproduzierbare D&D-Tisch-Kampagne, frei nach Critical Role Campaign 1 (Kraghammer-Bogen). 3 Sessions (Ep 1 Arrival at Kraghammer, Ep 2 Into the Mines, Ep 3 The Corruption Below). Campaign-ID `vox-machina-demo`, 7 Dummy-Spieler (Travis/Laura/Marisha/Taliesin/Liam/Ashley/Sam) + DM-Zeilen unter der `--as-admin`-Discord-ID.

```bash
mix lore.seed.vox_machina                             # gegen http://127.0.0.1:4000
mix lore.seed.vox_machina --hub http://127.0.0.1:4001 # PR-Test-Hub
mix lore.seed.vox_machina --reset                     # erst CampaignDeleted, dann re-seed
mix lore.seed.vox_machina --mode protocol-only        # ohne LLM-Output-Events (für Pipeline-Lasttests)
mix lore.seed.vox_machina --as-admin <discord-id> --display-name "<name>"
```

Refuses `MIX_ENV=prod` (Prod-Pfad: `scripts/seed_vox_machina_prod.exs` via RPC-Bridge, analog zum Romeo-Prod-Import). Berührt nur `vox-machina-demo`. JSONL-Files unter `apps/hub/priv/seeds/vox-machina/` (statisch committed, kein Generator-Script wie bei Musketiere/Ehre).

## Fidelity-Testset seeden (Ein Skandal in Böhmen — CoC/Gaslight, Issue #644)

**Treue-Testset, kein Klick-Demo.** Arthur Conan Doyle, „A Scandal in Bohemia" (1891, gemeinfrei), gespielt als Call-of-Cthulhu / BRP / Gaslight (mythos-frei, viktorianisches London 1888). Das Buch wird **abgebildet, nicht dazugedichtet** — Würfelausgänge an den Buch-Plot gekoppelt. Cast = Quell-Cast: Holmes + Watson (PCs), ein SL spricht alle NPCs (König von Böhmen / Wilhelm von Ormstein, Irene Adler, Godfrey Norton, Kutscher).

```bash
mix lore.seed.skandal                              # gegen http://127.0.0.1:4000
mix lore.seed.skandal --hub http://localhost:4001  # Teststage-Hub
mix lore.seed.skandal --reset                      # erst CampaignDeleted, dann re-seed
mix lore.seed.skandal --as-admin <discord-id>      # Caller als Owner+Admin
```

Refuses `MIX_ENV=prod`. Berührt nur `skandal-boehmen-demo`. JSONL-Files + Generator + Ground-Truth (`reference-summary.md`, `fact-key.json`) unter `apps/hub/priv/seeds/skandal-boehmen/`, regeneriert via `elixir apps/hub/priv/seeds/skandal-boehmen/generator.exs`.

Zweck: **reproduzierbares Stage-2-Treue-Testset** mit bekannter Referenz. Testet zugleich (1) Regel-Noise-Filterung — die Proben (BRP-Skill-Checks) sind **diegetisch** an den Handlungspunkten platziert, nicht zufällig gestreut, und ein treues Resümee muss sie wegfiltern; (2) **Figur-aus-Kontext-Attribution** — der eine SL-Sprecher spricht alle NPCs, die Figur lebt nur im Text (kein Figur-Feld pro Utterance), das Resümee muss „der König sagt X / Irene sagt Y" korrekt zuordnen; (3) Faktentreue gegen `fact-key.json` (required_facts / attribution_facts / decoys / rule_noise_markers). Umfang bewusst **buchtreu statt 4-h-aufgebläht** (Doyle-Vorlage ~8,5k Wörter).

### Treue-Scoring: `mix lore.eval.summary` (Issue #647)

Automatisiertes Treue-Scoring der Wahrheitsbild-Pipeline gegen den Fact-Key (seit #786 Wahrheitsbild-only — das `--mode`-Flag und der Chain-Treiber sind mit der Chain entfernt). Materialisiert das Fixture (JSONL unter `apps/hub/priv/seeds/<campaign>/`) in eine **frische Worker-Mnesia** (eigener Bootstrap, kein laufender Worker nötig), treibt die **echten** Pipeline-Bausteine pro Session (`extract_facts → Verify.verify_session → Render.render_summary` + `render_epos`, inkl. Extraktions-Map-Reduce #683 — kein Audio, kein Hub-Roundtrip) und scort den Output. Weil die echten Pipeline-Prompts getrieben werden, **bewegt sich der Score, sobald Extraktions-Prompt/Judge/Render verbessert wird** — der Measure-First-Loop (#557).

```bash
mix lore.eval.summary                          # default: skandal-boehmen, Gate gegen baselines.json
mix lore.eval.summary --model qwen2.5:7b       # explizites Extraktor-/Render-Modell
mix lore.eval.summary --judge                  # + LLM-Judge (fact_recall/fabrication/attribution)
mix lore.eval.summary --samples 3              # 3 Durchläufe → Median (LLM-Rauschen), #656
mix lore.eval.summary --output-baseline apps/worker/test/fixtures/summary_eval/baselines.json
```

- **Baseline-Label (Historie #685/#786):** der Report-/Baseline-Name trägt weiterhin das Suffix `(wahrheitsbild)` (`qwen2.5:7b (wahrheitsbild)` in `baselines.json`) — bestehende Wahrheitsbild-Baselines bleiben gültig, alte Chain-Baselines (ohne Suffix, aus der A/B-Phase #685) können nie fälschlich gaten. Zusätzlich zum Resümee wird das Epos-Kapitel (Ep_n, #752) mit denselben Metriken gescort (nicht gegated).
- **Lexikalisch:** `entity_recall` (Anteil Pflicht-Entities im Resümee), `noise_leak` (durchgesickerte Würfel-/OOC-/Proben-Strings, Soll 0). **Wichtig:** die Scoring-Funktion ist deterministisch, der LLM-Output (Resümee) und damit der Wert variiert run-to-run — deshalb mittelt `--samples N` (#656) über N Läufe und meldet den **Median** (+ min–max-Spanne). Harter Gate (exit 1) auf den `entity_recall`-Median (Toleranz `--max-rel-degradation`, default 0.20). `noise_leak` ist binär pro Marker: bei `--samples ≥ 3` wird der Median hart gegatet (robust), darunter nur gemeldet + Warnung. Baseline am besten mit `--samples 3+` schreiben (stabiler Median).
- **Judge-Pass (`--judge`, NICHT gegatet):** ein LLM-Grader für `fact_recall`/`fabrication`/`attribution_accuracy` — nicht-deterministisch, nur Diagnostik/Trend (#557-Disziplin: nicht-deterministische Zahlen röten keinen Merge). **Bekannt:** die Attributions-Teilmetrik ist noch unterkalibriert (liefert oft 0 % trotz korrekter Zuordnung) — Judge-Prompt-Tuning ist Folge-Arbeit.
- `baselines.json` (unter `apps/worker/test/fixtures/summary_eval/`) ist **nicht eingecheckt** (modell-/maschinen-/run-spezifisch) — per `--output-baseline` lokal erzeugen; ohne Baseline reportet der Eval nur (kein Gate). Refuses `MIX_ENV=prod`. Voraussetzung: Ollama läuft + Stage-2-Modell gepullt.

### Handlungsbogen-Treue-Eval: `mix lore.eval.threads` (Issue #830/#837, Epic #829 Slices A+E)

Das Gegenstück zu `mix lore.eval.summary`, nur für die **Erzählstruktur** statt der Resümee-Faktentreue. Misst, wie gut die Extraktion Fakten campaign-weit **Handlungsbögen** zuordnet, gegen die neuen `threads`/`must_not_merge_threads`/`must_not_resolve`-Blöcke im `fact-key.json` (bislang nur `skandal-boehmen`, 3 Doyle-Stränge). Materialisiert das Fixture in eine frische Worker-Mnesia (`EvalBootstrap`), treibt die **echte** Extraktion (`Stages.extract_facts`) pro Session, gruppiert die produzierten Fakten nach ihrem rohen `thread`-Label (`Worker.ThreadEval`) und scort:

```bash
mix lore.eval.threads                            # default: skandal-boehmen, Gate gegen baselines.json
mix lore.eval.threads --model qwen2.5:7b         # explizites Extraktor-Modell
mix lore.eval.threads --samples 3                # 3 Läufe → Median (LLM-Rauschen, #656-Muster)
mix lore.eval.threads --verbose                  # + roh-Label-Häufigkeiten
mix lore.eval.threads --reset                    # Campaign vorher löschen
mix lore.eval.threads --chunk-tokens 2200 --ctx 8192   # Extraktions-Knöpfe sweepen
mix lore.eval.threads --output-baseline apps/worker/test/fixtures/thread_eval/baselines.json
```

- **Modell-Kapazität (real gemessen, #831):** `qwen2.5:7b` labelt Stränge **unbrauchbar** — Total-Abstinenz oder Parroting eines Few-Shot-Beispiel-Labels auf alle Fakten. Ein fähigeres Modell (`qwen3:30b-a3b-instruct`) leitet **7 echte, inhaltsabgeleitete Doyle-Stränge** ab (100% thread_recall). Thread-Labeling will einen ≥30b-Extraktor; das laufzeit-ungegatete Feld schadet auf 7b nicht (Fehlgruppierung ≠ Fabrikation), liefert dort aber schwache Labels — Slice C (Clustering) + Modellwahl heben die Qualität. **Verbose-Extraktor-Caveat:** große Modelle überlaufen bei ~100+ Utts/Chunk die `ctx_stage2`-Decke → `:parse_failed` (das #763-Phänomen, von der Halbierung aufgefangen); `--chunk-tokens 2200` (kleinere Chunks) heilt das (404 statt 140 Fakten). Der Default-7b-Pfad ist davon nicht betroffen.

- **Metriken (deterministisch lexikalisch):** `thread_recall` (Anteil Soll-Stränge mit ≥1 passendem produzierten Strang), `fragmentation` (distinkte Labels je Soll-Strang, Soll 1.0 — das Label-Konsistenz-Signal fürs Prompt-Tuning), `false_merge` (ein Strang matcht beide Glieder eines `must_not_merge`-Paars), `false_resolve` (der Gegenpart eines `must_not_resolve`-Strangs trägt ein `fact_type=="auflösung"`-Flag). Matching ist **label-primär, unterscheidende-Entität-sekundär** (ubiquitäre Kern-Figuren matchen sonst jeden Strang mit jedem).
- **Gate (Slice E, #837 — analog `eval.summary`):** harter Gate (exit 1) auf den `thread_recall`-**Median** gegen `baselines.json` (relativ-tolerant, `--max-rel-degradation` Default 0.20); `false_merge`/`false_resolve` (Soll 0, binär pro Paar/Strang → einzeln flaky) werden bei `--samples ≥ 3` hart gegated, darunter nur gewarnt (#656-Muster). `fragmentation` wird gemeldet, **nicht** gegated (das Registry-Clustering #832 heilt Fragmentierung produktiv). `false_resolve` gatet auf sauberer Arc-Semantik (#885: Soll-Stränge des Fact-Keys sind Arcs; für Contexte ist die Metrik undefiniert). `baselines.json` (unter `apps/worker/test/fixtures/thread_eval/`) ist **nicht eingecheckt** — per `--output-baseline` lokal erzeugen (am besten `--samples 3+`); ohne Baseline nur Report, kein Gate. Gemessen werden weiterhin die **Roh-Extraktions-Labels** (Measure-First-Anker #557). Ehrliche Grenze: das Gate schützt vor Regression gegen das Doyle-Fixture, nicht vor der schwächeren Label-Realität auf echtem Tisch-Deutsch (Free-Seattle-Befund: viele leere Labels).
- **Ehrliche Grenzen:** (1) Seit **Slice B (#831)** emittiert die Extraktion `fact_type` + `thread` pro Fakt (`normalize_fact/4`, GBNF-Schema, beide required) → die Task liefert echte Zahlen. Der produktive Reader (Slice D1) fehlt noch → gescort werden die **Roh-Labels** (das Fragmentierungs-Signal fürs Prompt-Tuning; das Slice-C-Clustering läuft in der Pipeline, wird hier aber noch nicht angewendet). (2) `false_merge` ist deterministisch nur **label-/entity-sichtbar**; ein subtiler Ein-Label-Merge eines entity-untrennbaren Paars (Erpressung ↔ Gegenspiel im Skandal-Set) braucht eine semantische Fakt-Zuordnung (Judge, spätere Arbeit). Refuses `MIX_ENV=prod`. Voraussetzung: Ollama läuft + Stage-2-Modell gepullt.
