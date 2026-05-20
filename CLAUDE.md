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

For every development task the user assigns, follow this loop:

1. **Find a matching issue.** Run `tea issues list -r tomloresys/lore-tracker --state open` and pick the one that fits. If none fits, ask the user whether to file a new one (Default: ja, anlegen via `tea issues create -t … -d … -L <label-csv> -m "<milestone>"`). Ohne Issue keine Codezeile — Ausnahme nur für die unten gelisteten Doc-/Typo-/Hotfix-Sonderfälle.
   - **Neue Issues bekommen immer mindestens einen Label** aus der bestehenden Liste (`tea labels list -r tomloresys/lore-tracker`): primär `feature` oder `bug`; zusätzlich Domain (`llm` / `ui` / `audio` / `infra` / `docs` / `permission` / `mobile` / `i18n` / `architecture` / `live-transcription`); `blocked` falls auf ein anderes Issue wartend. Ungelabelte Issues fallen aus der Filterbarkeit raus und werden vergessen — Labels sind nicht optional.
2. **Take the ticket.** Vor dem Branch das Issue dem aktiven Bearbeiter zuweisen: `tea issues edit -a tomloresys <N>`. So sieht jeder im Tracker wer woran arbeitet, kein doppeltes Anpacken.
3. **Create a feature branch** named after the issue: `issue-<N>-short-slug` (e.g., `issue-11-self-critic`). Genau ein Branch pro Issue — wenn der Scope sich auf etwas anderes ausweitet, neues Issue + neuer Branch. Never work directly on `master`.
4. **Build the change.** Commit each time the code compiles cleanly (`mix compile` passes — tests staying green is preferred but not required for intermediate commits). Small focused commits beat one big WIP commit. Don't push during this phase.
5. **Doku mit-pflegen.** Wenn die Änderung etwas berührt, das in `CLAUDE.md`, `README.md`, `docs/`, `CONTRIBUTING.md` oder einem Modul-`@moduledoc` beschrieben ist, **im selben PR** die Doku nachziehen — nicht in einem Folge-PR. Doku-Drift sammelt sich sonst unsichtbar an, und die nächste Session arbeitet auf falschen Annahmen. Faustregel: wenn ein bestehender Doku-Satz nach deinem PR nicht mehr stimmt, ist es Teil deines PRs ihn zu fixen. Gilt auch für gelistete Befehle, Pfade, Env-Vars, Architektur-Skizzen und Workflow-Schritte.
6. **Ask for review.** Tell the user what was built and ask explicitly whether it's good ("ist das so gut?"). Wait for confirmation.
   - **If yes** → open a pull request to `master` via `tea pulls create`, merge it (`tea pulls merge`), and **manually push to gigalixir prod** afterwards (`git push gigalixir HEAD:refs/heads/master`). Codeberg-Woodpecker ist für dieses Repo aktuell nicht aktiv (Issue #31) — der manuelle Push ist offizieller Workflow-Schritt bis das gefixt ist.
   - **If no** → the user will say what to change. Iterate from step 4 (Code + Doku).

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
