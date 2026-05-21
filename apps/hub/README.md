# Hub

Web-Frontend + Event-Log-Backend von LoreTracker. Phoenix-LiveView-Anwendung — hosted Kampagnen, zeigt Transkripte und Resümees / Epos / Chronik, verwaltet User-Pairing und Worker-Connections.

## Komponenten

- **`HubWeb.Endpoint`** — Phoenix-Endpoint (Bandit). Auf `:4000` in Dev, gigalixir-deployed in Prod.
- **`Hub.EventLog`** — Append-only Event-Store. Adapter: Mnesia (Dev, file-backed) oder Postgres (Prod via Ecto). Steuerbar via `Application.get_env(:hub, :storage_backend)`.
- **`Hub.WorkerTokens`** — Pairing-Tokens für Worker-Sockets, gleiche Adapter-Logik wie EventLog.
- **`Hub.Reader`** — Liest materialisierte Snapshots vom verbundenen Worker via `snapshot_request`/`snapshot_response`-Wire-Calls.
- **`HubWeb.WorkerChannel`** — Phoenix-Channel für die Worker-Slipstream-Connection (Topic `worker:<worker_id>`).

## Deploy

`mix release.hub` baut die Prod-Release (hub + shared, ohne worker). Buildpack-Konfig in `elixir_buildpack.config` + `phoenix_static_buildpack.config`. Deploy via `git push gigalixir HEAD:refs/heads/master` (manuell, weil Woodpecker per Issue #31 noch nicht aktiv).

## Mehr

Siehe Root-[`README.md`](../../README.md) und [`CLAUDE.md`](../../CLAUDE.md).
