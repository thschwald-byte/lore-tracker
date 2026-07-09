# Contributing to LoreTracker

Vielen Dank, dass du mitmachen willst. Diese Datei hilft dir, dich im Repo zurechtzufinden, Änderungen einzureichen und während der Arbeit zu debuggen.

**Für die lokale Einrichtung** (Erlang, Whisper, Ollama, Pairing-Flow) schau zuerst in [`docs/Worker-Setup.md`](docs/Worker-Setup.md) — die Voraussetzungen und Erst-Start-Schritte werden dort einmal sauber beschrieben und nicht hier dupliziert.

## Repo-Layout im Schnelldurchlauf

Umbrella mit drei Apps (`apps/shared` / `apps/hub` / `apps/worker`). Hub ist die Phoenix-LiveView-Webanwendung, Worker läuft lokal beim Spielleiter und kümmert sich um Audio / Whisper / lokale LLM-Stages. Beide BEAMs reden über einen Append-only EventLog mit eigenem PubSub-Pattern. Architektur-Details und das Mnesia-vs-Postgres-Adapter-Modell stehen in [`CLAUDE.md`](CLAUDE.md) im Repo-Root.

## Licensing of contributions

LoreTracker is released under the **GNU Affero General Public License v3.0 (AGPL-3.0)** (see [`LICENSE`](LICENSE)), with the maintainer also offering it under a separate commercial license (see [`LICENSE-COMMERCIAL.md`](LICENSE-COMMERCIAL.md)).

**By submitting a contribution** (pull request, patch, suggestion that gets incorporated into the codebase, etc.), you agree that:

1. Your contribution is licensed to the project under the **GNU Affero General Public License v3.0 (AGPL-3.0)** on the same terms as the rest of the project.
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
- [ ] **`mix credo`** ohne neue Findings für die geänderten Dateien (Issue #544 — AST-Linter gegen die Anti-Pattern-Klassen; siehe Block unten).
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

Beim Öffnen eines Pull-Requests befüllt Codeberg automatisch das Template aus `.codeberg/pull_request_template.md` (Issue #536) — die Risiko-Checks dort sind die Lang-Form derselben Liste plus die spezifischen Pattern aus der Code-Review (neue `apply_kind/4`-Klausel braucht Test, neuer `Task.start/1` muss try/rescue haben, etc.). Bitte ausfüllen statt löschen.

## `mix credo` — AST-Linter gegen die Anti-Pattern-Klassen

Issue #544. Statische AST-Analyse gegen die Bug-Klassen, die in der Code-Review (2026-06-04) als wiederkehrend identifiziert wurden. Löste den Regex-basierten `mix lore.audit` (#535) ab — AST statt Grep, weil „blockiert dieser Read die GUI?" / „ist das ein echter Producer?" Bedeutung ist, kein Text (Regex sah weder `start_async`-Wrapper noch `@moduledoc`-Kontext → die FPs waren *eingebaut*, vgl. #549/#557).

Sechs Custom-Checks (`tools/credo/*.ex`, via `.credo.exs` `requires:` geladen — kein App-Compile):

1. **`UnsupervisedTaskStart`** — `Task.start/1` (nicht `start_link`/`Supervisor`); Crash wird still verschluckt. Mix-Tasks exempt.
2. **`SyncReaderInMount`** — sync `Reader.read/2` im LiveView; blockiert die GUI bis 15 s. Exempt't `start_async`/`assign_async`/`Task.*`-gewrappte Reads **strukturell** (AST, inkl. multi-line/piped). Korrekt: `assign_async`/`start_async`.
3. **`HardcodedEventKind`** — `%{"kind" => "<Pascal>"}` außer in `Shared.Events`/`Materializer`; Drift-Risiko. Korrekt: `Shared.Events.foo()`.
4. **`TimerWithoutCleanup`** — `Process.send_after(self(), …)` ohne `Process.cancel_timer` im File; Zombie-Timer nach Restart.
5. **`IgnoredIntentsPublish`** — `Worker.Intents.publish/1` als verworfenes (nicht-letztes) `__block__`-Statement; `{:ok, :pending}` bei Hub-Disconnect geht still verloren.
6. **`ModuleTooLong`** — File über `:max_lines` (Default 1000); God-Module-Refactoring-Kandidat.

### Aufruf

```bash
mix credo --checks LoreTracker.Credo.Check                                   # alle 6, ganzes Repo
mix credo diff --from-git-merge-base origin/master --checks LoreTracker.Credo.Check   # nur was DIESER Branch neu hinzufügt
```

### Mechanik — Diff-Scope (Clean-as-You-Code)

CI fährt **`credo diff --from-git-merge-base origin/master`**: geflaggt wird nur, was der aktuelle Branch ggü. seinem Abzweigpunkt von master NEU hinzufügt (exit 16 bei added, 0 sonst). Der bestehende Backlog blockt nie — **kein alterndes Baseline-File** (das hatte die Staleness-Eigenschaft, #557-Befund #3), sondern Diff-Scope (SonarQube „Clean as You Code"). Zugleich FP-Containment: alte (ggf. False-)Positives werden nicht mehr gescannt.

**Warn-Mode (default)**: der CI-Step ist `failure: ignore` (#557-Lesson: erst beobachten, dann blockieren — Sadowski et al. CACM 2018 zeigen, dass blocking gates effektiv 0 % FP brauchen, sonst werden sie ignoriert). Blocking-Flip = `failure: ignore` aus dem credo-Step entfernen.

### Was tun bei einem Hit?

- **Erste Wahl**: das Pattern fixen — die Klassen sind real-world Bug-Quellen, nicht akademisch.
- **Wenn der Hit legitim ist** (bewusstes fire-and-forget, intentionaler Mount-Load): `# credo:disable-for-this-line CheckName` mit Begründung; im PR-Body erklären WARUM der Hit OK ist.
- **Wenn der Hit eine Falsch-Erkennung** ist: den Check in `tools/credo/<check>.ex` schärfen + einen `refute_issues`-Fixture-Test in `apps/hub/test/credo/` ergänzen, der den FP einsperrt — die Falsch-Erkennung ist ein Bug des Checks selbst (jeder historische FP wird ein bleibender Negativ-Test).

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

Stand der vier Zielmodule (gemessen 2026-06-03, nach dem Coverage-Followup zu #66):

| Modul | Coverage | Ziel |
|---|---|---|
| `Hub.EventBridge` | ~94% | ✅ |
| `HubWeb.Permissions` | ~89% | ✅ |
| `Worker.Materializer` | ~74% | ✅ |
| `Worker.Repo` | ~70% | ✅ |

Alle vier kritischen Module liegen über dem 70%-Richtwert. Beim großen `Worker.Repo` (~1300 Zeilen) bleibt nur die `jobs`-`snapshot`-Klausel (`Worker.GpuQueue`-abhängig) und die Ollama-gebundenen `settings`/`probelauf`-`snapshot`-Pfade ungedeckt — bewusst, weil sie netz-/prozess-abhängig sind und keine reinen Read-Logik-Pfade.

### Coverage-Floor (`ExCoveralls` + `mix lore.coverage_floor`, Issue #537)

Der 70%-Richtwert oben war bis #537 **nicht durchgesetzt** — neue Funktionen
konnten ohne Tests einfließen, der Backfill rutschte in die Zukunft. `ExCoveralls`
liefert jetzt den Report, `mix lore.coverage_floor` erzwingt **pro kritischem
Modul** einen Floor (ExCoveralls selbst kennt nur einen *globalen*
`minimum_coverage`):

```bash
cd apps/hub    && MIX_ENV=test mix coveralls.json   # → apps/hub/cover/excoveralls.json
cd apps/worker && MIX_ENV=test mix coveralls.json   # → apps/worker/cover/excoveralls.json
mix lore.coverage_floor                             # vom Umbrella-Root; exit 1 bei Riss
mix lore.coverage_floor --bump                      # druckt aktuelle Werte als Floor-Vorschlag
```

CI-Step `coverage` (`.woodpecker/woodpecker.yml`) — vorerst **`failure: ignore`** (WARN-Soak
wie credo/dialyzer, #557-Lesson). Blocking-Flip = nur das `failure: ignore`
entfernen.

**Ratchet, nicht Aspiration.** Die Floors (in `lore.coverage_floor.ex`) sitzen
knapp **unter der heutigen Coverage**, nicht auf den #537-Zielwerten (Commands
70%, Pipeline 60%, ApiKey 90% …) — die brauchen erst Test-Backfill und würden das
Gate sofort reißen. Der Ratchet erfüllt den Kern (Coverage fällt → CI-Hit) und
verhindert Drift. Heutige Floors: Permissions 80 · EventBridge 88 · Commands 30 ·
Materializer 70 · Pipeline 35 · Repo 68 · CloudHelper 60. `ApiKey` ist (noch) nicht
gefloort — 0% Suite-Coverage, ein Floor wird erst nach initialen Tests sinnvoll.

**Wie hebt man den Floor:** neuer Code in einem kritischen Modul = Tests
**zusätzlich**, nicht ersatzweise. Steigt die Coverage durch Backfill, den Floor in
`lore.coverage_floor.ex` mit-anheben (`--bump` liefert den Vorschlag) — so ratscht
die Mindest-Härte nur nach oben.

### Mutation-Testing (`muex`, Issue #546)

**Coverage ≠ Assertion-Qualität.** Eine Zeile „ausgeführt" heißt nicht „ihr Bug
würde gefangen" — die 2026-06-04-Review (#508) hat das gezeigt (nominal grüne
Metrik, die Müll maß). **Coverage-Floor (#537) + Mutation-Score = echte
Test-Härte.**

[`muex`](https://hex.pm/packages/muex) mutiert den Code (Operator flippen, Return
ändern, Klausel droppen) und prüft, ob die Suite die Mutation **fängt** (Test wird
rot). Überlebende Mutanten = Lücken, die ein Coverage-Report NICHT sieht (Zeile
ausgeführt, aber nicht assertet). dev-only Dep in `hub` + `worker`.

> **Warum `muex` und nicht `muzak`?** `muzak` (free) ist **CC-BY-NC-4.0** —
> non-commercial, inkompatibel mit dem AGPL+Dual-License-Modell dieses Repos
> ([#477](https://codeberg.org/tomloresys/lore-tracker/issues/477)); `muzak_pro`
> ist kommerziell. `muex` ist **MIT** → FOSS-kompatibel.

**Kein hartes CI-Gate** — ein voller Lauf ist zu langsam (Suite läuft pro Mutant
neu). Stattdessen periodisch / lokal auf die kritischen Module; überlebende
Mutanten sind Test-Backlog. Scoped Aufruf (Modul + zugehöriger Test):

```bash
# Hub-Hotspot — Permissions:
cd apps/hub && mix muex --files "lib/hub_web/permissions.ex" \
  --test-paths "test/hub_web/permissions_test.exs"

# Worker-Hotspots — CloudHelper / Materializer / Pipeline:
cd apps/worker && mix muex --files "lib/worker/llm/cloud_helper.ex" \
  --test-paths "test/worker/llm/cloud_helper_test.exs"
cd apps/worker && mix muex --files "lib/worker/materializer*" --max-mutations 50
```

Nützliche Flags: `--max-mutations N` (kappt für schnelle Läufe), `--fail-at SCORE`
(Mindest-Score), `--format json|html`, `--app <name>` (Umbrella-Targeting). Default-
Mutators + intelligentes File-Filtering sind aktiv; `--no-filter`/`--no-optimize`
für vollständige Läufe. **Caveat** (`muex`-README): macro-lastige Module (Phoenix-
LiveViews) + sehr große Test-Suites sind langsamer/ungenauer — die genannten
Hotspots (plain Elixir) sind die ergiebigsten Ziele.

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

## Iron Laws — lore-iron-laws-Subagent

Issue #536. Für Claude-Code-Sessions im Repo gibt es einen `lore-iron-laws`-Subagent (`.claude/agents/lore-iron-laws.md`), der nach Änderungen an `lib/` proaktiv getriggert wird und das Repo gegen **10 fokussierte Anti-Pattern** scant:

1. `String.to_atom/1` mit User-Input (Atom-Table-DoS)
2. `raw(@var)` mit nicht-statischem Argument (XSS)
3. `Phoenix.PubSub.subscribe/2` ohne `connected?`-Guard im mount
4. Server-State-Calls (`Worker.Repo.*`, `Reader.read`, `:rpc.call`) im disconnected mount ohne Guard
5. `handle_event` mit Server-Side-Effect ohne `HubWeb.Permissions.can?`-Check
6. `onclick="event.stopPropagation()"` in HEEx-Modals (killt `phx-click`-Delegation)
7. `Process.send_after(self(), …)` ohne `Process.cancel_timer` im selben File (Timer-Leak)
8. Hardcoded Event-Kind-Strings in Pattern-Matches (Drift-Risiko, Issue #471)
9. Unsupervised `Task.start/1` in Hot-Pfaden (silent crash, Pipeline-Deadlock)
10. Ignorierter `Worker.Intents.publish/1`-Return (Pending-Backlog unsichtbar)

Der Agent liest nur (Read/Grep/Glob), schreibt keinen Code. Output: priorisierte Liste mit `file:line` + Fix-Vorschlag pro Verstoß. Regeln #4 + #7-10 sind die mechanisch greppbaren — `mix credo` (Issue #544) macht den mechanischen Anteil. Der Agent fokussiert auf die schwer greppbaren Klauseln (Context-Awareness, Race-Windows, Auth-Logik im handle_event-Body).

## Regeln für Regeln

Issue #557. Die Prävention-Tooling-Welle vom 2026-06-04 (`mix lore.audit` #535, Iron-Laws-Subagent #536, Folge-Issues #539–#543) hat **selbst Bugs produziert**, die zweimal master-CI rot gefärbt haben (Regex-Lints flaggten korrekten Code; ein Iron-Law-Fix kompilierte nicht; der Regel-Test lief nirgends). Damit der nächste Regel-Batch nicht denselben Weg geht, gilt für jede neue Code-Regel (Audit-Check, Credo-Custom-Check, Iron-Law-Klausel, CI-Gate):

### Leitlinien

1. **Keine Regel ohne rot/grün-Fixture.** Vor dem Merge eines neuen Checks muss eine `bad.ex`-Fixture die Regel **auslösen** und eine `good.ex`-Fixture **nicht** auslösen. Konvention etabliert durch Credo-Cut 2 (#563, `apps/hub/test/credo/ported_checks_test.exs`). ([Juliet Test Suite](https://samate.nist.gov/SARD/test-suites) als Industrie-Referenz für Static-Analyzer-Testing.)
2. **Neue Gates starten warn-only.** Erst nach FP-freier Soak-Phase auf `--strict` / `failure: stop` umschalten. Effektiv 0% FP ist die Schwelle für blocking gates — andernfalls werden sie ignoriert oder mit Allowlists durchlöchert. ([Sadowski et al. CACM 2018](https://m-cacm.acm.org/magazines/2018/4/226371-lessons-from-building-static-analysis-tools-at-google/fulltext), Erfahrung Google-Tricorder.) Praktischer Default für `mix credo` (#544, `failure: ignore`).
3. **Diff-scoped Enforcement schlagen Whole-Repo-Baselines.** Wenn möglich, nur neue/geänderte Zeilen failen (`git diff master...HEAD`-Scope, `credo diff`). Baseline-Files (`lint-baseline.xml` o.ä.) sind ein bekannter Mittelweg, aber sammeln stale Drift an. ([SonarQube New Code](https://docs.sonarsource.com/sonarqube-server/user-guide/about-new-code/), [imbue-ai/ratchets](https://github.com/imbue-ai/ratchets).) Umgesetzt in #544 via `credo diff --from-git-merge-base origin/master` (kein Baseline-File, exit 16 nur bei neuen Verstößen).
4. **AST/Compiler-Pässe schlagen Regex für semantische Checks.** Wenn der Check Kontext braucht (in `@moduledoc`? in `start_async`-Wrapper? Pattern-Match-Head vs String-Literal?), gehört er in einen AST-Walker (Credo-Custom-Check, Macro.prewalk). Regex reicht nur für rein-lexikalische Signale (z.B. `Process.send_after` ohne `cancel_timer` im selben File). ([Semgrep "Stop grepping" 2020](https://semgrep.dev/blog/2020/semgrep-stop-grepping-code/).) **Caveat**: AST ist nicht automatisch FP-frei — der [Macro.prewalk-Pipe-Arity-Bug](https://www.tomaszkowal.com/blog/finding-functions-with-given-arity-with-credo) zeigt, dass Credo-Custom-Checks ihre eigene FP-Klasse haben (Pipe-Arity verschiebt die `arity` um 1). Fixtures (Leitlinie 1) sind die Versicherung.
5. **Jede Regel rückverfolgbar auf einen realen Vorfall.** Issue-Link in Modul-`@moduledoc` + Test-Header. „Theoretisch könnte das schiefgehen" reicht nicht — es muss ein dokumentierter Bug, eine Code-Review-Beobachtung oder ein Production-Incident sein, der die Regel rechtfertigt. Sonst wuchert die Regel-Sammlung mit nicht-relevanten Lints, die Aufmerksamkeit von echten Findings ablenken.
6. **FP-Budget explizit machen.** Bei Merge des Checks im PR-Body schreiben: erwartet < 10% advisory-FP (akzeptabel für Code-Review-Lints), ~0% blocking-FP (für CI-Failure). Wenn die Rate nach 1-2 Wochen Beobachtung anders ist als geschätzt: nachjustieren oder zurück auf warn. ([Sadowski 2018](https://m-cacm.acm.org/magazines/2018/4/226371-lessons-from-building-static-analysis-tools-at-google/fulltext).)

### Historische Fehlschläge

Konkrete Anker für die Leitlinien — jedes Beispiel bricht eine andere Regel:

| Vorfall | Bricht Leitlinie | Was schief lief | Wie gelöst |
|---|---|---|---|
| #549/#550 `sync_reader_in_mount` flaggte `start_async(fn -> Reader.read(...) end)` | #4 (Regex statt AST) | Multi-line `start_async`-Wrapper außerhalb des Regex-Same-line-Fensters; CI blockierte korrekten Code | Pre-Filter in #560 (Cut 1); strukturelle Lösung via AST-Credo-Check in #559 (Cut 1 #544) |
| #471 `events_ssot_guard` flaggte `"kind" => "Foo"` im `@moduledoc` | #4 (Regex statt AST) | Regex sieht Doku-Kontext nicht; Cargo-Cult-Fix wäre Allowlist-Entry je Doku-Beispiel | Doc-Range-Filter in #560; AST-Endform `HardcodedEventKind` in #563 (Cut 2 #544) |
| #552 Iron-Law-#8-Fix `when kind == Shared.Events.x()` kompilierte nicht | #1 (keine Fixture) | Remote-Call im Guard ist verboten — Regel wurde nie an einem Fixture-Beispiel ausprobiert | Doc-Fix in #554; Fixture-Pflicht jetzt in Leitlinie 1 zementiert |
| #555 `apps/shared`-Tests compilierten nicht (Dotenvy) | #5 (keine Rückverfolgbarkeit per Test) | Der `lore.audit`-Regel-Test lag in `apps/shared/test` und lief weder lokal noch in CI — Regel-Drift wäre unbemerkt geblieben | Credo-Tests in #563 (`apps/hub/test/credo/ported_checks_test.exs`) — laufen in der CI-hub-Suite |

### Endform: AST-basierte Credo-Custom-Checks (#544)

Die Heimat für semantische Code-Regeln ist `tools/credo/<check>.ex` + `apps/hub/test/credo/<check>_test.exs` (siehe `ported_checks_test.exs` als Vorlage). Der Regex-basierte `mix lore.audit` (#535) wurde nach der Credo-Migration (#544) **entfernt** — Credo (AST + `credo diff`-Diff-Scope) ist die alleinige Heimat. Beim Hinzufügen einer neuen Code-Regel: einen Credo-Custom-Check schreiben + einen `refute_issues`-Fixture-Test, der die FP-Klasse einsperrt.

## Code style

- Follow standard Elixir / Phoenix conventions.
- `mix format` is canonical — no debate.
- Keep modules in the right umbrella app (`hub`, `worker`, `shared`).
- Document non-obvious *why* in comments, not *what*.

## Questions

Open an issue or email <thschwald@gmail.com>.
