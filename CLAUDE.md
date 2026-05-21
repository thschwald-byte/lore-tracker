# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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

## Hub storage backend

The Hub's event log + worker-token tables go through `Hub.EventLog` / `Hub.WorkerTokens`, which dispatch at runtime to one of two adapters:

- `:mnesia` (default, dev) — file-backed `disc_copies` in `priv/mnesia/<env>/`; no external DB required.
- `:postgres` (prod, e.g. Gigalixir) — Ecto-backed `events` + `worker_tokens` tables; activated automatically in the runtime.exs `config_env() == :prod` block.

To test the Postgres adapter locally, point at a running Postgres and set `LORE_STORAGE_BACKEND=postgres` in `.env`, then `mix ecto.create && mix ecto.migrate`. Hub.Repo dev creds default to `postgres/postgres@localhost/loretracker_dev`.

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
5. **Doku mit-pflegen.** Wenn die Änderung etwas berührt, das in `CLAUDE.md`, `README.md`, `docs/`, `CONTRIBUTING.md` oder einem Modul-`@moduledoc` beschrieben ist, **im selben PR** die Doku nachziehen — nicht in einem Folge-PR. Doku-Drift sammelt sich sonst unsichtbar an, und die nächste Session arbeitet auf falschen Annahmen. Faustregel: wenn ein bestehender Doku-Satz nach deinem PR nicht mehr stimmt, ist es Teil deines PRs ihn zu fixen. Gilt auch für gelistete Befehle, Pfade, Env-Vars, Architektur-Skizzen und Workflow-Schritte.
6. **Test-Instanz hochfahren** (PR-Hub + PR-Worker auf Port 4001+, siehe „PR-test instances" unten). **Pflicht** bevor die Review-Frage gestellt wird — User muss den Branch klickbar im Browser haben können. Reine Doc-/Typo-/Config-PRs ohne UI-Wirkung dürfen das überspringen; im Zweifel hochfahren.
7. **Ask for review.** Tell the user what was built (incl. Test-URL für die hochgefahrene Instanz) und frag explizit ob's gut ist („ist das so gut?"). Wait for confirmation.
   - **If yes** → open a pull request to `master` via `tea pulls create`, merge it (`tea pulls merge`), and **manually push to gigalixir prod** afterwards (`git push gigalixir HEAD:refs/heads/master`). Danach Test-Instanz runterfahren + Worktree/Mnesia-Dirs aufräumen. Codeberg-Woodpecker ist für dieses Repo aktuell nicht aktiv (Issue #31) — der manuelle Push ist offizieller Workflow-Schritt bis das gefixt ist.
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

2. **`mix lore.seed.romeo`** (issue #58, not yet implemented) — the planned canonical path: JSONL files committed under `priv/seeds/romeo/`, mix-task applies them via `Hub.EventLog.append/2`. **Guarded against `Mix.env() == :prod`** so it can't accidentally seed against prod. Until that exists, the RPC-bridge above is the only prod-seeding path.

### LLM-Pipeline-Backfill für nachgereichte Sessions

`Worker.Recording.Pipeline` (Stages 2-4 = Resümee / Epos / Chronik) feuert nur auf `SessionEnded`-Events während einer **echten Aufnahme**. Für seeded oder nachträglich importierte Sessions muss man die Pipeline pro Session manuell via `RegenerateRequested`-Event triggern:

```elixir
:rpc.call(:"worker_prod@#{hostname}", Worker.Intents, :publish, [%{
  "kind" => "RegenerateRequested",
  "scope" => "session_pipeline",
  "session_id" => SESSION_ID,
  "campaign_id" => CAMPAIGN_ID
}])
```

**Pro Session warten bis fertig bevor die nächste getriggert wird** — sonst rennen N LLM-Calls gleichzeitig durch den Ollama-Backend (mit großem Modell ~1 Inferenz auf einmal sinnvoll). Completion-Signale (von schnell nach robust):

- `Worker.Recording.Pipeline`-GenServer-State (`:sys.get_state(…).running`) listet aktive `session_id`s — gone = done. Reicht für sequentielles Trigger-Skript.
- `Worker.Repo.get_session_summary(session_id)` ≠ `nil` bestätigt dass Stage 2 mindestens lief.
- Korrektes Signal für volle Pipeline-Completion: `pipeline_status`-PubSub-Events watchen, auf `stage4`+`ended` warten.

Nur der **Owner-Worker** (`campaign.owner_discord_id == worker.admin_discord_id`) führt die Pipeline aus — bei Multi-Worker-Setups muss der Trigger den richtigen Worker erwischen. Das `--regenerate-llm`-Flag aus Issue #58 wird genau diesen Pattern abbilden.

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
