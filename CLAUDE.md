# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status

Freshly scaffolded Elixir umbrella project. All three apps (`hub`, `worker`, `shared`) currently contain only the default `mix new` stubs (`hello/0` returning `:world`). There is no real implementation, no dependencies declared, and the root `README.md` and root `config/config.exs` are placeholders. Treat any architectural decisions as still open.

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
