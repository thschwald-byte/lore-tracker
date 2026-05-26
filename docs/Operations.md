# Operations (Prod)

Betriebshandbuch für die gigalixir-Hub-Instanz. Behandelt Logs, Telemetry-Queries, Log-Drains, Rollback. Komplementär zu `docs/Worker-Setup.md` (lokales Worker-Setup) und `docs/Performance.md` (Mess-Baselines).

> **Stichtag**: 2026-05-26 (initiale Version aus Issue #238 Phase 1+2)
> **Prod-App**: `loretracker` auf gigalixir, URL https://loretracker.gigalixirapp.com

## Logs anschauen

Live-Tail:
```bash
gigalixir logs -a loretracker -f
```

Rolling-Buffer ohne `-f` (letzte ~1500 Lines):
```bash
gigalixir logs -a loretracker | tail -200
```

## Telemetry-Events grepen

Issue #238 Phase 1 hat strukturierte Logger-Lines eingeführt (`Hub.Telemetry`). Format pro Event:

```
[info] [telemetry] event=<dot.notation> key1=value1 key2=value2 ...
```

Verfügbare Events:

| Event | Felder | Zweck |
|---|---|---|
| `phoenix.endpoint.stop` | method, route, status, duration_ms | HTTP-Request done |
| `phoenix.live_view.mount.stop` | lv, duration_ms | LiveView-Mount |
| `phoenix.live_view.handle_event.stop` | lv, event, duration_ms | LV-handle_event |
| `phoenix.channel_joined` | channel, topic, result | Channel-Join |
| `phoenix.channel_handled_in` | channel, topic, event, duration_ms | Channel-Message |
| `hub.event_bridge.publish` | kind, campaign_id, result, duration_ms | Bridge-Publish (`ok` \| `no_worker_online`) |
| `hub.worker_registry.changed` | joins, leaves | Worker-(Re)Connects |

### Typische Queries

**Wie oft scheitert ein Bridge-Publish wegen `no_worker_online`?**
```bash
gigalixir logs -a loretracker | grep "[telemetry] event=hub.event_bridge.publish result=no_worker_online" | wc -l
```

**Welche LiveViews haben die langsamsten Mounts?**
```bash
gigalixir logs -a loretracker | grep "phoenix.live_view.mount.stop" | awk -F"duration_ms=" '{print $2" "$0}' | sort -rn | head -10
```

**Welche HTTP-Endpoints schmeißen 500?**
```bash
gigalixir logs -a loretracker | grep "phoenix.endpoint.stop status=5"
```

**Worker-Reconnects über die letzte Stunde:**
```bash
gigalixir logs -a loretracker | grep "hub.worker_registry.changed"
```

## Log-Drain (Phase 2)

Der gigalixir-Logs-Rolling-Buffer ist ca. **31 h** breit. Für längere History oder Volltextsuche → externer Drain.

### Setup (einmalig)

Empfehlung: **Papertrail** (Solarwinds, gigalixir-Standard, Free-Tier 7 Tage / 50 MB/Monat). Andere Optionen: Logtail/Better Stack (30 Tage / 1 GB/Monat free) oder eigener Vector/Loki/Logstash auf einem cheap VPS.

```bash
# 1. Account anlegen unter https://papertrailapp.com/
# 2. Im Papertrail-Dashboard "Add System" → "Logs from a remote system" wählen
#    → Endpoint kopieren (Format: logsN.papertrailapp.com:NNNNN)
# 3. Drain in gigalixir konfigurieren:
gigalixir drains:add -a loretracker syslog+tls://logsN.papertrailapp.com:NNNNN

# Bestehende Drains listen:
gigalixir drains -a loretracker

# Drain entfernen:
gigalixir drains:remove -a loretracker <drain-id>
```

### Drain im Browser

Papertrail-UI hat:
- **Live-Tail** (analog `gigalixir logs -f`)
- **Volltextsuche** über alle gedrainten Lines
- **Saved Searches** für die typischen Queries oben
- **Alerts**: z.B. „mehr als 5x `no_worker_online` in 5 Min" als Notification

Empfohlene Saved Searches:
1. `[telemetry] event=hub.event_bridge.publish result=no_worker_online`
2. `[telemetry] event=phoenix.endpoint.stop status=5`
3. `[telemetry] event=hub.worker_registry.changed`
4. `Pipeline: starting stages` (Worker-side, wenn Worker-Logs auch gedraint sind)

## Rollback + Restart

Wenn ein Deploy was bricht:

```bash
gigalixir releases -a loretracker                 # alle Releases listen
gigalixir releases:rollback -a loretracker        # auf voriges Release
gigalixir releases:rollback -a loretracker --version <N>  # specific Version

gigalixir ps -a loretracker                       # Replica-Status
gigalixir ps:restart -a loretracker               # soft-restart aller Replicas
```

CLI-Voraussetzung: `pip install gigalixir` + `gigalixir login -e $EMAIL -k $API_KEY` (Credentials liegen in den Codeberg-CI-Secrets).

## Was NICHT abgedeckt ist

- **Grafana-Dashboards** — Drain + Search-UI reichen für jetzt. Wenn jemand quantitative Trends will, separates Issue.
- **Prometheus-`/metrics`-Endpoint** — schwerer, braucht laufende Aggregation. Erst relevant wenn n>5 Self-Host-Instanzen vergleichende Metriken wollen.
- **OpenTelemetry-Tracing** — overkill für aktuelle Skalierung.
- **Sentry für Errors** — separates Issue (#68 für Self-Host-Error-UI).

## Verwandte Issues

- **#238** (dieses Doc): Hub-Telemetry + Log-Drain — Phase 1+2.
- **#68** (open): Error-Logging + Troubleshooting-UI für Self-Hosted-Worker.
- **#231** (closed): Worker-Stage-1-Logger.info — orthogonal, Worker-Side.
