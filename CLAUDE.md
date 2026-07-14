# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Language

Tom (the maintainer) is most fluent in German — sorry about that. The rest of this file, plus most CLAUDE.local.md notes, commit messages, issue bodies and PR descriptions, are written in German for that reason. If you're reading this in a non-German context (external contributor, public repo audit, English-only review), please use a translation tool — Claude Code can also translate on request.

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
- **Issue-Audit-Snapshot**: `docs/issue-audit-2026-07-09.md` — letzter Relevanz-Snapshot (Milestone-Fit / Gültigkeit / Reihenfolge über alle offenen Issues, Stichtag: nach dem Wahrheitsbild-Default-Flip; löst `docs/issue-audit-2026-06-01.md` ab). Bei der nächsten Refinement-Runde aktualisieren oder durch ein neueres Stichtag-Doc ersetzen, damit die Liste nicht stale wird.

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
   - **Version bumpen** in `apps/<app>/mix.exs` wenn die Änderung App-Verhalten / Wire-Protocol / Schema berührt. Pre-1.0: Minor (`0.3.0`) bei Feature / rückwärtskompat. Wire-Erweiterung, Patch (`0.2.1`) bei Bugfix / Polish ohne Verhaltens-Änderung. **`shared`-Bump erzwingt `hub` + `worker` mit-bumpen** (Wire/Schema-Sync). Reine Doc-/Doku-/Tooling-PRs brauchen keinen Bump. Nach Merge auf master: Tags `hub-v<N>` / `worker-v<N>` / `shared-v<N>` lokal setzen + pushen (`git tag … && git push origin --tags` — Token-Trick siehe `CLAUDE.local.md`).
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

`Worker.Recording.Pipeline.run_for_session/1` (bzw. der `UtterancesTranscribed`-Trigger) fährt pro Session den Wahrheitsbild-Pfad — die frühere Chain (Stage 2→3→4 Prosa-Kette) und das `pipeline_mode`-Setting sind mit #786 **komplett entfernt** (kein Fallback; die Chain fabrizierte auf echtem Tisch-Deutsch nahezu vollständig):

- **Extraktion** (`extract_facts`, Status `"extract"`) — Original-Utterances → strukturierte Fakten; Map-Reduce für lange Sessions (#683) + Halbierungs-Retry degenerierter Chunks (#763). Der EINE Generativschritt. **Seit #831 (Epic #829 Slice B)** trägt jeder Fakt zwei Handlungsbogen-Felder: `fact_type` (Enum `ereignis|zustandsänderung|beziehung|absicht|enthüllung|auflösung`, Default `ereignis`) + `thread` (Kurzlabel des Erzählstrangs, Leerstring = keiner). Beide `required` im GBNF-Schema (#676-Lektion), rekonstruiert in `normalize_fact/4` (die EINE Stelle mit fixer Feldliste — die Republish-Pfade sind feldkonservativ). Laufzeit-**ungegated** (das Verify-Gate prüft `claim`/Attribution, nicht Labels), offline eval-gegated via `mix lore.eval.threads`.
- **Entity-Registry** (best-effort, kein Status) — campaign-weites Guise-Merging (`EntityRegistry.resolve_campaign_entities`, #714; Cluster-Fehler lässt die Fakten unverändert).
- **Verify-Gate** (`Verify.verify_session`, Status `"verify"`) — Quell-Grounding + Attribution auf kanonischen Entitäten, Flag-statt-Drop (`verified? = grounded? AND attributed?`).
- **Geschwister-Render** (Status `"render"`/`"timeline"`/`"render_epos"`) — Resümee/Timeline/**Epos-KAPITEL pro Session** aus den **verifizierten** Fakten, mit Render-Gating; #752: Kapitel strikt isoliert aus E_n, deterministischer Kapitel-Kopf aus der Timeline-Tag-Range, Datenmodell entry_id=session_id/parent_id=campaign_id, Legacy-Buch („Alt-Epos") koexistiert in der UI. Timeline+Epos sind fehler-entkoppelte best-effort-Geschwister.

Jeder Schritt läuft in `with_status` → eigene Fehlerklassen in `/admin/errors` (#716). **Seit #783 Phase 2 (+ Nachtrag) hat jeder LLM-Schritt sein eigenes Backend + Modell**: `backend_stage2`/`model_stage2_<backend>` (Extraktion), `backend_stage3`/`model_stage3_<backend>` (Verify — Grounding + Attribution), `backend_stage4`/`model_stage4_<backend>` (Render-Resümee), `backend_stage5`/`model_stage5_<backend>` (Render-Epos-Kapitel — Nachtrag, war anfangs Teil von Stage 4). Damit kann der Verify-Judge gezielt stärker sein als der Extraktor ("fox guarding henhouse"-Vermeidung, der #783-Ursprungs-Usecase), Resümee und Epos können unterschiedliche Modelle nutzen (kurz/faktentreu vs. länger/literarisch), und Kosten lassen sich gezielt verteilen (Extraktion billig/lokal, Verify/Render ggf. Cloud). Die früheren Phase-1-Overrides `judge_model`/`render_model` (gleiches Backend, nur anderes Modell) sind mit der vollen Trennung entfernt. **Provenance-Stempel:** `SessionFactsExtracted` trägt `verify_backend`/`verify_model`, `SessionSummaryGenerated` trägt `render_backend`/`render_model`, `EposEntryEdited` trägt `epos_backend`/`epos_model` (additiv, reine Persistenz — macht einen Backend-Wechsel zwischen zwei Sessions sichtbar, ist aber kein Pin-Mechanismus; der bleibt Phase 4 der Multi-Worker-Architektur-Arbeit). **Migration für Bestandsworker:** `Worker.Application.migrate_stage2_to_stage34_if_unset!/0` kopiert beim ersten Boot nach dem Update Stage 2s Werte einmalig nach Stage 3/4, `migrate_stage4_to_stage5_if_unset!/0` (Nachtrag) analog Stage 4 nach Stage 5 (beide idempotent, gated auf einem rohen `backend_stage{3,5}`-Store-Read) — ohne das würde ein Bestandsworker mit `:no_model_configured` brechen. **Stil-Flavors (#787):** die Campaign-Flavors (`base` + `summary`/`epos`) wirken in den **Render-Prompts** (hinter dem Verify-Gate — Stil kann keine Fakten einschleusen, das Render-Gating fängt Dazudichtung); die Extraktion ist stilfrei, die Timeline deterministisch (kein Ton-Slot). Der Stil-Editor in der CampaignLive hat Tabs Resümee/Epos/Chronik mit Live-Prompt-Vorschau für die zwei Render-Slots (`preview_prompt/2`, byte-genau dieselben Builder wie die Pipeline). Die Überschrift (`vorgaben[stage].name`) setzt bei allen drei den **Spaltentitel**; nur beim Resümee wirkt sie zusätzlich als Textsorte-Direktive im Prompt (Epos-Kapitel-Köpfe sind deterministisch #752, die Timeline hat keinen Prompt). Historie: Default-Flip auf Wahrheitsbild 2026-07-08 nach dem Free-Seattle-Real-Lauf; Retention: historische Chain-Events/-Artefakte bleiben lesbar (Materializer-Folds + Event-Schemas unangetastet, nur die Producer sind weg).

**Zeitstrahl / Datums-Auflösung (#724).** Der Timeline-Publish ist verdrahtet: `run_wahrheitsbild` datiert die verifizierten Fakten deterministisch und schreibt sie als Chronik-Einträge (`publish_wahrheitsbild_timeline` → `Timeline.Graph.resolve` → `Render.timeline` → `ChronikEntryChanged`). Kernprinzip: das LLM liefert pro Fakt **Anker + Offset + Präzision + narration_time** (Erzählzeit vs. erzählte Zeit — Flashback/Prophezeiung), **Elixir rechnet das Datum** deterministisch auf einem Tageszähler (`Worker.Timeline.{Calendar,Resolver,Graph}`) — so landet eine erzählte Rückblende chronologisch in der Vergangenheit statt zur Aufnahmezeit. Persistenz: eigene Tabellen `@campaign_calendars` (per-Campaign-Kalender, Default Gregorian) + `@session_anchors` (In-Game-Datum-Anker pro Session), gesetzt via Events `CampaignCalendarSet` / `SessionInGameAnchorSet`; `chronik_entries` trägt `in_game_day` (Sort-Schlüssel) + `precision`. UI: pro Session ein 📅-Datumsfeld, ein „Kalender"-Config-Tab, und ein `~`-Präzisions-Marker in der Chronik. Ehrliche Grenze (#686): `narration_time` (required) ist das verlässliche Signal; relative Offsets sind modell-abhängig (Eval-Frage).

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

### Handlungsbogen-Treue-Eval: `mix lore.eval.threads` (Issue #830, Epic #829 Slice A)

Das Gegenstück zu `mix lore.eval.summary`, nur für die **Erzählstruktur** statt der Resümee-Faktentreue. Misst, wie gut die Extraktion Fakten campaign-weit **Handlungsbögen** zuordnet, gegen die neuen `threads`/`must_not_merge_threads`/`must_not_resolve`-Blöcke im `fact-key.json` (bislang nur `skandal-boehmen`, 3 Doyle-Stränge). Materialisiert das Fixture in eine frische Worker-Mnesia (`EvalBootstrap`), treibt die **echte** Extraktion (`Stages.extract_facts`) pro Session, gruppiert die produzierten Fakten nach ihrem rohen `thread`-Label (`Worker.ThreadEval`) und scort:

```bash
mix lore.eval.threads                            # default: skandal-boehmen
mix lore.eval.threads --model qwen2.5:7b         # explizites Extraktor-Modell
mix lore.eval.threads --verbose                  # + roh-Label-Häufigkeiten
mix lore.eval.threads --reset                    # Campaign vorher löschen
mix lore.eval.threads --chunk-tokens 2200 --ctx 8192   # Extraktions-Knöpfe sweepen
```

- **Modell-Kapazität (real gemessen, #831):** `qwen2.5:7b` labelt Stränge **unbrauchbar** — Total-Abstinenz oder Parroting eines Few-Shot-Beispiel-Labels auf alle Fakten. Ein fähigeres Modell (`qwen3:30b-a3b-instruct`) leitet **7 echte, inhaltsabgeleitete Doyle-Stränge** ab (100% thread_recall). Thread-Labeling will einen ≥30b-Extraktor; das laufzeit-ungegatete Feld schadet auf 7b nicht (Fehlgruppierung ≠ Fabrikation), liefert dort aber schwache Labels — Slice C (Clustering) + Modellwahl heben die Qualität. **Verbose-Extraktor-Caveat:** große Modelle überlaufen bei ~100+ Utts/Chunk die `ctx_stage2`-Decke → `:parse_failed` (das #763-Phänomen, von der Halbierung aufgefangen); `--chunk-tokens 2200` (kleinere Chunks) heilt das (404 statt 140 Fakten). Der Default-7b-Pfad ist davon nicht betroffen.

- **Metriken (deterministisch lexikalisch):** `thread_recall` (Anteil Soll-Stränge mit ≥1 passendem produzierten Strang), `fragmentation` (distinkte Labels je Soll-Strang, Soll 1.0 — das Label-Konsistenz-Signal fürs Prompt-Tuning), `false_merge` (ein Strang matcht beide Glieder eines `must_not_merge`-Paars), `false_resolve` (der Gegenpart eines `must_not_resolve`-Strangs trägt ein `fact_type=="auflösung"`-Flag). Matching ist **label-primär, unterscheidende-Entität-sekundär** (ubiquitäre Kern-Figuren matchen sonst jeden Strang mit jedem).
- **Nur messen, kein Gate (Slice A).** Das harte Gate (thread_recall-Floor, false_merge/false_resolve = 0) kommt in Slice E. Die Task misst die **Roh-Extraktions-Labels** vor Clustering (Slice C) + produktivem Reader (Slice D1) — der Measure-First-Anker (#557); der Wert bewegt sich, sobald der Extraktions-Prompt (Slice B) verbessert wird.
- **Ehrliche Grenzen:** (1) Seit **Slice B (#831)** emittiert die Extraktion `fact_type` + `thread` pro Fakt (`normalize_fact/4`, GBNF-Schema, beide required) → die Task liefert echte Zahlen. Clustering (Slice C) + produktiver Reader (Slice D1) fehlen noch → gescort werden die **Roh-Labels** (das Fragmentierungs-Signal fürs Prompt-Tuning). (2) `false_merge` ist deterministisch nur **label-/entity-sichtbar**; ein subtiler Ein-Label-Merge eines entity-untrennbaren Paars (Erpressung ↔ Gegenspiel im Skandal-Set) braucht eine semantische Fakt-Zuordnung (Judge, spätere Arbeit). Refuses `MIX_ENV=prod`. Voraussetzung: Ollama läuft + Stage-2-Modell gepullt.
