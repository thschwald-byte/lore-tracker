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

## Deploy (Gigalixir + Codeberg-Woodpecker)

- `.woodpecker.yml` at the repo root has compile + test + deploy steps. **But**: Woodpecker is currently not active for this repo (OAuth-permission gap — siehe Issue #31). Until that's resolved, every master-merge needs a manual `git push gigalixir HEAD:refs/heads/master` to actually deploy.
- `mix release.hub` (alias) builds the prod release (`lore_tracker`, hub+shared only — worker stays local-install).
- Required Codeberg secrets: `gigalixir_email`, `gigalixir_api_key`, `gigalixir_app_name`.
- Buildpack pins live in `elixir_buildpack.config` + `phoenix_static_buildpack.config`.

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

- Issues live on Codeberg at https://codeberg.org/tomloresys/lore-tracker — use `tea issues …` (tea is installed and authenticated as `tomloresys`).
- Prod hub: https://loretracker.gigalixirapp.com (manuell deployt via `git push gigalixir HEAD:refs/heads/master` — Woodpecker-Auto-Deploy ist offen in Issue #31).
- Local dev hub: http://localhost:4000 (`cd apps/hub && mix phx.server`).

## Development workflow

**Goldene Regel: jede Zeile Sourcecode hängt an einem Issue. Jedes Issue bekommt genau einen Branch. Bevor der Branch geöffnet wird, holt man sich das Ticket (`tea issues edit -a tomloresys <N>` — Assignee setzen).**

**Session-Start: einmal `git fetch origin master` (via HTTPS-Token wenn SSH-Agent nicht greifbar — siehe `CLAUDE.local.md` für den Token-Trick).** Sonst arbeitet man gegen einen stale `refs/remotes/origin/master`-Ref, `git status` lügt über „N Commits vor origin", und man baut Branches auf einem master der eigentlich schon längst weiterbewegt wurde. Konfliktreiche PRs + redundante Bug-Fixes sind die Folge.

For every development task the user assigns, follow this loop:

1. **Find a matching issue.** Run `tea issues list -r tomloresys/lore-tracker --state open` and pick the one that fits. If none fits, ask the user whether to file a new one (Default: ja, anlegen via `tea issues create -t … -d … -L <label-csv> -m "<milestone>"`). Ohne Issue keine Codezeile — Ausnahme nur für die unten gelisteten Doc-/Typo-/Hotfix-Sonderfälle.
   - **Neue Issues bekommen immer mindestens einen Label** aus der bestehenden Liste (`tea labels list -r tomloresys/lore-tracker`): primär `feature` oder `bug`; zusätzlich Domain (`llm` / `ui` / `audio` / `infra` / `docs` / `permission` / `mobile` / `i18n` / `architecture` / `live-transcription`); `blocked` falls auf ein anderes Issue wartend. Ungelabelte Issues fallen aus der Filterbarkeit raus und werden vergessen — Labels sind nicht optional.
2. **Take the ticket.** Vor dem Branch das Issue dem aktiven Bearbeiter zuweisen: `tea issues edit -a tomloresys <N>`. So sieht jeder im Tracker wer woran arbeitet, kein doppeltes Anpacken.
3. **Branch-Check vor Branch-Anlage.** Prüfen ob das Issue schon einen Branch hat — sonst entstehen zwei parallele Branches auf demselben Ticket (z.B. wenn eine andere Claude-Session schon dran ist oder eine alte Session unterbrochen war):
   ```bash
   git fetch origin "refs/heads/issue-<N>-*:refs/remotes/origin/issue-<N>-*" 2>/dev/null
   git branch -a | grep -E "(^|/)issue-<N>-"   # lokal + remote
   tea issues <N> | grep -iE "^[[:space:]]*Branch:"   # Comment-Marker
   ```
   - **Existiert ein Branch** → STOP. An dem bestehenden Branch weiterarbeiten (ggf. `git checkout` + `git pull`/`git rebase master`). Kein neuer Branch.
   - **Kein Branch da** → neuen Branch `issue-<N>-short-slug` anlegen (e.g., `issue-11-self-critic`) **und sofort als Issue-Comment hinterlegen** damit's beim nächsten Check auffindbar ist:
     ```bash
     tea comment <N> "Branch: \`issue-<N>-short-slug\`"
     ```
   Genau ein Branch pro Issue — wenn der Scope sich auf etwas anderes ausweitet, neues Issue + neuer Branch. Never work directly on `master`.
4. **Build the change.** Commit each time the code compiles cleanly (`mix compile` passes — tests staying green is preferred but not required for intermediate commits). Small focused commits beat one big WIP commit. Don't push during this phase.
   - **Version bumpen** in `apps/<app>/mix.exs` wenn die Änderung App-Verhalten / Wire-Protocol / Schema berührt. Pre-1.0: Minor (`0.3.0`) bei Feature / rückwärtskompat. Wire-Erweiterung, Patch (`0.2.1`) bei Bugfix / Polish ohne Verhaltens-Änderung. **`shared`-Bump erzwingt `hub` + `worker` mit-bumpen** (Wire/Schema-Sync). Reine Doc-/Doku-/Tooling-PRs brauchen keinen Bump. Nach Merge auf master: Tags `hub-v<N>` / `worker-v<N>` / `shared-v<N>` lokal setzen + pushen (`git tag … && git push origin --tags` — Token-Trick siehe `CLAUDE.local.md`).
5. **Doku mit-pflegen.** Wenn die Änderung etwas berührt, das in `CLAUDE.md`, `README.md`, `apps/hub/README.md`, `apps/worker/README.md`, `apps/shared/README.md`, `docs/Worker-Setup.md`, `docs/Spieler-Anleitung.md`, `docs/Backup-Recovery.md`, `CONTRIBUTING.md` oder einem Modul-`@moduledoc` beschrieben ist, **im selben PR** die Doku nachziehen — nicht in einem Folge-PR. Doku-Drift sammelt sich sonst unsichtbar an, und die nächste Session arbeitet auf falschen Annahmen. Faustregel: wenn ein bestehender Doku-Satz nach deinem PR nicht mehr stimmt, ist es Teil deines PRs ihn zu fixen. Gilt auch für gelistete Befehle, Pfade, Env-Vars, Architektur-Skizzen und Workflow-Schritte.
6. **Test-Instanz hochfahren** (PR-Hub + PR-Worker auf Port 4001+(siehe CLAUDE.local.md), siehe „PR-test instances" unten). **Pflicht** bevor die Review-Frage gestellt wird — User muss den Branch klickbar im Browser haben können. Reine Doc-/Typo-/Config-PRs ohne UI-Wirkung dürfen das überspringen; im Zweifel hochfahren.
7. **Ask for review.** Tell the user what was built (incl. Test-URL für die hochgefahrene Instanz) und frag explizit ob's gut ist („ist das so gut?"). Wait for confirmation.
   - **If yes** → open a pull request to `master` via `tea pulls create`, merge it (`tea pulls merge`), and **manually push to gigalixir prod** afterwards (`git push gigalixir HEAD:refs/heads/master`). Danach Test-Instanz runterfahren + Worktree/Mnesia-Dirs aufräumen. Codeberg-Woodpecker ist für dieses Repo aktuell nicht aktiv (Issue #31) — der manuelle Push ist offizieller Workflow-Schritt bis das gefixt ist. **Falls der PR Worker-Code verändert hat** (`apps/worker/` oder `apps/shared/`): den User darauf hinweisen, dass der lokale `worker_prod`-Daemon neu gestartet werden muss (`cd apps/worker && LORE_MNESIA_DIR=… HUB_BASE_URL=https://loretracker.gigalixirapp.com elixir --sname worker_prod --no-halt -S mix run`), damit er den neuen Code gegen den frisch deployten Hub läuft.
   - **If no** → the user will say what to change. Iterate from step 4 (Code + Doku); Test-Instanz weiterlaufen lassen.

Exceptions (don't enforce the branch+PR-loop, kein Issue nötig): pure docs-only tweaks (CLAUDE.md, README, docs/*), trivial typo fixes, or explicitly user-driven hot-fixes can go straight on `master`. When in doubt, branch.

### PR-test instances

Port 4000 is reserved for the **master** hub. For each open PR awaiting user review, spin up an independent hub+worker pair on incrementing ports starting at 4001:

| Port | Branch | Mnesia dir |
|---|---|---|
| 4000 | `master` | `priv/mnesia/dev` (+ `priv/mnesia/dev-worker`) |
| 4001 | first PR  | `priv/mnesia/pr-4001` (+ `pr-4001-worker`) |
| 4002 | second PR | `priv/mnesia/pr-4002` (+ `pr-4002-worker`) |
| … | … | … |

Each PR-test pair gets its own **git worktree** (`git worktree add ../lore-pr-4001 <branch>`) so file edits per branch don't collide. Hub is started with `PORT=4001 mix phx.server` (override added in `runtime.exs` for dev) and an own `LORE_MNESIA_DIR`. Worker is started with `HUB_BASE_URL=http://localhost:4001`, own `LORE_MNESIA_DIR`, and own sname (e.g. `worker_pr4001`).

When the user approves a PR ("ja"), shut down its hub+worker pair before merging — frees the port + Mnesia lock. The worktree directory can be deleted after merge (`git worktree remove …`).

The current set of running PR-test instances should be listed in `CLAUDE.local.md` so future sessions don't double-spawn ports.

## Local setup recommendation (`CLAUDE.local.md`)

Neue Claude-Code-Sessions auf einer neuen Maschine sollten als ersten Schritt eine eigene **`CLAUDE.local.md`** im Repo-Root anlegen. Die Datei ist in `.gitignore` und gehört dem jeweiligen Entwickler — sie hält maschinen-spezifische Pfade, Ports, Workarounds und Operational-Do-Nots fest, die nirgendwo sonst hingehören (CLAUDE.md = Repo-weit, `docs/Worker-Setup.md` = User-Onboarding, `CONTRIBUTING.md` = Code-Contributor-Onboarding).

Empfohlenes Sektions-Skelett:

```markdown
# CLAUDE.local.md — <name> @ <hostname>

Gitignored. Machine-local context für Claude Code.

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
| Worker against local hub | `worker` | `priv/mnesia/dev-worker` | http://localhost:4000 |
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

## Currently running PR-test instances
_None._ (Updaten wenn PR-Hub+Worker gestartet wird, damit kein zweites Setup denselben Port okkupiert.)

## Test seeding scripts / ad-hoc artifacts
- Kurz-Notizen über `/tmp/`-Skripte die noch nützlich sind und welche bereits durch committed Mix-Tasks ersetzt wurden.
```

Wichtig: **CLAUDE.local.md anlegen ist explizit `.gitignored`** — niemals committen, auch nicht den Beispiel-Inhalt aus diesem Block 1:1 als File einchecken. Sensible Tokens, Discord-IDs, Mnesia-Pfade gehören in keinen Git-History.

## Local multi-BEAM setup

Hub + worker run in **separate** BEAMs locally because each owns its own Mnesia schema. Schemas are node-name-bound — start each BEAM with the sname matching the schema in its data directory.

- **Hub** (no sname → `nonode@nohost`): `cd apps/hub && mix phx.server` — uses `priv/mnesia/dev/`.
- **Worker against local hub** (sname `worker`): `cd apps/worker && LORE_MNESIA_DIR=$(pwd)/../../priv/mnesia/dev-worker elixir --sname worker --no-halt -S mix run`.
- **Worker against gigalixir prod hub** (sname `worker_prod`): same but with `LORE_MNESIA_DIR=…/prod-worker` and `HUB_BASE_URL=https://loretracker.gigalixirapp.com`.

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

Setup pro Worker-Maschine: `ANTHROPIC_API_KEY=sk-ant-...` in der Worker-Start-Umgebung (`.env` neben dem Worker oder direkt vor `mix run`). Dann in `/settings` Stage-Backend auf `anthropic` + Modell aus `Worker.LLM.Anthropic.models/0`. Wenn die Env-Var fehlt, scheitert die Pipeline-Stage mit `:no_key_configured` (Logger-Warning, kein silent Fallback auf Ollama).

`Worker.LLM.Anthropic.complete/2` ruft `https://api.anthropic.com/v1/messages` mit `x-api-key: $ANTHROPIC_API_KEY`. HTTP-Error-Mapping: 401 → `:upstream_auth`, 429 → `:upstream_rate_limit`, 5xx → `{:upstream_error, status, msg}`, Netz/Timeout → `{:network_error, reason}`.

Folge-Issues (nicht in Phase 1a): `LLMCallBilled`-Event für Spend-Tracking, OpenAI/Google-Backends, Streaming, Per-User-Spend-Caps.

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

### Modell-Inkompatibilitäten + Pipeline-Robustheit (Issue #75)

Die Pipeline meldet `pipeline_stage`/`failed` statt stilles `ended`, wenn das LLM für Stage 4 nach Retry **0 Chronik-Einträge** liefert. Beobachtet beim Folger-R&J-Import: `qwen3:30b-a3b` (Thinking-Modell) kollidiert mit Ollamas `format: "json"` Modus — der Server verwirft den `<think>`-Block-Prefix und liefert `{"response": ""}`. Stage 4 parst seither auch Output mit `<think>...</think>`-Block und Markdown-Code-Fences (siehe `Worker.Recording.Pipeline.parse_chronik_json/1`).

Stage 3 (Epos) hat keinen JSON-Mode, scheitert aber bei großen Modellen mit langem Prompt am HTTP-Timeout. Default ist jetzt `Worker.Settings.get(:http_timeout_ms, 600_000)` (vorher hardcoded 120 s). Per Worker tunbar via `Worker.Settings.put(:http_timeout_ms, …)`.

Empfohlene Sanity-Checks pro Worker-Setup vor dem ersten Backfill:

```elixir
# 1) Modell antwortet überhaupt im JSON-Mode?
:rpc.call(node, Worker.LLM, :complete, [:chronik, "Antworte mit {\"ok\":true}", [format: "json"]])

# 2) Modell schafft den Stage-3-Prompt in akzeptabler Zeit?
# (~8 KB Prompt; sollte <60s sein, sonst http_timeout_ms hochsetzen)
```

Wenn `parse_chronik_json/1` für einen real-world Output `[]` liefert obwohl das LLM Text geliefert hat → bitte den Raw-Output an Issue #75 anhängen.

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
mix lore.seed.romeo --as-admin 615614311255244801 --display-name "Tom"
mix lore.seed.romeo --as-admin <id> --mode protocol-only  # Resümee/Epos/Chronik leer (für LLM-Lasttests)
```

Refuses `MIX_ENV=prod`. Berührt nur die Kampagne `romeo-julia-demo` — kollidiert nicht mit echten Daten. Use Cases: Klick-Demos, LLM-Lasttests (vgl. #69 + `--mode protocol-only`), Onboarding einer fremden Claude-Code-Instanz (mit `--as-admin <eigene-discord-id>` ist der Caller sofort Owner+Admin der Romeo-Demo).
