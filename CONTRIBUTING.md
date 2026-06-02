# Contributing to LoreTracker

Vielen Dank, dass du mitmachen willst. Diese Datei hilft dir, dich im Repo zurechtzufinden, Änderungen einzureichen und während der Arbeit zu debuggen.

**Für die lokale Einrichtung** (Erlang, Whisper, Ollama, Pairing-Flow) schau zuerst in [`docs/Worker-Setup.md`](docs/Worker-Setup.md) — die Voraussetzungen und Erst-Start-Schritte werden dort einmal sauber beschrieben und nicht hier dupliziert.

## Repo-Layout im Schnelldurchlauf

Umbrella mit drei Apps (`apps/shared` / `apps/hub` / `apps/worker`). Hub ist die Phoenix-LiveView-Webanwendung, Worker läuft lokal beim Spielleiter und kümmert sich um Audio / Whisper / lokale LLM-Stages. Beide BEAMs reden über einen Append-only EventLog mit eigenem PubSub-Pattern. Architektur-Details und das Mnesia-vs-Postgres-Adapter-Modell stehen in [`CLAUDE.md`](CLAUDE.md) im Repo-Root.

## Licensing of contributions

LoreTracker is released under the **PolyForm Noncommercial License 1.0.0** (see [`LICENSE`](LICENSE)), with the maintainer also offering it under a separate commercial license (see [`LICENSE-COMMERCIAL.md`](LICENSE-COMMERCIAL.md)).

**By submitting a contribution** (pull request, patch, suggestion that gets incorporated into the codebase, etc.), you agree that:

1. Your contribution is licensed to the project under the **PolyForm Noncommercial License 1.0.0** on the same terms as the rest of the project.
2. You **grant the maintainer (Thomas Falk) the perpetual, worldwide, royalty-free right to relicense your contribution under any other license**, including commercial licenses, at the maintainer's sole discretion.
3. You have the legal right to make the contribution and grant these rights (i.e., the code is yours, or you have your employer's permission, etc.).
4. Your contribution is provided **as is**, with no warranty.

If you cannot agree to these terms, please do not submit a contribution. If anything is unclear, open an issue first and we'll talk it through.

## Issue-First-Workflow

Jede Code-Änderung hängt an einem Issue und bekommt einen eigenen Branch. Ausnahmen: reine Doku-Tweaks, Typo-Fixes, explizit angefragte Hot-Fixes.

1. **Issue finden oder anlegen.** Tracker: <https://codeberg.org/tomloresys/lore-tracker/issues>

   ```bash
   tea issues list -r tomloresys/lore-tracker --state open
   tea issues create -r tomloresys/lore-tracker -t "<titel>" -d "<body>" -L "<label-csv>" -m "<milestone>"
   ```

   Jedes neue Issue bekommt mindestens ein Label (`feature` oder `bug` + optionale Domain: `llm` / `ui` / `audio` / `infra` / `docs` / `permission` / `mobile` / `i18n` / `architecture` / `live-transcription`). Ungelabelte Issues fallen aus der Filterbarkeit raus.

2. **Branch nach Schema** `issue-<N>-<short-slug>` (z.B. `issue-12-export-markdown`). Genau ein Branch pro Issue. Niemals direkt auf `master`.

3. **Commits** schreibst du jedes Mal, wenn der Code sauber kompiliert. Kleine, fokussierte Commits sind besser als ein großer WIP-Klumpen. Commit-Message-Stil: `issue #<N>: <kurzbeschreibung>`.

4. **Doku mit-pflegen** (siehe Definition of Done unten).

5. **Pull Request** gegen `master` via `tea pulls create` oder Codeberg-Web-UI. Beschreibe was geändert wurde, wie verifiziert, was bewusst offen bleibt.

## Definition of Done

Ein PR ist mergebereit, wenn:

- [ ] **`mix format`** ist gelaufen (kanonisch, kein Diskussionsthema).
- [ ] **`mix compile` ohne neue Warnings** für die geänderten Dateien.
- [ ] **Tests grün.** `mix test` läuft durch (Postgres-Tests optional, siehe unten). Bei neuer Funktionalität: relevante Tests **im selben PR** mit-geliefert.
- [ ] **Doku-Drift gefixt.** Wenn dein PR eine Aussage in einem dieser Files veraltet hat, wird die Doku **im selben PR** mit-aktualisiert:
   - [`CONTRIBUTING.md`](CONTRIBUTING.md) — diese Datei (Test-Commands, Debug-Patterns, Workflow-Schritte).
   - [`CLAUDE.md`](CLAUDE.md) — Architektur, Workflow für Claude Code, Storage, Deploy.
   - [`README.md`](README.md) — Repo-Überblick, Quick-Start, License-Hinweise.
   - [`docs/Worker-Setup.md`](docs/Worker-Setup.md) — Voraussetzungen, Pairing-Flow, Troubleshooting-Tabelle.
   - [`docs/Spieler-Anleitung.md`](docs/Spieler-Anleitung.md) — End-User-Sicht aufs Browser-UI.
   - [`docs/Backup-Recovery.md`](docs/Backup-Recovery.md) — Backup-Workflow, Mix-Tasks (`lore.backup` / `lore.restore`), Hub-Endpoint, Gigalixir-Prod-Pfad, Disaster-Recovery-Checkliste.
   - `@moduledoc` / `@doc`-Strings für berührte Module, wenn die Aussagen nicht mehr stimmen.
   Faustregel: wenn ein bestehender Doku-Satz nach deinem PR nicht mehr stimmt, ist es Teil deines PRs, ihn zu fixen.
- [ ] **Code-Hygiene.** Keine `IO.inspect`-Reste, keine kommentierten Code-Blöcke, keine ad-hoc Print-Debugs.
- [ ] **Permissions / Auth nicht aufgeweicht.** Änderungen an `Hub.Permissions` o.ä. werden im PR-Body explizit benannt.

## Tests laufen lassen

```bash
mix test                                      # umbrella-weit
mix cmd --app hub mix test                    # nur die Hub-Tests
mix test apps/hub/test/hub_test.exs:5         # einzelner Test per file:line
mix test --include postgres                   # Postgres-Adapter-Tests dazu
```

Postgres-Tests sind per Default ausgeschlossen, weil sie eine erreichbare Postgres-Instanz brauchen (Creds via Env: `POSTGRES_HOST` / `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB`, Defaults in `config/test.exs`). Lokal einmalig vorbereiten: `mix ecto.create && mix ecto.migrate`.

Wenn dein Test ad-hoc Daten braucht, lade die Romeo-Demo-Kampagne in einen frischen Hub:

```bash
mix lore.seed.romeo            # voll-bestückte 5-Akt-Kampagne ins lokale dev-Hub
mix lore.seed.romeo --reset    # vorher löschen, dann neu laden (idempotent)
```

Das Mix-Task arbeitet via HTTP-POST gegen `/dev/event` — Hub muss vorher laufen, Worker auch (für Materializer-Apply). Refuses `MIX_ENV=prod`.

### Test-Helpers + Fixtures (Issue #66)

Neue Tests sollen **<50 Setup-Zeilen** brauchen, nicht 200+. Dafür gibt es geteilte Helper unter `apps/*/test/support/`:

**Worker** (`Worker.TestHelper`, `import Worker.TestHelper`):

- `build_campaign(opts)` — baut die volle Event-Sequenz für N Sessions × M Utterances (`CampaignCreated → AdminMemberAdded* → SessionScheduled → SessionStarted → UtteranceAppended*`). Opts u.a. `:campaign_id`, `:members`, `:sessions` (Integer N **oder** Liste von Utterance-Counts), `:include_summaries?`, `:apply` (materialisiert via `Materializer.apply_batch/1`). Gibt `%{campaign_id, sessions: [%{id, utterance_ids}], events}` zurück.
- `event/4`, `ensure_materializer!/0`, `clear_all_tables!/0` — Event-Builder + Lifecycle/Cleanup.
- `Worker.Schema.Builder` — Mnesia-Tuple-Builder für Pre-Seed direkt in die Tabellen.

**Hub** (`use HubWeb.ConnCase` für conn/LiveView-Tests):

- `HubWeb.Fixtures.user/1` — User-Map (`role`/`campaign_role`/`is_member?` + `discord_id`/`display_name`), für `HubWeb.Permissions.can?/3`-Subjekt **und** Session-Login.
- `HubWeb.Fixtures.snapshot/1` + `member/2` — string-keyed Worker-Snapshot für `CampaignLive.derive_assigns/2` und LiveView-Mounts.
- `log_in(conn, user)` — schreibt den Session-`current_user` (passiert den `:require_user`-Plug).
- `stub_reader!(snapshot)` — ersetzt den supervisten `Hub.Reader` für die Testdauer durch `HubWeb.ReaderStub`, sodass LiveViews **ohne echten Worker** mounten. Macht den Test `async: false`.

Beispiel-LV-Mount-Test: `apps/hub/test/hub_web/campaign_live_mount_test.exs`.

### Coverage

```bash
mix test --cover                              # eingebauter Coverage-Report pro Modul
mix cmd --app worker mix test --cover         # nur eine App
```

Richtwert: **>70%** für die kritischen Pfade `Worker.Materializer`, `Worker.Repo`, `Hub.EventBridge`, `HubWeb.Permissions`; andere Module lockerer. Die Schwelle ist heute **nicht** hart erzwungen — eine echte Coverage-Gate (ExCoveralls + Required-Status-Check + Coverage-Diff-Bot) folgt mit der CI-Aktivierung (Phase 3, hängt an #31), weil sie ohne CI keinen Durchsetzungspunkt hat.

## Debug-Patterns

### Hub-EventLog inspizieren

In einer Shell `mix phx.server` starten, in einer zweiten `iex -S mix` (oder im laufenden iex):

```elixir
Hub.EventLog.head()                       # höchste seq (= Anzahl Events)
Hub.EventLog.stream(0) |> Enum.take(5)    # erste 5 Events ab Anfang
Hub.EventLog.stream(100) |> length()      # wie viele seit seq 100?
```

Bei `LORE_STORAGE_BACKEND=postgres` (Prod-Setup) dispatcht `Hub.EventLog` automatisch auf den Postgres-Adapter — Aufrufe bleiben identisch.

### Worker-Materializer-Tabellen inspizieren

Im **Worker**-BEAM (sname `worker` oder `worker_prod`):

```elixir
Worker.Repo.all_campaigns()                                # alle Kampagnen
Worker.Repo.list_sessions("romeo-julia-demo")              # Sessions einer Kampagne
Worker.Repo.list_utterances("session-romeo-akt-1")         # Utterances einer Session
Worker.Repo.list_chronik_entries("romeo-julia-demo")       # Chronik-Einträge
Worker.Repo.get_session_summary("session-romeo-akt-1")     # einzelnes Resümee
Worker.Repo.get_epos_entry("romeo-julia-demo")             # Epos-Dokument
Worker.Repo.list_members("romeo-julia-demo")               # Campaign-Members
Worker.Repo.list_invites("romeo-julia-demo")               # Invites (aktiv + verbraucht)
```

Für Roh-Zugriff (Felder die der Materializer nicht eigens ausliefert):

```elixir
:mnesia.dirty_select(:worker_sessions, [{:_, [], [:"$_"]}])
```

### LLM-Pipeline manuell triggern

Für nachträglich-importierte oder geseedete Sessions feuert die Pipeline nicht von allein. Manuell anwerfen (im Worker-BEAM) — seit Issue #121 als direkter Call ohne Hub-Roundtrip:

```elixir
Worker.Recording.Pipeline.run_for_session("session-romeo-akt-1")
```

Den `Worker.Recording.Pipeline`-State kannst du live beobachten:

```elixir
:sys.get_state(Worker.Recording.Pipeline).running   # Map %{session_id => stage}
```

Leerer State = nichts läuft mehr. Mehr Hintergrund (PubSub-Completion-Signal, Owner-Worker-Constraint) in [`CLAUDE.md`](CLAUDE.md) → „LLM-Pipeline-Backfill für nachgereichte Sessions".

### Test-Events direkt am Hub einspeisen (nur dev)

In `:dev` und `:test` ist `POST /dev/event` aktiv:

```bash
curl -sS http://localhost:4000/dev/event \
  -H 'content-type: application/json' \
  -d '{"payload":{"kind":"...","..."}}'
```

Wird von `mix lore.fake_session` und `mix lore.seed.romeo` benutzt. In Prod existiert die Route nicht (404).

## Cloud-LLM-Backends (optional)

Wenn du Cloud-Backends (Anthropic, später OpenAI/Google — Issue #27) nutzen willst:

1. Master-Key für Key-Verschlüsselung generieren und in `.env` ablegen:
   ```bash
   echo "LORE_CLOAK_KEY=$(openssl rand -base64 32)" >> .env
   ```
   Der Key ver-/entschlüsselt die API-Keys at-rest (AES-GCM via Cloak). **Wenn du den Key verlierst, sind die gespeicherten API-Keys unwiederbringlich** — neu eingeben.
2. Hub starten und unter `/admin/cloud-keys` (nur `:admin`-Rolle) den Provider-API-Key eintragen — wird sofort verschlüsselt persistiert.
3. In `/settings` pro Stage das Backend auf `Anthropic (Claude via Hub-Proxy)` stellen + ein Modell aus `Worker.LLM.Anthropic.models/0` ins Modellfeld eintragen.

Ohne `LORE_CLOAK_KEY` läuft der Vault mit einem **ephemeren In-Memory-Key**, also gehen gespeicherte Cloud-Keys beim nächsten Hub-Restart verloren — nur OK für `:dev`/`:test`.

## Troubleshooting

Die häufigsten Stolpersteine — Mnesia-Schema-Mismatch beim Worker-Start, Pairing-Flow steckt, Whisper findet kein Modell, LLM-Stage hängt — sind in [`docs/Worker-Setup.md`](docs/Worker-Setup.md#6-troubleshooting) tabellarisch beschrieben. Für LLM-Pipeline-Robustheit gegen problematische Modelle (Thinking-Modus, große Prompts, HTTP-Timeouts) siehe [`CLAUDE.md`](CLAUDE.md) → „Modell-Inkompatibilitäten + Pipeline-Robustheit". Daten retten / wiederherstellen: [`docs/Backup-Recovery.md`](docs/Backup-Recovery.md).

## Code style

- Follow standard Elixir / Phoenix conventions.
- `mix format` is canonical — no debate.
- Keep modules in the right umbrella app (`hub`, `worker`, `shared`).
- Document non-obvious *why* in comments, not *what*.

## Questions

Open an issue or email <thschwald@gmail.com>.
