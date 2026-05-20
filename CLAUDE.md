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

- `.woodpecker.yml` at the repo root builds + tests every push; `git push gigalixir HEAD:refs/heads/master` on main branch.
- `mix release.hub` (alias) builds the prod release (`lore_tracker`, hub+shared only — worker stays local-install).
- Required Codeberg secrets: `gigalixir_email`, `gigalixir_api_key`, `gigalixir_app_name`.
- Buildpack pins live in `elixir_buildpack.config` + `phoenix_static_buildpack.config`.

## Issue tracker + URLs

- Issues live on Codeberg at https://codeberg.org/tomloresys/lore-tracker — use `tea issues …` (tea is installed and authenticated as `tomloresys`).
- Prod hub: https://loretracker.gigalixirapp.com (auto-deployed from `master`).
- Local dev hub: http://localhost:4000 (`cd apps/hub && mix phx.server`).

## Development workflow

For every development task the user assigns, follow this loop:

1. **Find a matching issue.** Run `tea issues list -r tomloresys/lore-tracker --state open` and pick the one that fits. If none fits, ask the user whether to file a new one or proceed without an issue.
2. **Create a feature branch** named after the issue: `issue-<N>-short-slug` (e.g., `issue-11-self-critic`). Never work directly on `master`.
3. **Build the change.** Commit each time the code compiles cleanly (`mix compile` passes — tests staying green is preferred but not required for intermediate commits). Small focused commits beat one big WIP commit. Don't push during this phase.
4. **Ask for review.** Tell the user what was built and ask explicitly whether it's good ("ist das so gut?"). Wait for confirmation.
   - **If yes** → open a pull request to `master` via `tea pulls create`, merge it (`tea pulls merge`), and **manually push to gigalixir prod** afterwards (`git push gigalixir HEAD:refs/heads/master`). The Codeberg-Woodpecker CI currently builds + tests but does not auto-deploy on merge — that's the gap manual push fills until CI/CD is improved.
   - **If no** → the user will say what to change. Iterate from step 3.

Exceptions (don't enforce the branch+PR loop): pure docs-only tweaks (CLAUDE.md, README, docs/*), trivial typo fixes, or explicitly user-driven hot-fixes can go straight on `master`. When in doubt, branch.

## Local multi-BEAM setup

Hub + worker run in **separate** BEAMs locally because each owns its own Mnesia schema. Schemas are node-name-bound — start each BEAM with the sname matching the schema in its data directory.

- **Hub** (no sname → `nonode@nohost`): `cd apps/hub && mix phx.server` — uses `priv/mnesia/dev/`.
- **Worker against local hub** (sname `worker`): `cd apps/worker && LORE_MNESIA_DIR=$(pwd)/../../priv/mnesia/dev-worker elixir --sname worker --no-halt -S mix run`.
- **Worker against gigalixir prod hub** (sname `worker_prod`): same but with `LORE_MNESIA_DIR=…/prod-worker` and `HUB_BASE_URL=https://loretracker.gigalixirapp.com`.

Dev-only HTTP endpoint `POST /dev/event` (mounted only in `:dev`/`:test`) accepts `%{"payload" => map}` and appends the payload raw to the event log — used by `mix lore.fake_session` and ad-hoc seeding scripts.
