# Hub

Web-Frontend + Event-Log-Backend von LoreTracker. Phoenix-LiveView-Anwendung — hosted Kampagnen, zeigt Transkripte und Resümees / Epos / Chronik, verwaltet User-Pairing und Worker-Connections.

## Komponenten

- **`HubWeb.Endpoint`** — Phoenix-Endpoint (Bandit). Auf `:4000` in Dev, gigalixir-deployed in Prod.
- **`Hub.Events`** — Stateless PubSub-Schiene für Event-Broadcasts (seit Etappe 4c.4 keine eigene `events`-Tabelle mehr — kanonisch leben Events in den Workern).
- **`Hub.EventBridge`** — Hub-LV/Controllers delegieren Event-Erzeugung an einen online Worker (Worker-First-Apply + sync zurück).
- **`Hub.WorkerJWT`** — RFC-7519-JWT (HS256) für stateless Pairing/Channel-Auth (seit Etappe 5a kein DB-Lookup mehr).
- **`Hub.Reader`** — Liest materialisierte Snapshots vom verbundenen Worker via `snapshot_request`/`snapshot_response`-Wire-Calls.
- **`HubWeb.WorkerChannel`** — Phoenix-Channel für die Worker-Slipstream-Connection (Topic `worker:<worker_id>`).

## Deploy

`mix release.hub` baut die Prod-Release (hub + shared, ohne worker). Buildpack-Konfig in `elixir_buildpack.config` + `phoenix_static_buildpack.config`. Deploy läuft seit Issue #31 automatisch über Codeberg-Woodpecker bei jedem `master`-Push zu Gigalixir — kein manueller `git push gigalixir` mehr nötig.

## Mehr

Siehe Root-[`README.md`](../../README.md) und [`CLAUDE.md`](../../CLAUDE.md).
