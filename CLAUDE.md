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
- `mix credo --checks LoreTracker.Credo.Check` — AST-Linter (Issue #544). Die 5 vormaligen lore.audit-Regeln + ein God-Module-Check (`module_too_long`, #544-Headline) + zwei Präventions-Checks (Issue #614: `raw_event_bridge_publish` flaggt rohes `EventBridge.publish` in LiveViews → erzwingt den `Publisher.publish/2`-Cold-Fail-Flash, schließt die Silent-Failure-Klasse #613; `unescaped_markdown_render` flaggt `Earmark.as_html(…, escape: false)` im hub_web-Layer → schließt die Stored-XSS-Klasse #604 am Definitionspunkt, deckt damit auch `.heex`-konsumierte Render-Pfade) als Custom-Checks (`tools/credo/*.ex`, via `.credo.exs` `requires:`). **CI nutzt Diff-Scope**: `mix credo diff --from-git-merge-base origin/master --checks LoreTracker.Credo.Check` flaggt nur Verstöße, die der aktuelle Branch ggü. master NEU hinzufügt (exit 16 bei added, 0 sonst) — der bestehende Backlog blockt nie. CI-Step noch `failure: ignore` (warn-Soak); Blocking-Flip = das entfernen. Der Regex-basierte `mix lore.audit` (#535) wurde damit **abgelöst + entfernt**.
- `mix dialyzer` — Typ-Analyse (Issue #540). Fängt Spec-Drift / unmögliche Guards / dead `{:error,_}`-Pfade. Erster Lauf baut den PLT (`priv/plts/`, ~2,5 min, gitignored); danach ~1 min. **Findings-Cleanup ist durch (Issue #589: 80 → 0 actionable Findings über 4 Cuts).** `mix dialyzer` läuft sauber durch (`done (passed successfully)`). Die `.dialyzer_ignore.exs`-Baseline hält **genau einen** bestätigten Dep-FP (`Phoenix.Tracker.update/5`-Success-Typing, Cut 2); alle anderen Suppressions sind co-lokierte `@dialyzer {:nowarn_function}`/`{:no_opaque}`-Attribute mit Begründung am Code (intentionale Boundary-Defense, anon halt-Closures, dev-Tooling-Confusion). CI-Step läuft seit #589 **auf PRs + master-Push** als **warn-Soak** (`failure: ignore`) — kein PLT-Cross-Pipeline-Cache, daher ~3,5 min/PR (parallel zu `test`). Blocking-Flip (`failure: ignore` entfernen → echtes Merge-Gate) folgt nach dem PR-Soak (#557-Lesson: erst beobachten, dann blockieren).
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

**Disaster-Recovery für Worker:** Mnesia bleibt der kanonische Speicher pro Worker. Wenn ein Worker seine Mnesia verliert: re-pair + `pull_since`/`pull_since_global` holt alle Events aus anderen Workern derselben Campaigns zurück.

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

- `.woodpecker.yml` at the repo root has compile + test + deploy steps. Seit Issue #31 ist die Pipeline auf den stateless-Hub angepasst: **compile** läuft `mix compile --warnings-as-errors` über das ganze Umbrella (Drift-Gate für hub + worker + shared), **test** fährt nur die hub-Suite (`mix cmd --app hub mix test` — stateless, kein Postgres/Ecto mehr), **deploy** pusht zu Gigalixir ohne `ps:migrate` (kein Schema). **Seit Issue #31 ist Woodpecker aktiv** (CI-Zugriff via `Codeberg-e.V./requests` #2016 auto-granted nach der AGPL-Relizenzierung #477; Repo in ci.codeberg.org aktiviert, Webhook gesetzt, die drei Secrets `gigalixir_email`/`gigalixir_api_key`/`gigalixir_app_name` als push-scoped Secrets hinterlegt). **Jeder master-Push deployt jetzt automatisch nach Gigalixir** — der manuelle `git push gigalixir HEAD:refs/heads/master` ist damit **überflüssig** (würde doppelt deployen). compile + test laufen zusätzlich auf jedem PR.
- `mix release.hub` (alias) builds the prod release (`lore_tracker`, hub+shared only — worker stays local-install).
- Required Codeberg secrets: `gigalixir_email`, `gigalixir_api_key`, `gigalixir_app_name`.
- Buildpack pins live in `elixir_buildpack.config` + `phoenix_static_buildpack.config`.

### Branch-Protection als Merge-Gate (Issue #485)

`master` ist **Branch-protected** mit dem Woodpecker-PR-Check als Required-Status — der Merge-Button bleibt gesperrt, solange `ci/woodpecker/pr/woodpecker` (compile + test) rot oder pending ist. Erst **CI grün + Maintainer-Merge** lässt nach master (und damit per Auto-Deploy nach Prod). Kein roter/ungetesteter Stand kommt mehr durch — genau das „CI-OK, dann mein OK"-Modell. Praktische Folge fürs Mergen: erst den CI-Status pollen (grün abwarten), dann mergen — Merge-Versuche auf rot/pending werden geblockt.

Die Settings leben in der Codeberg-Web-UI (**Repo → Settings → Branches → `master`**, Maintainer-only, nicht per API/Commit automatisierbar):

- **Push deaktivieren** — direkte Pushes auf master gesperrt, alles läuft über PRs.
- **Statuscheck-Muster** = `ci/woodpecker/pr/woodpecker` — der PR-Check muss grün sein.
- **Ungeschützte Dateimuster** = `.woodpecker.yml` — siehe Ausnahme unten.

**Ausnahme — CI-Config kann sich nicht selbst grün prüfen:** Woodpecker nutzt für PR-Events die `.woodpecker.yml` aus dem **Ziel**-Branch (master), nicht aus dem PR-Branch. Eine kaputte CI-Config reparierende Änderung kann ihren eigenen Fix daher nie per PR validieren — der Check bliebe ewig rot. Lösung: `.woodpecker.yml` steht in den **Ungeschützten Dateimustern**, d.h. PRs, die *nur* diese Datei ändern, umgehen den Required-Status (Admin-Bypass alternativ). Bei reinen CI-Config-Fixes also bewusst trotz noch-rotem/abwesendem Check mergen.

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
- **Issue-Audit-Snapshot**: `docs/issue-audit-2026-06-01.md` — letzter Relevanz-Snapshot (still-relevant/partial/resolved/obsolete) über alle offenen Issues mit Cluster-Vorschlägen (löst `docs/issue-audit-2026-05-24.md` ab). Bei der nächsten Refinement-Runde aktualisieren oder durch ein neueres Stichtag-Doc ersetzen, damit die Liste nicht stale wird.

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
- **Worker against gigalixir prod hub** (sname `worker_prod`): same but with `LORE_MNESIA_DIR=…/prod-worker` and `HUB_BASE_URL=https://loretracker.gigalixirapp.com`. **Seit #492** kann `worker_prod` stattdessen als **self-updating systemd --user Daemon** laufen (`LORE_WORKER_AUTOUPDATE=1` + `LORE_WORKER_DEPLOY_REPO=…`) — er zieht sich nach jedem Hub-Deploy automatisch nach (git→`compile --force`→`System.halt`, nur wenn idle; `--force` seit #516, damit die SHA auch ohne Worker-Versions-Bump neu gebacken wird → kein Drift-Loop). Drei Robustheits-Säulen: **#512** systemd-Watchdog (`WatchdogSec=`+`NotifyAccess=main`, `Worker.SystemdWatchdog`) killt Zombie-BEAMs, wenn der Halt nicht durchkommt; **#516** `compile --force` garantiert SHA-Konvergenz; **#500** Boot-Crash-Rollback (`Worker.Updater.boot_guard/1` beim Start) — bootet eine frisch self-updatete SHA wiederholt nicht durch (>2 Versuche, nie via Hub-Join als „good" markiert), rollt der Worker selbst auf die letzte gute SHA (`:last_good_sha`) zurück. Setup: `apps/worker/priv/systemd/worker_prod.service` + `docs/Worker-Setup.md`.

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

### LLM-Pipeline-Backfill für nachgereichte Sessions

`Worker.Recording.Pipeline` (Stages 2-4 = Resümee / Epos / Chronik) feuert nur auf `SessionEnded`-Events während einer **echten Aufnahme**. Für seeded oder nachträglich importierte Sessions muss man die Pipeline pro Session manuell triggern — seit Issue #121 als direkter Pipeline-Call ohne Hub-Event-Roundtrip:

```elixir
:rpc.call(:"worker_prod@#{hostname}", Worker.Recording.Pipeline, :run_for_session, [SESSION_ID])
```

**Pro Session warten bis fertig bevor die nächste getriggert wird** — sonst rennen N LLM-Calls gleichzeitig durch den Ollama-Backend (mit großem Modell ~1 Inferenz auf einmal sinnvoll). Completion-Signale (von schnell nach robust):

- `Worker.Recording.Pipeline`-GenServer-State (`:sys.get_state(…).running`) listet aktive `session_id`s — gone = done. Reicht für sequentielles Trigger-Skript.
- `Worker.Repo.get_session_summary(session_id)` ≠ `nil` bestätigt dass Stage 2 mindestens lief.
- Korrektes Signal für volle Pipeline-Completion: `pipeline_status`-PubSub-Events watchen, auf `stage4`+`ended` warten.

Nur der **Owner-Worker** (`campaign.owner_discord_id == worker.admin_discord_id`) führt die Pipeline aus — bei Multi-Worker-Setups muss der Trigger den richtigen Worker erwischen. Das `--regenerate-llm`-Flag aus Issue #58 wird genau diesen Pattern abbilden.

### Cloud-LLM-Backends (Issue #27, ab Etappe 5b direkt vom Worker)

Seit Issue #162 (Etappe 5b) calls der Worker Cloud-LLM-APIs **direkt** — Hub kennt keine Cloud-Credentials mehr. Kein Proxy, kein Vault.

Setup pro Worker-Maschine: passende Env-Var in der Worker-Start-Umgebung (`.env` neben dem Worker oder direkt vor `mix run`). Dann in `/settings` Stage-Backend auf das gewünschte Backend + ein Modell aus dessen `models/0`. Wenn die Env-Var fehlt, scheitert die Pipeline-Stage mit `:no_key_configured` (Logger-Warning, kein silent Fallback auf Ollama).

Unterstützte Backends:
- **Anthropic** (`ANTHROPIC_API_KEY=sk-ant-...`) — `Worker.LLM.Anthropic.complete/2` ruft `https://api.anthropic.com/v1/messages` mit `x-api-key: $ANTHROPIC_API_KEY`. Modelle: `Worker.LLM.Anthropic.models/0`.
- **OpenAI** (`OPENAI_API_KEY=sk-proj-...`) — `Worker.LLM.OpenAI.complete/2` ruft `https://api.openai.com/v1/chat/completions` mit `Authorization: Bearer $OPENAI_API_KEY`. Modelle: `Worker.LLM.OpenAI.models/0`.
- **Google Gemini** (`GEMINI_API_KEY=...`) — `Worker.LLM.Google.complete/2` ruft `https://generativelanguage.googleapis.com/v1beta/models/<MODEL>:generateContent?key=$GEMINI_API_KEY` (Auth via Query-Param, nicht Header). Modelle: `Worker.LLM.Google.models/0` (gemini-2.5-pro / -flash / 2.0-flash / -flash-lite). Body-Shape unterscheidet sich (`contents/parts` statt `messages`).

**Gemeinsamer Code** (Issue #463): Retry-Loop, HTTP-Error-Mapping, `LLMCallBilled`-Spend-Event und Stage-→-Modell-Lookup leben in `Worker.LLM.CloudHelper`. Backend-spezifisch bleibt nur die Request-Shape, das Response-Parsing und die Auth-Mechanik. Neue Cloud-Backends spiegeln das Anthropic-Modul (~50 Zeilen) und reusen den Helper.

HTTP-Error-Mapping einheitlich für alle drei Backends: 401/403 → `:upstream_auth`, 429 → `:upstream_rate_limit`, 5xx → `{:upstream_error, status, msg}`, Netz/Timeout → `{:network_error, reason}`. Retry: 2× exponentielles Backoff (500ms / 1s) bei 429/5xx/Network, sofort hart bei :upstream_auth + 4xx ≠ 429 (Client-Fehler).

Folge-Issues (separate Tickets): `LLMCallBilled`-Event für Spend-Tracking (#177), Streaming (#176), Per-User-Spend-Caps (#178).

### Campaign-Pipeline-Trigger (Issue #104)

In der Campaign-LV gibt es zwei Buttons (sichtbar je nach Rolle):

- **`🔄 neu generieren`** pro Session (in der Resümee-Spalte): Owner, Spielleiter-mit-Membership oder Admin. Triggert direkt `Worker.Recording.Pipeline.run_for_session/1` im Owner-Worker via `Hub.Commands.request_session_regenerate/3` (Channel-Push, kein Event-Roundtrip — siehe Issue #121).
- **`🔄 Pipeline für alle Sessions neu starten`** im Campaign-Header: Spielleiter-mit-Membership oder Admin. Triggert `Worker.Recording.CampaignReplay` im Owner-Worker, der sequentiell alle Sessions durchschickt + via `pipeline_status` (kind: `"campaign_replay"`) live einen Banner mit Fortschritt liefert.

Lock im Worker — nur ein Campaign-Replay pro Worker gleichzeitig. Bei laufendem Replay sind beide Buttons disabled. Stage-Failures werden geloggt (`Pipeline: failed for session=…`) aber der Replay macht trotzdem mit der nächsten Session weiter — sonst würde eine misslungene Stage 2 das ganze Backfill blockieren.

### LLM-Probelauf (Issue #74)

Statt manuell pro Session zu triggern: unter `/admin/probelauf` (nur :admin) gibt es einen „Probelauf starten"-Button. `Worker.Probelauf` seedet eine eigene `probelauf-<uuid>`-Kampagne (3 Sessions à 10/30/100 Utterances — short/medium/long Prompts), schickt sie sequentiell durch die Pipeline, misst pro Stage Wall-Clock + Outcome (`ok`/`timeout`/`empty_output`/`parse_error`/`other_error`), publisht `ProbelaufFinished` und cascade-deleted die Kampagne. UI zeigt Heatmap pro Session × Stage + Heuristik-Empfehlung; „Empfehlung übernehmen" schreibt direkt in `Worker.Settings`.

Probelauf-Campaigns sind aus `campaigns_for`/`all_campaigns` rausgefiltert (Prefix-Match `probelauf-`). Lock im `Worker.Probelauf`-GenServer — nur ein Lauf gleichzeitig pro Worker.

#### LiveView-Gotchas (gesammelt beim Bau von /admin/probelauf)

- **`fetch_live_flash` muss im `:browser`-Pipeline sein**, sonst crasht jeder LiveView der `put_flash(socket, ...)` im mount/load_data ruft mit `ArgumentError "flash not fetched"`. Andere LiveViews funktionieren oft „zufällig" weil sie put_flash nur im Fehlerpfad nutzen — neuer LiveView ohne den Plug fällt auf die Nase sobald der reload-Pfad einen Flash schreibt.
- **HEEx `@assigns` ≠ Modul-Attribute**: `@stages` im Template referenziert immer `socket.assigns.stages` — Modul-`@stages` muss explizit als `assign(:stages, @stages)` in mount durchgereicht werden. Sonst `KeyError :stages` bei render.
- **`Worker.Repo.serialize/1` braucht `nil`-Klausel** wenn Snapshot-Felder optional sind (z.B. `running == nil` wenn nichts läuft). Sonst FunctionClauseError beim Snapshot.
- **Modal-Pattern: `<.lt_modal on_close="...">` benutzen, NIEMALS `onclick="event.stopPropagation()"` (Issue #352)**: Phoenix-LiveView registriert seine Click-Listener delegated auf document-Level. Wenn man im Modal-Body ein `onclick="event.stopPropagation()"` setzt um Backdrop-Klick-Schließen-Bubbling zu unterdrücken, killt das **alle** `phx-click`/`phx-change`/`phx-submit`-Events innerhalb des Containers — Buttons im Modal scheinen tot, kein Crash, kein Log. Der korrekte Pattern ist die `HubWeb.UIComponents.lt_modal/1`-Komponente: backdrop = `phx-click`, content = `phx-click-away`, KEIN JS-stopPropagation. Iron-Law-Regel #6 scant nach dem Anti-Pattern.

### Modell-Inkompatibilitäten + Pipeline-Robustheit (Issue #75)

Die Pipeline meldet `pipeline_stage`/`failed` statt stilles `ended`, wenn das LLM für Stage 4 nach Retry **0 Chronik-Einträge** liefert. Beobachtet beim Folger-R&J-Import: `qwen3:30b-a3b` (Thinking-Modell) kollidiert mit Ollamas `format: "json"` Modus — der Server verwirft den `<think>`-Block-Prefix und liefert `{"response": ""}`. Stage 4 parst seither auch Output mit `<think>...</think>`-Block und Markdown-Code-Fences (siehe `Worker.Recording.Pipeline.parse_chronik_json/1`).

Stage 3 (Epos) läuft seit Issue #373 ebenfalls im strict JSON-Schema-Mode (analog Stage 2/4 aus #289 P1) — `stage3_json_schema/0` erzwingt `{"content_md": string, "source_refs": [string]}` token-seitig, das verhindert `<think>`-Block-Lecks, Code-Fence-Wrapping und Vorrede-Plaudereien. Double-Wrap (`content_md` enthält wieder ein JSON-Object) lässt sich strukturell nicht ausschließen — der Stage-3-Prompt enthält dafür eine explizite Klarstellung. Bei großen Modellen + langem Prompt kann Stage 3 weiterhin am HTTP-Timeout scheitern. Default ist `Worker.Settings.get(:http_timeout_ms, 600_000)` (vorher hardcoded 120 s). Per Worker tunbar via `Worker.Settings.put(:http_timeout_ms, …)`.

Empfohlene Sanity-Checks pro Worker-Setup vor dem ersten Backfill:

```elixir
# 1) Modell antwortet überhaupt im JSON-Mode?
:rpc.call(node, Worker.LLM, :complete, [:chronik, "Antworte mit {\"ok\":true}", [format: "json"]])

# 2) Modell schafft den Stage-3-Prompt in akzeptabler Zeit?
# (~8 KB Prompt; sollte <60s sein, sonst http_timeout_ms hochsetzen)
```

Wenn `parse_chronik_json/1` für einen real-world Output `[]` liefert obwohl das LLM Text geliefert hat → bitte den Raw-Output an Issue #75 anhängen.

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
