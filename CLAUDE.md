# ⛔ HARTE REGELN (nicht verhandelbar, gelten in JEDER Session)

1. **SPRACHE: Antworte in JEDER Chat-Ausgabe auf Deutsch.** Ausnahmslos — auch
   technische Erklärungen, Status-Updates, Rückfragen. Gilt unabhängig davon, in
   welcher Sprache Code, Logs oder frühere Nachrichten sind. Diese Regel gilt auch
   direkt nach einer Context-Compaction weiter; wenn du unsicher bist, ob eine frühere
   Sprachanweisung noch im Kontext steht, gilt: Deutsch.

(Weitere harte Regeln folgen hier später — Platzhalter, noch nicht befüllen.)

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Language

Tom (the maintainer) is most fluent in German — sorry about that. The rest of this file, plus most CLAUDE.local.md notes, commit messages, issue bodies and PR descriptions, are written in German for that reason. External readers (non-German contributor, public repo audit) may encounter this file in a language they don't speak — that's expected and not something Claude Code should work around by replying in a different language.

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
- `mix credo --checks LoreTracker.Credo.Check` — AST-Linter (Issue #544). Die 5 vormaligen lore.audit-Regeln + ein God-Module-Check (`module_too_long`, #544-Headline; zählt seit #1097 **Code-Zeilen** statt aller Zeilen, Grenze 600 — s.u.) + zwei Präventions-Checks (Issue #614: `raw_event_bridge_publish` flaggt rohes `EventBridge.publish` in LiveViews → erzwingt den `Publisher.publish/2`-Cold-Fail-Flash, schließt die Silent-Failure-Klasse #613; `unescaped_markdown_render` flaggt `Earmark.as_html(…, escape: false)` im hub_web-Layer → schließt die Stored-XSS-Klasse #604 am Definitionspunkt, deckt damit auch `.heex`-konsumierte Render-Pfade) als Custom-Checks (`tools/credo/*.ex`, via `.credo.exs` `requires:`). **CI nutzt Full-Scan, blockend** (seit #793): `mix credo --checks LoreTracker.Credo.Check` scannt das ganze Umbrella; **JEDER** Verstoß rotet den PR-Check und blockt den Merge (exit 16 bei Findings, 0 sauber). Der Bestands-Backlog wurde vorher auf 0 geräumt (#789: 21 Event-Kind-Literale in `legacy_event_backfill` → `Shared.Events`-SSoT; #791: `transcribe.ex`-God-Module-Split → `Transcribe.Confidence`). Kein `failure: ignore` mehr (analog Dialyzer #619 / Coverage #658; #557-Lesson erfüllt: erst beobachten, dann blockieren). Der Full-Scan braucht keinen merge-base → die frühere Diff-Scope-`git-fetch`/unshallow-Mechanik samt Flake-Risiko ist entfallen. Der Regex-basierte `mix lore.audit` (#535) wurde schon früher **abgelöst + entfernt**.

  **God-Module-Grenze: gezählt wird Code, nicht Zeilen (#1097).** Der Check zählte bis dahin jede Zeile gleich — Code, Leerzeilen, `@moduledoc`, Begründungskommentare. Über alle 256 Dateien gemessen (2026-08-20) sind davon nur **60 % Code**, bei den Dateien nahe der Grenze fällt der Anteil auf **49 %** (`voice_session.ex`: 916 Zeilen, davon 452 Code und 367 Doku). Der Check maß damit die Sorgfalt mit, die hier ausdrücklich gewollt ist — Begründungskommentare am Code sind das Mittel gegen Wissensverlust zwischen Sessions —, und er zeigte auf die **falschen** Dateien: `artifacts.ex` war mit 995 Zeilen die knappste im Repo, nach Code aber nur Rang 3; die größte Code-Datei (`einstellungen_live.ex`, 775) stand nach Gesamtzeilen auf Rang 3. Gezählt wird jetzt, was `code_lines/1` übriglässt (keine Leerzeilen, keine `#`-Kommentare, keine `@moduledoc`/`@doc`/`@typedoc`/`@shortdoc`-Heredocs), die Grenze liegt entsprechend bei **600**.

  **Zwei Bestandsdateien laufen über eine Ratsche statt über eine Ausnahme** (`bestand:`-Param in `.credo.exs`): `einstellungen_live.ex` (659) und `dashboard_live.ex` (690). Angefangen hat die Liste mit vier Einträgen (775/691/611/602); `snapshots.ex` fiel mit #1152 unter die Grenze, `artifacts.ex` mit J4 (#1207, der Probelauf nahm seine vier Leser mit), und beide Einträge sind ersatzlos gestrichen — genau der Weg, den die Ratsche vorzeichnet. Sie dürfen ihren heutigen Stand halten, aber **nicht wachsen** — eine Zeile mehr rötet den Check; sinkt eine unter 600, greift wieder die reguläre Grenze und ihr Eintrag gehört ersatzlos raus. Der Unterschied zur Ausnahme ist der Punkt: eine Ausnahme ist unsichtbar und wächst mit, eine Ratsche schrumpft von selbst. Zwei Test-Wächter halten die Liste ehrlich (`module_too_long_test.exs`): kein Eintrag darf auf eine geschrumpfte Datei zeigen (sonst Altlast, die wie eine Regel aussieht), und kein Eintrag darf über dem Ist-Stand liegen (sonst gäbe er stillschweigend Wachstum frei) — beide gegengeprüft.

  **Der Schnitt dieser Dateien ist bewusst NICHT Teil davon.** Genau das ist der Anlass von #1097: die letzten beiden Schnitte (`Pipeline.Zeit` aus `pipeline.ex`, `AudioBuffer.Recovery` aus `audio_buffer.ex`) entstanden am Merge-Tor, weil Credo rot war — nicht, weil jemand das Modul zu groß fand. Dass sie trotzdem kohäsiv ausfielen, war Glück, kein Verfahren. **Ehrliche Grenzen des Checks, unverändert:** Zeilenzahl bleibt ein Proxy — ein Modul mit 400 Code-Zeilen und sechs Zuständigkeiten sieht er nicht, ein generierter 700-Zeilen-Mapper wird geflaggt, obwohl er keins ist. Er misst den **Zwischenstand** einer Datei, nicht das Ergebnis einer Änderung (real: `audio_buffer.ex` lief 981 → 1157 → 959, der PR verkleinerte die Datei und riss die Grenze trotzdem). Und zwei parallele Branches, von denen keiner allein die Grenze reißt, können sie zusammen reißen — rot wird dann master, nicht der PR (#1090-Klasse).
- `mix dialyzer` — Typ-Analyse (Issue #540). Fängt Spec-Drift / unmögliche Guards / dead `{:error,_}`-Pfade — und, seit #1247 belegt, **eine Schlüsselform, die kein Test sieht**: Ein Match auf `%{"blocks" => …}` gegen eine Map mit Atom-Schlüsseln traf nie, der betroffene Schritt meldete in jedem Lauf „fehlt", und weil er best-effort war, fiel es niemandem auf. Ein Test hätte das nicht gefangen — er baut die Eingabe mit derselben Annahme, die der Code trifft (dieselbe Falle wie bei den Wächtern, s. „Ein Wächter, der nie anschlägt"). Der Dialyzer ist an dieser Stelle das einzige Gate, das eine Annahme gegen die Wirklichkeit prüft statt gegen sich selbst. Erster Lauf baut den PLT (`priv/plts/`, ~2,5 min, gitignored); danach ~1 min. **Findings-Cleanup ist durch (Issue #589: 80 → 0 actionable Findings über 4 Cuts).** `mix dialyzer` läuft sauber durch (`done (passed successfully)`). Die `.dialyzer_ignore.exs`-Baseline hält **genau einen** bestätigten Dep-FP (`Phoenix.Tracker.update/5`-Success-Typing, Cut 2); alle anderen Suppressions sind co-lokierte `@dialyzer {:nowarn_function}`/`{:no_opaque}`-Attribute mit Begründung am Code (intentionale Boundary-Defense, anon halt-Closures, dev-Tooling-Confusion). CI-Step läuft **auf PRs + master-Push** und ist seit #619 **blockend** (kein `failure: ignore` mehr) — ein neues actionable Dialyzer-Finding rotet den PR-Check und blockt den Merge (echtes Merge-Gate; der #603-warn-Soak ist gelaufen, #557-Lesson erfüllt: erst beobachten, dann blockieren). Neue Dep-FPs gehören **vor** dem Merge mit Begründung in `.dialyzer_ignore.exs`. Kein PLT-Cross-Pipeline-Cache auf Codeberg, daher ~3,5 min/PR (sequenziell **nach** `test`, seit Issue #668 — die frühere `depends_on: [compile]`-Parallelität sprengte den Codeberg-Runner-RAM, weil zwei Dep-Compiles in unterschiedlichen MIX_ENVs gleichzeitig liefen → graceful-stop ohne echten Fehler).
- `mix lore.coverage_floor` — Per-Modul-Coverage-Floors (Issue #537; ExCoveralls kennt nur einen globalen `minimum_coverage`). Ratchet auf dem heutigen Stand pro kritischem Modul (Permissions 80 %, EventBridge 88 %, Commands 30 %, Materializer 70 %, Pipeline 35 %, Repo 68 %, CloudHelper 60 %). Braucht vorher `mix coveralls.json` pro App. CI-Step **seit #658 blockend** (vorher `failure: ignore`-Warn-Soak, der einen CloudHelper-Breach still durchließ — `failure: ignore` entfernt, analog Dialyzer #619). Deterministisch (kein LLM) → kein Flaky-Risiko; ein Floor-Unterschritt rotet den PR-Check.
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
- `OPENAI_API_KEY`. Setting `:backend_stage{n} == :openai` ohne Env-Var → Pipeline-Stage scheitert mit `:no_key_configured`. (Issue #174, Phase 1)
- `GEMINI_API_KEY`. Setting `:backend_stage{n} == :google` ohne Env-Var → Pipeline-Stage scheitert mit `:no_key_configured`. (Issue #175, Phase 1)
- `DISCORD_BOT_TOKEN` (optional, nur für Discord-Bot-Voice-Capture, Epic #985 — s. Abschnitt unten). Settings-first-then-ENV-Fallback wie die LLM-Keys (`Worker.Discord.BotToken`).

Event-Producer im Hub (LiveViews, Controllers, Mix-Tasks) erzeugen Events nicht mehr selbst — sie delegieren via `Hub.EventBridge.publish/1-2` an einen online Worker, der Worker-First-Apply'd + via `publish_intent` zurück-broadcastet. Cold-Fail (kein Worker online): Logger.warning + Flash-Error für UI / Mix.raise für CLI.

**Disaster-Recovery für Hub:** trivial. `git pull` + Secrets aus dem Vault + Re-Deploy. Keine Restore-Story, kein Backup, kein Schema.

**Disaster-Recovery für Worker:** Mnesia bleibt der kanonische Speicher pro Worker. Wenn ein Worker seine Mnesia verliert: re-pair + der Pull-Sync holt alle Events aus anderen Workern derselben Campaigns zurück. Mechanik seit #690+#693: persistente **Sync-Wasserlinie** pro Scope (`Worker.SyncWatermark` — nur Pull-Batches schieben sie vor, Live-Events nie → kein Cursor-Poisoning), Quell-Worker antwortet 1 Byte-Budget-Chunk pro Request (`pull_chunk_max_bytes`), Empfänger loopt bis leer; periodischer Sync-Tick (`sync_tick_ms`, 60 s) heilt verpasste Responses/Live-Events dauerhaft. Invariante: jeder Worker hält alle Member-Campaigns seiner User vollständig synchron, solange ein Peer online ist. Details: `docs/Backup-Recovery.md`.

## Rollen-Modell (Issue #140)

Zwei orthogonale Achsen:

**Globale Rolle** (`worker_users.role`, instance-weit):

- `:admin` — Universal-Allow. Userverwaltung, Worker-Config, sieht jede Kampagne.
- `:spielleiter` — darf eigene Kampagnen erstellen (`:create_campaign`). KEINE automatischen GM-Rechte in fremden Kampagnen.
- `:spieler` — Default. Darf einer Einladung folgen, Mikro beitreten, eigene Utterances bearbeiten.

**Per-Campaign-Rolle** (`campaign_members.role`, pro Membership):

- `:spielleiter` — GM dieser Kampagne. Ersteller wird automatisch eingetragen (`CampaignCreated` → Auto-Member). Weitere Co-SL werden vom GM via `MemberRolePromoted` befördert (Promote-Button am Member-Pill in der CampaignLive; derselbe Event-Kind dient der Rück-Demotion `:spielleiter → :spieler`). Der letzte Spielleiter einer Kampagne ist nicht demote-/removebar.
- `:spieler` — Mitspieler-Default (`InviteRedeemed` + `AdminMemberAdded` schreiben das).

**Seit Issue #1082 ist die GM-Liste kurz.** GM-exklusiv (per-Campaign-`:spielleiter` oder globaler `:admin`) sind nur noch **vier** Aktionen:

- `:delete_campaign` + `:delete_session` — **unumkehrbar**. Alles andere in diesem Projekt ist Overlay, LWW und undo-bar; Löschen ist es nicht.
- `:promote_member` + `:demote_member` — die Rollenverwaltung **muss** hier bleiben, sonst hebelt sich die Löschsperre selbst aus: wäre Befördern ein Mitglieder-Recht, könnte sich jeder Spieler zum Spielleiter machen und danach löschen.

**Alles Übrige ist Mitglieder-Recht** (jede per-Campaign-Rolle, `:spielleiter` wie `:spieler`): `:control_recording` (Aufnahme starten/stoppen/pausieren/fortsetzen/Marker — #1082), `:edit_summary`, `:edit_epos`, `:edit_chronik`, `:edit_flavor`, `:edit_vocab`, `:edit_calendar`, `:edit_discord_config`, `:add_utterance`, `:assign_speaker`, `:invite_to_campaign`, `:regenerate_session`, `:regenerate_campaign`, `:set_session_date`, `:set_fact_date`, `:resolve_flag`, dazu die schon länger offenen `:join_mic`, `:set_own_alias`, `:curate_threads`, `:curate_luecken`, `:curate_facts`, `:flag_raise`.

Das Trust-Modell dahinter ist dasselbe wie bei der Multi-Worker-Arbeit (#766): ein Member ist ein **Mit-Spieler am selben Tisch**, kein Fremder. Die Reibung, für jede Korrektur den Spielleiter zu brauchen, kostet mehr, als sie schützt — und beim Aufnahme-Start war sie messbar teuer (der Spielleiter ist bei Sessionbeginn der Beschäftigtste am Tisch, die ersten Minuten fehlten regelmäßig).

**Bedienen ist nicht Einrichten — diese Trennung ist mit #1082 gefallen**, mit einer Ausnahme: das Löschen und die Rollen. Wer den Discord-Server bindet oder das Vokabular pflegt, ist jetzt ebenfalls jedes Mitglied.

Zwei Schranken, nicht eine: der Hub gatet über `HubWeb.Permissions.can?/3` (mit `user.campaign_role`, gesetzt aus `Worker.Repo.campaign_role/2` beim LV-Mount), der Worker prüft in `Worker.Recording.Recorder.resolve_campaign/2` **noch einmal selbst**. Die zweite ist die wichtigere: der Slash-Befehl (#1033) kommt am Hub vorbei und trifft nur sie. Globale `:spielleiter` ohne Membership in einer Kampagne ist dort weiterhin gleichgestellt mit `:spieler`.

Im UI heißt das Assign für die Aufnahme `can_record?` (`HubWeb.CampaignLive.Derive`); `owner?` bleibt der GM-Indikator (`:delete_campaign`) und taugt seit #1082 **nicht** mehr als Stellvertreter für „darf bearbeiten" — `can_edit_meta?` ist für Mitglieder wahr.

**Permission-Assigns kommen aus EINER Liste** (`Derive.permission_assigns/0`, seit #1090). Sie wurde vorher an drei Stellen von Hand gepflegt — Mount-Defaults, Snapshot-Apply, Rollenwechsel-Apply — und genau das ging schief: `can_record?` landete in Berechnung und Defaults, aber nicht im Apply, und der REC-Knopf war für **alle** dauerhaft ausgegraut (Prod-Bug, gemeldet Minuten nach dem #1082-Deploy). Derselbe Fehler steckte unabhängig davon schon länger im Rollenwechsel-Pfad, dem vier Keys fehlten. Ein fehlendes Assign erzeugt keinen Fehler, sondern einen **toten Knopf** — nichts wird rot, weder beim Kompilieren noch in der Suite noch im Log. Deshalb: `Derive.assign_permissions/2` überträgt alle Keys, `default_permission_assigns/0` liefert den Sperr-Satz, und `derive_permission_keys_test.exs` hält Berechnetes und Übertragenes gegeneinander (mit einer benannten Ausnahmeliste für das, was bewusst anders heißt). Wer ein neues Recht ergänzt, ergänzt nur noch `@permission_assigns`.

`campaign.owner_discord_id` ist seit #140 KEIN persistiertes Feld mehr — `Worker.Repo.get_campaign/1` liefert den ersten Spielleiter als abgeleiteten Wert (für Recording-Leader-Routing und Dashboard-SL-Pille). Permission-Gating geht nie über dieses Feld.

### Admin-Debug-Endpoint (Issue #144)

Wenn ein User über fehlende GM-Buttons oder seltsame Permission-Symptome klagt: Admin-only HTTP-GET dumpt für die (target_did, campaign_id)-Paarung den Worker-Snapshot + die aus `HubWeb.CampaignLive.derive_assigns/2` berechneten LV-assigns + die Permission-Matrix (`HubWeb.Permissions.can?` für alle GM- und Member-Actions) als JSON.

**URL-Schema:**

```
GET /admin/debug/campaign/<campaign_id>?target_did=<discord_id>[&include_live=1]
```

**Konkrete Beispiele:**

```bash
# Prod (gigalixir):
https://loretracker.gigalixirapp.com/admin/debug/campaign/romeo-julia-demo?target_did=615614311255244801

# Lokal (PR-Test-Hub auf 4003):
http://localhost:4003/admin/debug/campaign/romeo-julia-demo?target_did=615614311255244801

# Mit curl + Session-Cookie:
curl -b "_lore_tracker_key=<sess-cookie>" \
  "https://loretracker.gigalixirapp.com/admin/debug/campaign/<cid>?target_did=<did>"
```

Einfacher im Browser: einloggen, dann die URL direkt aufrufen — der Browser schickt das Session-Cookie automatisch mit.

**Gate**: Target-User muss vorher in `/settings → Debug-Zugriff` einen Grant (5/15/60 min) aktiviert haben (`Hub.DebugConsent.grant/2`). Ohne valid Grant → 403 mit Hint. Auto-Expire via `Process.send_after`, kein Postgres-Persist (Hub-stateless seit #164). Audit-Log via `Logger.info` mit `admin_did + target_did + campaign_id`.

**Response-Shape** (JSON):
- `snapshot` — Worker-Reader-Output (campaign + sessions + members + utterances + epos + chronik + ...)
- `derived_assigns` — `{role, campaign_role, is_member?, owner?, can_edit_meta?, can_regenerate_*, perm_user}`
- `permissions.gm_actions` — Map mit allen 12 GM-Actions (`edit_summary, delete_campaign, ...`) → `true`/`false`
- `permissions.member_actions` — `join_mic, set_own_alias` → `true`/`false`

LV-Process-Iteration (`?include_live=1`) ist v1-out-of-scope — der Endpoint returnt einen Hint-Stub. Snapshot + derived-Assigns + Permissions-Matrix reichen für die meisten Permission-Bug-Diagnosen.

## Deploy (Gigalixir + Codeberg-Woodpecker)

- CI-Config lebt seit #764 im Verzeichnis `.woodpecker/`: **`woodpecker.yml`** (compile + credo + test + dialyzer + coverage + deploy — der Dateiname hält den Required-Status-Kontext `ci/woodpecker/pr/woodpecker` stabil) + **`audit.yml`** (`deps_audit` als eigener, nicht-required Workflow — ein Runner-/Daemon-Fehler dort cancelt den Deploy nicht mehr; genau das passierte 2026-07-09 zweimal trotz `failure: ignore`). Seit Issue #31 ist die Pipeline auf den stateless-Hub angepasst: **compile** läuft `mix compile --warnings-as-errors` über das ganze Umbrella (Drift-Gate für hub + worker + shared), **test** fährt die hub- **und** die worker-Suite (`mix cmd --app hub mix test` + `mix cmd --app worker mix test` — beide gated; shared hat keinen eigenen Test-Step, weil es standalone nicht bootet [config/runtime.exs importiert Dotenvy, kein shared-Dep] → shared-Logik wird aus der hub-/worker-Suite mitgetestet, z.B. der Wire-Drift-Guard unter `apps/hub/test/wire/`), **deploy** pusht zu Gigalixir ohne `ps:migrate` (kein Schema) und hängt seit #1224 an **allen** Gates (`depends_on: [compile, test, credo, dialyzer, coverage]`) — „wenn rot, dann stop" (Tom, 17.09.2026). Vorher hingen dort nur `[compile, test]`: Lauf 1053 deployte bei rotem `coverage` und übersprang dabei `deploy_verify`, weil Woodpecker nach einem Fehlschlag alle noch nicht gestarteten Schritte überspringt. Der Preis ist die Deploy-Latenz, die die frühere Anordnung bewusst gespart hatte. **Seit Issue #31 ist Woodpecker aktiv** (CI-Zugriff via `Codeberg-e.V./requests` #2016 auto-granted nach der AGPL-Relizenzierung #477; Repo in ci.codeberg.org aktiviert, Webhook gesetzt, die drei Secrets `gigalixir_email`/`gigalixir_api_key`/`gigalixir_app_name` als push-scoped Secrets hinterlegt). **Jeder master-Push deployt jetzt automatisch nach Gigalixir** — der manuelle `git push gigalixir HEAD:refs/heads/master` ist damit **überflüssig** (würde doppelt deployen). compile + test laufen zusätzlich auf jedem PR.
- `mix release.hub` (alias) builds the prod release (`lore_tracker`, hub+shared only — worker stays local-install).
- Required Codeberg secrets: `gigalixir_email`, `gigalixir_api_key`, `gigalixir_app_name`.
- Buildpack pins live in `elixir_buildpack.config` + `phoenix_static_buildpack.config`.

### Branch-Protection als Merge-Gate (Issue #485)

`master` ist **Branch-protected** mit dem Woodpecker-PR-Check als Required-Status — der Merge-Button bleibt gesperrt, solange `ci/woodpecker/pr/woodpecker` (compile + test) rot oder pending ist. Erst **CI grün + Maintainer-Merge** lässt nach master (und damit per Auto-Deploy nach Prod). Kein roter/ungetesteter Stand kommt mehr durch — genau das „CI-OK, dann mein OK"-Modell. Praktische Folge fürs Mergen: erst den CI-Status pollen (grün abwarten), dann mergen — Merge-Versuche auf rot/pending werden geblockt.

Die Settings leben in der Codeberg-Web-UI (**Repo → Settings → Branches → `master`**, Maintainer-only, nicht per API/Commit automatisierbar):

- **Push deaktivieren** — direkte Pushes auf master gesperrt, alles läuft über PRs.
- **Statuscheck-Muster** = `ci/woodpecker/pr/woodpecker` — der PR-Check muss grün sein.
- **Ungeschützte Dateimuster** = `.woodpecker.yml;.woodpecker/**` — siehe Ausnahme unten (seit #764 liegt die Config unter `.woodpecker/`; das Muster muss das Verzeichnis abdecken, sonst ist die CI-Selbstreparatur-Ausnahme wirkungslos).

**Ausnahme — CI-Config kann sich nicht selbst grün prüfen:** Woodpecker nutzt für PR-Events die CI-Config aus dem **Ziel**-Branch (master), nicht aus dem PR-Branch. Eine kaputte CI-Config reparierende Änderung kann ihren eigenen Fix daher nie per PR validieren — der Check bliebe ewig rot. Lösung: die CI-Config-Pfade (`.woodpecker/**`, historisch `.woodpecker.yml`) stehen in den **Ungeschützten Dateimustern**, d.h. PRs, die *nur* diese Dateien ändern, umgehen den Required-Status (Admin-Bypass alternativ). Bei reinen CI-Config-Fixes also bewusst trotz noch-rotem/abwesendem Check mergen.

### Free-Tier-Grenzen + Guards (Issue #876)

Prod läuft auf dem Gigalixir-**FREE**-Account: max size **0.5** (aktuell 0.4), **genau 1 Replica**, kein Clustering, und **30 Tage ohne Deploy → App wird auf 0 Replicas skaliert** (Warnmail nach 23 Tagen; jeder master-Push deployt = zählt als Aktivität). Drei Guards sichern das ab:

- **`deploy_verify`-CI-Step** (`.woodpecker/woodpecker.yml`, nach `deploy`): pollt via `tools/ci/deploy_verify.py` die Gigalixir-API bis das Release mit dem CI-Commit-SHA live ist, prüft Pods Healthy + replicas 1/1 + kein `OOMKilled`-lastState + size ≤ 0.5 + HTTP 200/301/302/303 auf `/` + Grace-Recheck nach 30 s. Ein kaputtes Deploy (z.B. OOM-Crash-Loop am 400-MB-Limit) rotet die Pipeline statt still tot zu sein.
- **`freetier`-Cron-Workflow** (`.woodpecker/freetier.yml`, braucht KEINE Secrets — die gigalixir_*-Secrets sind push-scoped) mit **zwei** Schritten: `tools/ci/freetier_check.sh` (HTTP-Check auf Prod + rot ab 21 Tagen ohne master-Commit, Frühwarnung vor dem 30-Tage-Downscale) und seit #1224 `tools/ci/deploy_drift_check.sh` — **läuft in Prod überhaupt der master-Stand?** Er fragt `/health/version` (die Commit-SHA des Releases, aus `Hub.Version.current/0`) und vergleicht sie per Präfix mit `git rev-parse HEAD`; unter 60 Minuten Commit-Alter gilt ein Unterschied als „Deploy noch unterwegs", darüber als Befund. **Der Fall, für den es ihn gibt:** ein master-Lauf wird gekillt, bevor er `deploy` erreicht (zwei Merges kurz hintereinander killen den ersten Lauf — real Lauf 1089 am 17.09.2026 und 1113 am 19.09.). `deploy_verify` läuft dann nie, `freetier_check` bleibt grün, und der Commit steht in master, aber nicht in Prod. Am 17.09. fiel das nur auf, weil jemand die Releases von Hand verglich. Einmaliges Maintainer-Setup: Cron-Eintrag in der Woodpecker-UI (ci.codeberg.org → Repo → Settings → Cron, Branch master, wöchentlich).
- **pending-Map-Regressionstests** (`reader_pending_test.exs`; bis J6 #1210 auch `prompt_preview_pending_test.exs` — `Hub.PromptPreview` ist mit der Stil-Vorschau entfallen): nageln die Aufräum-Pfade der einzigen praktisch unbounded-fähigen Hub-RAM-States fest (Cache-Inventar 2026-07-17; RateLimit-Sweep + DebugConsent-Expire waren schon getestet).

**Zwei Korrekturen an diesem Absatz, beide 2026-08-19 am laufenden Prod-Pod nachgemessen (#1087):**

- **„400 MB RAM" ist zu großzügig.** Das Cgroup-Limit ist `memory.max` = 399.998.976 B = **381,5 MiB**. Wer mit 400 rechnet, plant 18 MiB Puffer ein, die es nicht gibt.
- **„kein SSH" stimmt nicht.** Der FREE-Tier bekommt sehr wohl einen SSH-Endpunkt zugeteilt (`root@us-central1.gcp.ssh.gigalixir.com:<port>`), und `gigalixir ps:distillery rpc "<expr>"` läuft damit gegen den **laufenden** Pod. Genau das hat die #1087-Ursachensuche entschieden, statt auf den nächsten Kill zu warten. Voraussetzung ist der bei Gigalixir hinterlegte SSH-Key im Agent; ohne TTY braucht `ssh-add` ein Askpass (auf dieser Maschine `kdialog`). **`ps:observer` dagegen nicht benutzen** — die GUI zieht laufend Prozessdaten, und schon eine schlichte SSH-Sitzung kostet den Pod ~47 MB (`gigalixir_run` + zwei `sshd`), also über ein Zehntel des Limits.

### Hub-Speicher: Protokoll-Ladefenster + Speicher-Zeile (Issue #1087)

Der Prod-Hub wurde zwischen dem 07. und 18.08.2026 **fünfzehnmal** am
Speicherlimit gekillt, vierzehnmal davon in den letzten drei Tagen — mitten im
Spielbetrieb, als 502 für ein paar Sekunden. Der Hub ist seit #164 zustandslos
und übersteht das technisch; für eine laufende **Aufnahme** entsteht in dieser
Zeit aber eine Lücke im Mitschnitt, die niemand bemerkt (dieselbe Klasse wie
der Deploy-Restart aus #703, nur unangekündigt).

**Was die Log-Auswertung ergab — und was sie widerlegte.** Drei naheliegende
Erklärungen fielen durch: kein Speicherleck (Laufzeit bis zum Kill streute von
12 Sekunden bis 41,5 Stunden — ein Leck hätte eine Zeitkonstante), keine
Versions-Korrelation (die verdächtigten SHAs sind im Hub-Verzeichnis
byte-identisch; die Häufung markiert bloß den längsten ununterbrochenen
Deploy), und keine Last (der aufnahmeintensivste Tag mit über 10.000
Audio-Chunks hatte **null** Kills, der ruhigste hatte acht). Was blieb, ist die
Anwesenheit von Zuschauern: in 10-Minuten-Fenstern gerechnet fiel **kein
einziger** Kill in ein Fenster ohne LiveView-Aktivität (0 von 1494), alle
dreizehn in die 272 Fenster mit (4,8 %). Das ist kein Zirkelschluss — die
Worker-Channel-Nachrichten laufen rund um die Uhr, der Hub ist nie untätig.

**Die Ursache, live am Pod nachgemessen.** `campaign`-Snapshot einer echten
Kampagne: **5,7 MB Heap**, davon **4,8 MB allein `utterances`** (5.553
Einträge). Alle Scopes zusammen ~7 MB — **pro Betrachter**, denn jeder
LiveView hält seinen eigenen Snapshot in den Assigns, und LiveView hält beim
Diffen kurzzeitig alt *und* neu. Nicht der Text ist dabei teuer (216 KB
serialisiert für alle 5.553 Zeilen zusammen), sondern die schiere Zahl der
Maps: ~870 Byte Heap je Utterance für ~270 Byte Daten.

Das #709-Fenster half dagegen nichts, weil es das falsche Fenster ist: es
schneidet zu, was ins DOM geht, während die volle Liste in den Assigns lag.
Der Kommentar dort sagte das ausdrücklich („teuer ist der Render-Diff, nicht
der Assign-Heap") — genau diese Annahme ist widerlegt.

**Gebaut wurde beides — Messung und Hebel:**

- **Ladefenster.** Der `campaign`-Snapshot liefert nur noch die jüngsten
  `Worker.Repo.utterance_tail_size/0` (200) Utterances **je Session**, dazu
  `utterance_counts` (Gesamtzahl je Session) und `utterance_from` (absoluter
  Index, ab dem die gelieferte Liste beginnt). Ohne diese beiden Karten könnte
  der Hub aus einer Teilliste keine richtigen Gesamtzahlen ableiten und nicht
  gezielt weiterblättern. Darüber liegt ein **Gesamtbudget** (1.200) und ein
  **Mindestrest je Session** (10): ein reines Pro-Session-Fenster begrenzt
  nichts — eine Kampagne mit 200 Sessions bekäme 40.000 Zeilen und wäre
  schlechter dran als mit dem alten 10.000er-Deckel. Das Budget wird von der
  jüngsten Session abwärts vergeben; der Mindestrest ist keine Freundlichkeit,
  sondern nötig, weil die Protokoll-Spalte über die gelieferten Utterances
  gruppiert und eine Session ohne eine einzige Zeile aus der Ansicht
  verschwände. Der neue schmale Scope **`campaign_utterances`** holt
  nach — in zwei Formen, weil die Ansicht zwei verschiedene Fragen stellt:
  `session_id`+`from`+`count` fürs Scrollen, `ids` für Sprungmarken und den
  Refs-Popover, die auf beliebig alte Zeilen zeigen können. Die ids-Antwort
  trägt zusätzlich die absoluten Positionen, sonst wüsste der Hub nicht, wie
  weit er für einen Sprung zurückladen muss.
- **Invariante: das Geladene ist immer ein zusammenhängendes Suffix
  `[from, total)`.** Ein Einzelabruf per ID landet deshalb in
  `utterance_lookup` und **nicht** in der Liste — sonst risse er ein Loch
  hinein, und das Render-Fenster zeigte nicht benachbarte Zeilen als
  benachbart an. Für den echten Sprung (`focus_utterance/3`, auch von
  ColumnSync #10 benutzt) wird der Bereich zwischen Ziel und geladenem Anfang
  vollständig geholt; vorher tat ein Klick auf eine sehr alte Zeile schlicht
  gar nichts.
- **`Hub.MemoryReporter`** schreibt alle 30 s eine Zeile im bestehenden
  `[telemetry] event=…`-Format: `:erlang.memory/0` **und** die Cgroup-Werte
  (`memory.current`/`memory.peak`/`memory.max`/`anon`), dazu Prozesszahl, Zahl
  offener LiveViews und die drei größten Prozesse mit Mailbox-Länge. Ab 85 %
  des Limits wird die Zeile zur `Logger.warning` — gemessen an **`anon`**, nicht
  an `memory.current` (#1098): `current` enthält den Seitencache, den der Kernel
  wegwirft, bevor er killt. An der ersten Prod-Messung sichtbar: im Leerlauf,
  bei null Betrachtern, `current` 301 MB von 381 (79 %) gegen `anon` 154 MB
  (40 %). Auf `current` hätte die Schwelle ab Tag eins dauerhaft geleuchtet und
  wäre genau dann übersehen worden, wenn sie einmal etwas bedeutet. Beide Sichten nebeneinander
  sind der Punkt: nur auf die BEAM-Zahl zu schauen hätte die Ursache verfehlt.
  Ohne echtes Cgroup-Limit (Entwicklermaschine) entfallen die Kernel-Felder
  ganz, statt Zahlen des ganzen Rechners zu melden.

**Nach dem Deploy am 19.08. an der laufenden App nachgemessen** (#1098): im
Leerlauf liegt `anon` bei 154 MB von 381 (40 %), die Luft nach oben ist also
~227 MB — nicht die zunächst geschätzten ~190 MiB. Die frühere Zahl stammte aus
einer Messung am alten Pod, in der die eigene SSH-Sitzung (~47 MB) mitzählte.
Zugleich ist der 16. Kill jetzt **kernel-bestätigt** statt nur plausibel: der
von diesem Deploy ersetzte Pod zeigte in `gigalixir ps` `exitCode: 137,
reason: OOMKilled` (08:00 UTC, nach 4,5 h Laufzeit) — genau der unabhängige
Nachweis, den die Log-Auswertung als fehlend benannt hatte.

**Ehrliche Grenzen.** Dass die ~227 MB Abstand zwischen Ruhezustand und Limit
tatsächlich von mehreren gleichzeitigen Betrachtern gefüllt werden, ist
**plausibel, nicht bewiesen**: fünf Betrachter × 7 MB sind im Ruhezustand nur
~35 MB. Der Rest müsste aus dem Müll pro Neu-Lesen kommen (jeder Mount zieht
den Snapshot über den Channel, dekodiert ihn und kopiert ihn durch
`Hub.Reader`) — genau das soll die Speicher-Zeile beim nächsten Kill zeigen.
Die LiveView-Zählung hängt am Prozess-Label, das Phoenix setzt (ein Interna,
durch einen Test mit echtem Mount abgesichert). Der Sync-Index (#10) fällt für
Alt-Seeds ohne `source_refs` auf „alle Utterances der Session" zurück und ist
dort jetzt unvollständig. Und ein Sprung auf die älteste Zeile einer langen
Session lädt weiterhin die ganze Session — für diesen einen Betrachter, auf
ausdrückliche Aktion, statt für alle bei jedem Mount. Der Mindestrest bleibt
zudem **linear in der Zahl der Sessions** (200 Sessions ≈ 3.100 Zeilen statt
gedeckelter 1.200); vollständig gedeckelt wäre es erst, wenn eine Session auch
mit null gelieferten Zeilen darstellbar ist — das hieße, `group_by_session/2`
über die Session-Liste statt über die Utterances laufen zu lassen, und ist
eigene Arbeit.

### Warteschlange für die grossen Reads (Issue #1149, Epic #1146)

Der Prod-Hub wurde in 14 Tagen **130+ mal** am Speicherlimit gekillt. Kein
Leck, sondern ein Kreislauf: nach einem Kill wächst der Reconnect-Backoff der
Browser, dann verbinden sich alle Tabs und der Worker **gleichzeitig**;
`workers_changed` löst in jeder offenen CampaignLive einen Voll-Read aus, und
bis zu 16 Snapshots à 3,3 MB laufen parallel durch denselben Hub. Der stirbt
daran, der Backoff wächst weiter, der Kreislauf schliesst sich.

`Hub.Reader` lässt von den drei Kampagnen-weiten Scopes (`@serialized_kinds`:
`campaign`, `campaign_facts` und — seit #1198 anstelle von `campaign_luecken` —
die **Vollform** von `campaign_glatt_ansicht`) deshalb **immer nur einen**
laufen. Ein Fensterschritt der Geglättet-Spalte (`"nur"` gesetzt, eine Session,
≤ 200 Blöcke) läuft vorbei, aus demselben Grund wie `campaign_utterances`. Aus 16 gleichzeitigen Spitzen wird eine Folge von 16 einzelnen: **die
Gesamtdauer steigt, der Höchststand nicht** — das ist der Zweck und zugleich
der Preis. Alle übrigen Scopes bleiben unverändert parallel; sie sind klein,
und sie zu serialisieren erzeugte Wartezeit ohne Speichergewinn.
`campaign_utterances` ist bewusst draussen: es ist der Nachlade-Scope des
#1087-Fensters und liefert eine feste Zahl Zeilen — es hinter die grossen
Reads zu stellen machte das Scrollen zäh, ohne etwas zu sparen.

**Warum im Hub und nicht im Worker.** Der Worker serialisiert bereits von
selbst — `Rpc.on_snapshot/2` läuft synchron im Socket-Prozess, es gibt dort
also nie 16 gleichzeitige Snapshot-Bauten. Und es reicht nicht: die Spitze
entsteht **nach** dem Empfang, beim Dekodieren des Rahmens und beim Diffen in
N Ansichten. Dazu kommen zwei Gründe, die den Ort entscheiden: die **Frist**
lebt beim Aufrufer (läge die Schlange im Worker, müsste er dem Hub „du stehst
an" sagen können — ein Protokoll-Umbau; ohne ihn liefe der Hub-Read in seine
Zeitgrenze und iterierte auf den nächsten, ebenso beschäftigten Worker, also
schlimmer statt besser), und die **Anzeige** lebt ebenfalls dort. Die Schlange
ist flüchtiger RAM wie Tracker und PubSub — die Zustandslosigkeit des Hubs
(#164) bleibt unberührt.

**Die Frist ist gerechnet, nicht gegriffen:** `queue_deadline_ms(vor_mir) =
min((vor_mir + 2) × @per_attempt_timeout, 60 s)`. Die beiden Zuschläge sind
der laufende Read und der eigene; die 5 s sind die Zahl, die dieses Repo
ohnehin als „so lange darf ein Worker brauchen" führt. `read/2` hebt die
Aufrufer-Frist für serialisierte Kinds entsprechend an — **ohne das stürbe der
`GenServer.call` an seiner eigenen Zeitgrenze**, und der Aufrufer sähe einen
Absturz statt einer Antwort. Daraus folgt die Zusage: der Reader antwortet
immer innerhalb von `@queue_max_wait + @default_timeout`.

**Kein automatischer Neuversuch** bei `{:error, :queue_timeout}` — ein
Timer-Retry ersetzte den Kill-Kreislauf durch einen Timeout-Kreislauf.

**Der Platz wird an ALLEN Ausgängen frei** (Antwort, Timeout, kein Worker,
abgemeldeter Worker), sonst stünde die Schlange. Der wichtigste davon ist der
letzte: der Reader abonniert seit #1149 die `WorkerRegistry` und behandelt
einen laufenden Read am abgemeldeten Worker wie einen Timeout — ohne das
stünde die Schlange genau im Reconnect-Fall still, also in dem Fall, für den
sie gebaut ist. Dafür merkt sich der pending-Eintrag seine `worker_id`. Beim
Retry **wandert der Platz mit**; ohne das gäbe der Reader ihn nach dem ersten
Worker-Wechsel nie wieder frei.

**Sichtbar in der Oberfläche:** `read/2` nimmt `notify: pid` und meldet
`{:reader_queued, kind, position}` beim Einreihen und beim Weiterrücken,
`{:reader_started, kind}` sobald der Read läuft. Die vier Warte-Zweige der
CampaignLive zeigen darüber „Wartet auf einen Ladeplatz (Position N)" statt
stumm „Warte auf Worker." (`Components.warte_text/2`). Best-effort: ohne
`notify:` verhält sich alles exakt wie zuvor. **`self()` muss VOR der
`start_async`-Closure gebunden werden** — darin wäre es die Pid des Tasks. Die
Speicher-Zeile (#1087) führt zusätzlich `reader_queue=N`, sonst ist ein Herd
von einem ruhigen Moment nicht zu unterscheiden.

**Zwei Funde im Bestand, beide Silent-Failure-Klasse:**

- Die **CampaignLive hat keinen `handle_info`-Auffangzweig**. Jede unerwartete
  Nachricht bringt sie zum Absturz. Die beiden Klauseln für die
  Warte-Meldungen sind damit Pflicht, nicht Kosmetik — wer künftig einen
  Rückkanal an diese Ansicht hängt, braucht seine Klausel dazu.
- **`HubWeb.ReaderStub` matchte auf die innere Tupel-Form** von
  `Reader.handle_call` — ein privates Detail, kein Vertrag; sein eigener
  Moduledoc nannte bereits die vorletzte Form, ohne dass es auffiel. Als die
  Schlange zwei Felder ergänzte, fielen rund zwanzig LiveView-Tests mit einem
  `FunctionClauseError` **im Stub**, und der Reader kam in keiner
  Fehlermeldung vor. **Ein Test-Doppel bildet Verhalten nach, nie die innere
  Form einer `handle_call`-Klausel.** Der Stub prüft jetzt nur noch, dass es
  ein Lese-Call ist. Aus demselben Grund liefert `Reader.initial_state/0` den
  leeren Zustand für `init/1` **und** die Tests — ein von Hand nachgebauter
  Zustand ist die Klasse, die in `VoiceSession` (#1005) einen Prod-Crash-Loop
  gekostet hat.

**Ehrliche Grenzen.** Es gibt **kein Dedup**: zwei Tabs derselben Kampagne
lesen denselben Snapshot zweimal nacheinander (das wäre der geteilte
Kampagnen-Snapshot, eigenes Ticket). Ein zäher Worker **blockiert den Kopf**
der Schlange, bis seine Frist abläuft — gedeckelt, nicht verhindert. Und die
Schlange drosselt das **Anfragen**, nicht das **Arbeiten**: baut der Worker
langsam, steigt die Wartezeit, nicht der Speicherverbrauch. Vor allem aber ist
**nicht gemessen, ob ein EINZELNER grosser Read samt Kopierkaskade unter die
Decke passt** — die Schlange hilft nur, wenn er es tut. Das war C0 des Epics
und ist offen.

### Glättungs-Blöcke: Skelett vollständig, Texte gefenstert (Issue #1152, Epic #1146)

Was #1087 für die Protokollzeilen tat, fehlte für die geglätteten Blöcke — sie
waren danach die **einzige große Liste ohne Fenster**. An seattleV4 per RPC am
laufenden `worker_prod` gemessen: **2436 KB** für 4110 Blöcke aus 3 Sitzungen,
**74 %** des Haupt-Snapshots, pro Betrachter.

`smoothed_for_campaign/2` nimmt jetzt `fenster: true`. Dann reist das
**Skelett** vollständig (`block_id`, `quell_utterance_ids`, `hat_luecke`,
`status` — gemessen 793 KB) und die **Texte** nur für die jüngsten 200 Blöcke je
Sitzung unter einem Gesamtbudget von 600, Mindestrest 10; Vergabe von der
jüngsten Sitzung abwärts, überziehen statt schneiden — dasselbe Muster wie
`campaign_utterance_tail/2`. Exakt nachgerechnet: **2436 → 1055 KB, −56,7 %**.
**Ohne die Option ist die Antwort byte-identisch**; der Schalter sitzt am
`campaign_luecken`-Scope (`"glatt" => "fenster"`) — **seit #1153 (C6) setzt der
Hub ihn**, bis dahin änderte sich in Prod nichts.

**Die Invariante ist eine ANDERE als beim Utterance-Fenster** — das ist der
Punkt, an dem ein naiver Nachbau falsch würde. Dort muss die gelieferte Liste
ein zusammenhängendes Suffix sein, sonst erschienen nicht-benachbarte Zeilen als
benachbart. Hier fehlt **kein** Block: die Texte sind eine beliebige Teilmenge,
ein textloser Block ist sichtbar textlos statt unsichtbar. Ein `text_from` gibt
es deshalb bewusst **nicht** — es beschriebe ein Suffix, auf das sich niemand
verlassen darf.

**Nachgeladen wird in ZWEI Formen** (`campaign_luecken_slice`), aus demselben
Grund, aus dem `campaign_utterances` zwei hat: die Spalte stellt zwei
verschiedene Fragen. Der ursprüngliche Entwurf sah nur einen Bereich
`[from, count)` vor und hätte die Standardansicht zerstört:
`glatt_view_for/2` schaltet **automatisch** auf „kuratieren", sobald es etwas zu
kuratieren gibt, und dieser Filter ist ein **Prädikat**
(`hat_luecke and is_nil(status)`) — seine Treffer liegen über die ganze Sitzung
verstreut. Gemessen liegen allein die letzten 150 Treffer der dritten Sitzung
auf den Positionen **1230..1795 von 1802**; ein 200er-Suffix deckt davon 56.
Weil der Text zugleich die **Nutzlast des Kurations-Events** ist
(`phx-value-text`), wären aus den übrigen tote Knöpfe geworden — „Kein Text zum
Bestätigen", immerhin laut. Also `smoothed_texts_by_ids/2` für den
Prädikat-Fall, `smoothed_texts_slice/4` fürs zusammenhängende Scrollen.

**Ehrliche Grenzen:**

- **Der Worker wird nicht schneller.** Auf einem seattleV4-großen Fixture
  gemessen: voll 39 ms / 3025 KB gegen gefenstert 40 ms / 909 KB. Der volle
  `list_utterances(limit: :all)` bleibt, sobald auch nur **ein** Block der
  Sitzung Text trägt, weil es keinen Leser für einzelne Utterance-IDs gibt (der
  Roh-Text ist der einzige Grund für diesen Read). Er entfällt nur bei leerem
  Fenster und im ids-Pfad für Sitzungen ohne Treffer (dort 25 ms). Der Gewinn
  ist die **Nutzlast**, nicht die Rechenzeit.
- Das Fenster deckelt die Texte, nicht die **Struktur**: das Skelett wächst
  weiter linear mit der Kampagne (793 KB an seattleV4).
- ~~Ohne die Hub-Seite bleibt der Schalter ungesetzt — die Wirkung in Prod ist
  null, bis dort jemand danach fragt.~~ **Mit #1153 (C6) eingelöst**, s.u.

**Nebenwirkung auf die God-Module-Ratsche:** `snapshots.ex` ist mit diesem Cut
von der Bestandsliste **heruntergefallen** (602 → 599 Code-Zeilen). Der neue
Scope hätte die Ratsche gerissen; statt sie anzuheben sind die Rümpfe beider
Lücken-Klauseln nach `Worker.Repo.Luecken` gewandert — das `member?`-Gate blieb
am Dispatch, wo jede Nachbar-Klausel es auch hat. Wer die Datei wieder über 600
bringt, bekommt die **reguläre** Grenze rot, nicht eine gewachsene Ratsche.

### Die Geglättet-Spalte fordert das Fenster an (Issue #1153, Epic #1146)

C5 (#1152) gab dem Worker die Fähigkeit, die Texte zu fenstern. Dieser Cut
lässt den Hub sie auch **anfordern**, anzeigen und nachladen — und behebt dabei
den Defekt, an dem der Prod-Hub am 07.09. um 13:53 und 13:55 starb.

> **Seit #1198 ist die Hub-Seite dieses Abschnitts abgelöst.** Der Hub fragt
> `campaign_luecken` nicht mehr; `GlattFenster`, das Nachladen über IDs, der
> „N noch ohne Text"-Anker, die Quittung, `glatt_texte` und das gezielte
> Verwerfen einzelner Block-IDs gibt es nicht mehr — der Worker liefert das
> Fenster samt Text (s. „Die Geglättet-Spalte bekommt nur, was sie zeigt").
> Stehen bleibt der Abschnitt als Begründung: die Messungen, die Kill-Analyse
> und die Fallen (`start_async`-Abbruch, `hat_luecke == true`) gelten weiter.
> `glatt_flag_guard_test.exs` bewacht seitdem das Gegenteil: **kein**
> `campaign_luecken`-Read im Hub.

**Die eine Zeile.** C4 (#1151) nahm die Blöcke aus dem Mount-Read und lud sie
direkt danach über `campaign_luecken` nach — **ohne das Fenster-Flag**. An
seattleV4 per RPC am laufenden `worker_prod` gemessen:

```
campaign voll             4348 KB
campaign mit C4           1202 KB   (-72 %)
campaign_luecken          3146 KB   <- der Nachlade-Read, GRÖSSER als der Mount
campaign_luecken + Flag   1253 KB   (-60 %)
```

**Der Nachlade-Read war größer als das, was C4 eingespart hatte** — der Cut, der
den Hub retten sollte, hat ihn neun Sekunden nach dem Mount umgebracht.

**#1153 setzt #1151 zwingend voraus, und das steht in keinem der beiden
Tickets.** Vor C4 ging der Haupt-Snapshot an `campaign_luecken` *vorbei* und
rief `smoothed_for_campaign/1` ohne Option; das Fenster war für den Mount-Fall
nicht erreichbar. Umgekehrt ist C4 ohne C6 nicht neutral, sondern der Auslöser:

```
C4 ohne C6    Mount entlastet, Nachlade-Read holt die volle Masse (= der Kill)
C6 ohne C4    keinerlei Wirkung auf den Mount
C4 + C6       beides gedeckelt
```

**Das Flag sitzt an EINER Stelle** (`HubWeb.CampaignLive.Updates.scope_extra/1`,
gereicht durch `Snapshot.start_scope_load/3`), nicht bei den drei Aufrufern.
Läge es dort, müsste jeder Ladeweg es kennen — und der eine, der es vergisst,
holt still die volle Masse. Genau so ist es passiert. Ein Quelltext-Wächter
(`glatt_flag_guard_test.exs`) hält das fest: kein `campaign_luecken`-Read ohne
`scope_extra/1`. Nötig, weil das Fehlen **keinen Fehler erzeugt** — kein roter
Test, keine Warnung, nur ein Server, der beim Öffnen einer Seite stirbt.

**Nachgeladen wird über IDs, nicht über Indizes** (`HubWeb.CampaignLive.GlattFenster`,
Auslöser: Mount, Scope-Reload, Fensterschritt, Ansichtswechsel). Das
Anzeige-Fenster gleitet über die **gefilterte** Ansicht, das Lade-Fenster des
Workers über die **ungefilterte** Blockliste — ein Index in der einen ist keiner
in der anderen. Und ein `text_from` gibt es bewusst nicht (#1152): die Texte
sind eine beliebige Teilmenge, kein Suffix. Deshalb entscheidet pro Block die
**Anwesenheit des `text`-Schlüssels** (`Map.has_key?`), nie sein Wahrheitswert:
ein Block ohne auflösbaren Roh-Text trägt legitim `nil`, und ein
Wahrheitswert-Test forderte ihn bei **jedem** Re-Render neu an — im
Kurations-Feld also bei jedem Tastendruck, direkt in die #1149-Schlange.

Der #883-Anker („N noch ohne Text") zählt die unbetexteten der **gefilterten**
Liste **und rechnet das schon Nachgeladene ab** — dieselbe Regel wie
`fehlende_ids/2`. Der erste Wurf zählte nur auf dem rohen Skelett; nachgeladene
Texte liegen aber in `glatt_texte` und **nie** im Skelett, also blieb die Zahl
nach jedem Nachladen stehen und der Anker verschwand nie (an seattleV4 S3:
„426 noch ohne Text" beim Mount und 426, wenn alles geladen ist). Er bleibt
stehen, solange die Zahl über 0 ist — ein Deckel ohne erreichbaren Rest wäre
Datenverlust.

**Alle fehlenden Texte holt EIN Task, in einer Schleife (#1181).** Eine
Anforderung trägt höchstens 200 IDs. Am laufenden `worker_prod` gegen seattleV4
nachgemessen (`campaign_luecken` mit Fenster-Flag):

```
S#  Blöcke  mit Text  gefiltert(kuratieren)  sichtbar(150)  davon ohne Text
1     734      10           244                  150            148
2    1574     200           405                  150             99
3    1802     200           482                  150             94
5    1207     200           358                  150             89
                                                        Summe:  430
```

Die Kuratieren-Ansicht ist überall Default, ihre Treffer streuen über die ganze
Sitzung, und der Worker-Tail ist das **Ende** — beim Mount sind deshalb **430
von 600 sichtbaren Blöcken** ohne Text, also drei Reads.

**Die erste Fassung (C6, Release 398) kettete diese Reads in der LiveView** —
jede Antwort ein `assign`, jedes `assign` ein Render der Geglättet-Spalte (600
Blöcke, bis zu 1200 `List.myers_difference`-Wort-Diffs), vier Renders in unter
einer Sekunde statt einem. Am 07.09.2026 starb der Prod-Hub auf diesem Release
bei jedem Öffnen einer Kampagne (fünf Kills in sieben Minuten), und diese Kette
war der **Verdacht**. Seit #1181 läuft die Schleife in
`GlattFenster.lade_texte/2` **im Task**: Read für Read bis leer, die LiveView
bekommt **ein** Ergebnis und rendert **einmal**; die Closure trägt nur die
ID-Liste (nicht `smoothed`, nicht `socket.assigns` — alles darin kopiert der
BEAM in den Task). Ein Quelltext-Wächter hält beides fest.

**Gemessen hat das den Kill NICHT erklärt** (#1169-Marken, Prod 17:39, zwei
Tabs, Tabelle in #1181): Mount 1 starb **zwei Sekunden nach dem
`campaign`-Render, bevor ein einziger Slice-Read lief**. In Mount 2 (Tabs um
2 s versetzt, überlebt bei 318 MB) laufen die vier Slice-Renders bei
**konstantem** LiveView-Heap (33–35 MB), `anon` fällt dabei. Die Spitze ist
die **`campaign_luecken`-Phase** — Skelett-Read 1253 KB → 5317 Blöcke → Apply
→ Render: pro Tab LiveView-Heap 10 → 36 MB und Pod-`anon` **+84 MB**; zwei
Tabs zugleich in dieser Phase sind +168 MB auf einen Sockel von 226. Die
#1149-Schlange serialisiert die **Reads**, nicht Apply und Render — und die
Reads sind kurz genug, dass sich die Phasen überlappen. Die `campaign`-Phase
(C4) ist dagegen billig (+40 vorübergehend). #1181 ist damit **Hygiene, kein
Fix** für den Mount-Kill; der Hebel liegt in der Skelett-Phase (Größe 5317
Blöcke, `rebuild_refs`, 600-Block-Render, Tab-Überlappung) — eigenes Ticket.
~~Sofort wirksam wäre allein Größe 0.5: 165 + 2 × (20 + 84) ≈ 373 passt unter
477, nicht unter 381.~~ **Hochstufen ist ausgeschlossen** (Tom, 10.09.2026):
Prod bleibt auf 0.4 / 381 MiB, Speicherprobleme werden im Code gelöst — s. #1198
weiter unten.

**Was `rebuild_refs` aus dem Skelett macht (#1187, lokal mit dem Hub-Code auf
RPC-Daten von seattleV4 nachgerechnet):** Skelett 2,47 MB Heap,
`block_source_map` 1,34 MB (wurde **zweimal** gebaut), `utterance_refs_index`
0,55 MB, `sync_index` 3,09 MB (flach 6,77) — und **`sync_index_json` 2,56 MB
als Binary, gegen 0,12 MB ohne Skelett: Faktor 21.** `build_sync_index` trägt
für jeden der 5317 Blöcke einen `{"glatt", id}`-Eintrag, ob im DOM oder nicht
(sichtbar sind 600). Dieser String hing als `data-sync-index` am Wurzel-`div`
der CampaignLive: bei **jedem** der fünf Scope-Reloads HTML-escaped ins Render,
gegen den alten Wert gediffed (alt UND neu gehalten), gepusht, transportkodiert
— große Binaries außerhalb des Prozess-Heaps, für jeden Tab. Seit #1187 geht
der Index als **`push_event("sync_index")`** an den Hook (`Updates.pushe_sync_index/2`):
einmal kodiert, nichts escaped, nichts gediffed, nichts im Socket gehalten;
und die `block_source_map` wird einmal gebaut. **Ehrlich:** über den Draht geht
er weiterhin ~2,5 MB; kleiner wird er erst mit Hebel 1 aus #1184 (nur
gerenderte Blöcke) — **seit #1198 eingelöst:** der Index trägt nur noch die
gerenderten Blöcke, die `block_source_map` und `utt_sessions` sind weg (die
Quellen kommen aufgelöst vom Worker) — und ob #1187 die
`anon`-Lücke schließt, ist Folgerung aus der LiveView-Mechanik, nicht gemessen. **Eine Grenze aus dem Review:** `start_async` bricht
einen laufenden Task gleichen Namens ab (#1122-Klasse); eine Betrachter-Aktion
mitten im Laden verwirft jetzt alle bisherigen Runden statt nur der laufenden
— nichts war quittiert —, die nächste Aktion holt sie neu.

**Die Quittung bleibt, mit einer Schärfung.** `quittiere/3` trägt jede
**beantwortete** ID ein, auch die, auf die der Worker nichts geliefert hat (als
`%{}`) — sonst forderte der nächste Fensterschritt dieselben unbekannten IDs
erneut an (Re-Smoothing vergibt neue Block-IDs). Die IDs eines
**gescheiterten** Reads werden dagegen nicht quittiert: was vorher ankam, wird
übernommen, der Rest bleibt „fehlend" für die nächste Betrachter-Aktion. Ein
Timeout der #1149-Schlange ist kein „gibt es nicht".

**Ein Scope-Reload allein macht Texte nicht frisch.** Er ersetzt `smoothed`,
lässt `glatt_texte` aber bewusst stehen (sonst würfe jede Kuration alles
Nachgeladene weg, und gelesene Blöcke würden wieder leer). Weil `block_texte/4`
neben `text` auch `vorschlag_text`, `vorschlag_modell` und `override` trägt,
zeigte ein einmal nachgeladener Block sonst bis zum Neuladen der Seite den
Stand seines ersten Ladens: nach `LueckenVorschlagGeneriert` fehlte das 💡 in
der Standardansicht (bei jedem der hunderten Ereignisse eines Gap-Fill-Laufs),
nach `manuell_korrigiert` blieben ✎-Zeile und „von X" veraltet. An seattleV4 S1
umfasst der Tail 10 Texte — praktisch jeder dort kuratierte Block war
betroffen. `Updates.scope_reload/3` verwirft deshalb **gezielt die eine
Block-ID** aus der Event-Payload, bevor der Reload startet; ein Leeren des
ganzen Bestands wäre genau das Flackern, gegen das `glatt_texte` überhaupt
getrennt liegt. `stutze_glatt_texte/2` räumt beim Apply zusätzlich die Waisen
weg, die ein Re-Smoothing mit neuen Block-IDs hinterlässt.

**Fünf Funde im Bestand, die dieser Cut ausgelöst hat.** `components.ex`
396/400, `gap_marker.ex:22` und die heex-Zeilen 1346/1351 werfen
`BadBooleanError`, wenn ein Block `hat_luecke` nicht trägt (`nil and …` — die
#710-Klasse). Bisher unsichtbar, weil sie ausschließlich im Template liefen; der
Nachlade-Auslöser ruft `glatt_view_for` erstmals außerhalb davon. Alle fünf auf
`== true` gezogen. Dazu war der eigene Pfad nicht robust: bei einem Teil-Socket
(Test, Fehlerzweig, Reload vor dem ersten Snapshot) hätte er einen `KeyError`
geworfen — im Render-Pfad, also die ganze Seite. Jetzt no-op. Ein fehlender Text
ist ein Schönheitsfehler, ein Absturz kostet alles.

**Ehrliche Grenzen:**

- **Ob es reicht, ist eine Vermutung, keine Zahl.** Der Hub stirbt bei
  1202 + 3146 KB; dass er bei 1202 + 1253 überlebt, ist **nicht gemessen**. Die
  Mount-Messzeile (#1169) liefert die erste Prod-Zahl nach diesem Deploy.
- **Das Fenster deckelt die Texte, nicht die Struktur.** Von den 1253 KB ist der
  größte Teil Skelett (5317 Blöcke à ~240 Byte), und das wächst linear mit der
  Kampagne. Kein Cut dieses Epics adressiert das.
- **Die kleinste Sitzung bekommt 10 betextete Blöcke statt 200** (der
  Mindestrest aus dem Gesamtbudget). Sie ist die älteste und steht in der
  Kuratieren-Ansicht oben — das kann nach zu wenig aussehen. Bedienproblem, kein
  Speicherproblem; eigenes Ticket **nach** der Mount-Zahl, weil jede
  Budget-Änderung die 1253 KB wieder nach oben schiebt.
- **Ein Block ohne Text zeigt „Text wird geladen …"** statt einer leeren Zeile
  hinter dem Doppelpunkt — bei 430 Blöcken beim Mount ist der Unterschied
  zwischen „lädt noch" und „ist leer" keine Kosmetik. Bleibt eine ID
  unbeantwortet, bleibt der Platzhalter allerdings stehen, und der Anker zählt
  sie nicht mehr mit (sie ist ja nicht mehr holbar).
- **Die ✓/🚫-Plakette rendert vor ihrem „von wem".** `status` ist ein
  Skelett-Schlüssel, `override` ein Text-Schlüssel — solange der Text fehlt, ist
  der Tooltip „von " leer (kein Absturz: `nil["set_by"]` ist in Elixir `nil`).
  Das heilt sich mit dem Nachladen, ist also ein Fenster von Sekunden.
- **Kein Seed erreicht diesen Pfad.** Romeo (Folger) hat auf Prod 174 Blöcke,
  alle mit Text; die Romeo-Demo ist kleiner. Nur seattleV4-große Daten zeigen
  das Verhalten — alle Zahlen hier stammen deshalb aus RPC-Messungen am
  laufenden `worker_prod`, nicht von einer Teststage.

### Reload-Schleife bei `no_worker` (Issue #1183)

Beim Rolling-Deploy hängt der Worker noch am alten Pod, während die
CampaignLive im neuen schon läuft. In dieser Lücke drehte die Ansicht eine
Schleife: **429 `:reload`-Runden in 66 s für einen Tab** (~6,5/s), jede mit
`voll_read_start`/`voll_read_error reason=no_worker` — im Moment mit der
wenigsten Luft. Der Kreis, am Code gelesen: `:reload` → Voll-Read scheitert
sofort mit `{:error, :no_worker}` (`Hub.Reader` hat dafür keine Frist) →
`Snapshot.nachlade_glatt/2` (C4, #1151) bekam das **Tupel**, seine drei
Schutzklauseln matchten aber nackte **Maps** und griffen nie → der Catch-all
startete den Skelett-Read auch nach einem gescheiterten Voll-Read → der
scheiterte ebenfalls sofort → sein Fehlerzweig ruft `schedule_reload`
(150 ms) → von vorn. Der C4-Test fütterte genau die Map-Form, die der
Produktionspfad nie liefert, und war grün, während die Klauseln tot waren.

**Was #1183 NICHT ist: ein Speicherfix.** Am Prod-Log vom 07.09., 21:58
belegt — die Kette lief mit **lebendem** Worker: `workers_changed` → `campaign`
(9,6 MB, GC 4,1, `anon` 197) → `campaign_luecken` (38,7 MB, GC 16,6, `anon`
250 → 262) → Kill nach 14 s (kernel-bestätigt, exit 137). Kein `no_worker` in
dieser Kette. Der Voll-Read **gelingt** dort, liefert wegen C4 kein `smoothed`,
und der Skelett-Read startet völlig korrekt — auch mit diesem Fix. Die Höhe
kommt aus der Skelett-Phase (#1184, Hebel 1: Index nur für gerenderte Blöcke).
#1183 nimmt die **Wiederholung** der nutzlosen Runden, nicht die Höhe der
Spitze. Wer es als Speicherfix liest, wartet auf eine Wirkung, die ausbleibt.

**Der zweite Antrieb desselben Moments: ein Doppel-Read pro Rejoin.**
`reload_dirty?` (#321) bedeutet „während des laufenden Reads kamen Änderungen,
die er nicht gesehen hat" — es wurde aber nur beim **Mount** und beim
**Abarbeiten** gelöscht, nie beim **Start** eines Reads. Ein `:reload` aus der
`no_worker`-Kette überlebte damit den Start des nächsten, erfolgreichen Reads
und erzwang dahinter einen **zweiten Voll-Read samt zweiter Skelett-Phase**. Am
Prod-Log belegt (19:19:28 und 21:58): nach jedem gelungenen
`workers_changed`-Read folgte innerhalb einer Sekunde `anlass=reload` mit
**identischem** `snapshot_words=295913`, die zweite Skelett-Phase mit `anon`
309. `start_snapshot_load/2` löscht das Flag jetzt beim Start — der Read, der
dort beginnt, sieht alles bis jetzt; nur was **danach** eintrifft, ist ein
echter Nachläufer. Der Nachlauf-Zweig löscht es weiterhin selbst, sonst liefe
er endlos. **Ehrliche Grenze:** bei echten Events während eines Reads bleibt
der Nachlauf-Read — dort ist er richtig; halbiert ist damit der Rejoin-Fall,
nicht jeder Doppel-Read.

Seit #1183 matcht `nachlade_glatt/2` das Tupel: `{:ok, %{"smoothed" => _}}`,
`forbidden`, `not_found` → nichts; `{:ok, %{}}` ohne `smoothed` → Skelett-Read;
**jeder Fehler → nichts**. Ein Fehler löst keinen weiteren Read aus; der
Ausgang aus `no_worker` ist wie immer `workers_changed`. Damit ist nebenbei die
C4-Zusage „kein zweiter Read, wenn ein Alt-Worker `smoothed` schon mitliefert"
erstmals eingelöst. Bewusst unverändert: `schedule_reload` im Fehlerzweig eines
**einzelnen** Scope-Reads bei lebendem Worker (dort richtig), und die fehlende
Frist im Reader bei `no_worker` — nicht die Ursache, der Kreis lief nur, weil
ein Fehler einen weiteren Read auslöste. Ein Quelltext-Wächter hält fest, dass
der Aufrufer das Tupel übergibt; sonst kippt es beim nächsten Umbau wieder
still.

### Die Geglättet-Spalte bekommt nur, was sie zeigt (Issue #1198, Epic #1146)

Am 10.09.2026 zwischen 07:30 und 07:31 UTC wurde der Prod-Hub dreimal
gekillt (exit 137), jedes Mal von **einem einzigen** Kampagnen-Tab der
Seattle-Kampagne, der sich nach jedem Neustart wieder verband — Release v404,
also schon mit #1187. Der Kampagnen-Read gelang jedes Mal (`anon` ~190 von
381 MB), zwei Sekunden später starb der Hub in der Skelett-Phase, bevor sie
eine einzige Messzeile schreiben konnte. Am 07.09. hatte ein Tab noch
überlebt; ob die Daten gewachsen sind oder #1187 etwas verschlechtert hat,
ist ohne diese Marke nicht zu sagen.

**Die Vorgabe, die daraus folgt (Tom):** alle Daten liegen im Worker, an den
Hub geht nur, was er anzeigt. Der Hub hat bis hierhin das Skelett aller
Blöcke geholt (5.317, davon ≤ 600 sichtbar) und daraus Ansicht, Filter,
Zähler, Fenster, 🕳-Marker, Block-Karte und Sync-Index selbst gerechnet.

**Gebaut in zwei Merges**, weil der Hub vor dem Worker-Autoupdate deployt
(und der Boot-Guard #500 den Worker zurückrollen kann) — ein neuer Hub fragt
also minutenlang einen alten Worker. **Release 1 (Worker)** gibt dem Worker
zwei Fähigkeiten, beide verhandelt, beide ohne Wirkung, solange der Hub nicht
danach fragt:

- **Scope `campaign_glatt_ansicht`** (`Worker.Repo.GlattAnsicht`): pro Session
  Kopf, wirksame Ansicht samt Auto-Vorschlag (`kuratieren`, solange es
  Kuratierbares gibt, sonst `einfach` — die Regel von
  `Components.glatt_view_for/2`), `kuratieren_count`, `block_count`,
  `gefiltert_total`, `from` und als `blocks` **nur das Fenster** (Tail oder
  `from`/`count` über die gefilterte Liste, Deckel 200), jeder Block mit Text.
  Dazu `luecken_marker` und das Echo `nur` (Teil- oder Vollantwort).
- **`"refs" => "aufgeloest"`** an `campaign`, `campaign_summaries`,
  `campaign_chronik`, `campaign_epos` (`Worker.Repo.GlattQuellen`, eingehängt
  in `Worker.Repo.snapshot/1`): Resümee, Chronik, Epos-Kapitel und Alt-Epos
  tragen `quell_utterance_ids` (Semantik exakt wie bisher
  `Refs.resolve_source_refs/2`, kampagnenweit, weil Chronik und Alt-Epos
  sessionübergreifend zitieren), die Antwort trägt `luecken_marker`. Ohne Flag
  byte-identisch.

**Der Marker ist in jeder Antwort vollständig** (`summary:<sid>`,
`chronik:<id>`, `epos_chapter:<id>`), auch in der schmalen Chronik-Antwort —
der Hub kann die Menge ersetzen, statt sie je Scope zusammenzuflicken.
**Fehler kosten keine Antwort:** `Worker.HubClient.Rpc.on_snapshot/2` fängt
nichts ab, eine Exception träfe den Socket-Prozess, und der Reconnect löste in
jeder Ansicht einen Voll-Read aus. Beide Module fangen und loggen laut.

**Zahlen.** Auf einem Nachbau der Seattle-Blockverteilung (Test
`glatt_ansicht_groesse_test.exs`, `LORE_MESSWERTE=1` zeigt die Werte): alter
Skelett-Read 1.178 KB (in Prod gemessen: 1.253 KB), neue Anzeige 443 KB; beim
Hub kommen 600 statt 5.317 Block-Maps an. Die Rechenzeit im Worker bleibt
gleich. Die Prod-Zahl liefert die Messung am laufenden `worker_prod` nach
Release 1 — sie steht in #1198, nicht hier, bis sie gemessen ist.

**Release 2 (Hub)** fragt danach. `HubWeb.CampaignLive.GlattAnsicht` lädt
die Spalte nach jedem erfolgreichen Voll-Read (`:alle`) und nach einem
Fensterschritt, Ansichtswechsel oder Lücken-Event (nur die betroffene
Session); der Hub hält nur noch UI-Zustand (gewählte Ansicht, Fenster je
Session) und zeigt, was kommt. Die „ältere/neuere anzeigen"-Zahlen folgen aus
`from`, der Blockzahl und `gefiltert_total`. `GapMarker` übernimmt die
Marker-Menge des Workers, `Refs.quell/1` ist die eine Lesestelle für Quellen,
der Sync-Index trägt nur die gerenderten Blöcke. `GlattFenster`,
`glatt_view_for/2`, `glatt_blocks/2` und die Block-Karte sind entfernt.

**Drei Fallen, am Code geprüft und in Release 2 geschlossen:**
`campaign_live.ex` macht bei einem gescheiterten Scope-Read einen Voll-Reload
— für diesen Scope wäre `unknown_scope` eine Schleife mit **lebendem** Worker.
Der Ansicht-Read hat deshalb einen eigenen Async-Namen (`:glatt_ansicht`) und
einen eigenen Ergebnis-Zweig, der **nie** `schedule_reload` auslöst: alter
Worker → Hinweis „Der Worker wird gerade aktualisiert" in der Spalte, sonstiger
Fehler → der alte Stand bleibt; der Ausweg ist `workers_changed` nach dem
Worker-Update. `start_async` mit gleichem Namen bricht den laufenden Task ab
(#1122) — höchstens ein Ansicht-Read je LiveView, Wünsche währenddessen
sammeln sich als Nachlauf. Und die vom Worker gewählte Ansicht geht nie als
Wunsch zurück (nur eine vom Betrachter gewählte), sonst stürbe der
Auto-Wechsel. Quelltext-Wächter in `glatt_ansicht_test.exs` und
`glatt_flag_guard_test.exs` halten alle drei fest.

**Test-Doppel:** `HubWeb.ReaderStub` beantwortet jeden Read mit derselben
Antwort; `stub_reader_fn!/1` (ConnCase) nimmt stattdessen eine Funktion des
Scopes — nötig, sobald Haupt-Snapshot und Ansicht verschieden antworten
müssen. `Fixtures.snapshot/1` trägt die Ansicht-Schlüssel mit.

**Auf zwei Teststages nachgemessen** (10.09.2026, seattleV4 per Event-Replay
vom `worker_prod` eingespielt; Zahlen und Verfahren in #1198): das Neu-Laden
eines Tabs kostete auf dem alten Weg **+193 MB** Spitzen-RSS über dem
Ruhewert (LiveView-Heap ~58 MB), auf dem neuen **+37 MB** (~11,5 MB).
Entwicklungsmodus ohne Cgroup-Grenze — vergleichbar ist der Zuwachs, nicht
die absolute Zahl.

**Dabei gefunden: der Websocket-Prozess behält den Müll großer Frames.** Der
Prozess, der die Verbindung eines Tabs hält (`Bandit.DelegatingHandler`),
trug nach dem Laden 29–32 MB (alter Weg 50), die Worker-Verbindung 7,5–9 MB —
ein erzwungener GC brachte beide auf praktisch null. Jeder Diff wird dorthin
kopiert und zu JSON kodiert; ein ruhender Prozess räumt nicht auf, und mit dem
Standard-`fullsweep_after` (65.535) liegt der Müll im alten Heap. Seitdem
`fullsweep_after: 0` an beiden Sockets (`HubWeb.Endpoint`), dazu
`HubWeb.TransportGc` (`on_mount`, `after_render`): **1 s** nach einem Render
wird der Verbindungsprozess aufgeräumt, höchstens einmal je Sekunde — sofort
aufgeräumt, wäre der große Frame noch gar nicht da, denn `after_render` läuft
vor dem Versand. Der Worker-Kanal räumt nach `snapshot_response` ebenso auf.
**Aufgeräumt wird per `:erlang.garbage_collect/1` aus einem Timer, nie per
Nachricht an den Verbindungsprozess:** die erste Fassung schickte ihm
`:garbage_collect` — `Phoenix.Socket` kennt das, der LiveView-Test-Client
(`Phoenix.LiveViewTest.ClientProxy`) nicht, und ein Test, der länger als die
Sekunde lebte, starb daran (PR #1201, CI-Lauf 1026; lokal unsichtbar, weil
kaum ein Test so lange lebt). `transport_gc_liveview_test.exs` hält eine
Ansicht absichtlich länger offen.
Gemessen beim Seitenaufbau: ohne 31,9 MB bleibend, mit 0,0 MB nach 3 s. Die
kurze Spitze beim Kodieren (~29 MB) bleibt — der Fix nimmt das Liegenbleiben,
nicht die Spitze. Quelltext-Wächter in `transport_gc_test.exs`.

**Ehrliche Grenzen.** Das Fenster gilt **je Session** — bei 20 Sessions sind
es 1.000 Blöcke (seit #1204 Tail 50, vorher 150 → 3.000); ein globaler Deckel
ist eigene Arbeit. Jede angereicherte
Antwort dekodiert die Blöcke aller Sessions im Worker (Kosten dort, nicht im
Hub). **Die Hub-Wirkung ist lokal gemessen, nicht in Prod** — die Prod-Zahl
liefert die `voll_read_rendered`-Marke für `campaign_glatt_ansicht` nach dem
Deploy (#1169), sie steht dann in #1198. Der Sync-Index kennt nur die
gerenderten Blöcke — zitiert ein Eintrag nur Blöcke außerhalb des Fensters,
hat er in der Geglättet-Spalte kein Ziel, bis jemand dorthin blättert. Die Scopes
`campaign_luecken`/`_slice` bleiben bis zu einem Folge-Ticket im Worker, damit
ein zurückgerollter Hub weiter funktioniert.

### Der erste Aufbau zeichnet nur, was man sieht (Issue #1204, Epic #1146)

Nach #1198/#1200 blieb eine Spitze beim **ersten** Aufbau: Prod-Marke vom
10.09.2026, 16:07 UTC, seattleV4 — `anon` 159 → 303 MB von 381, LiveView-Heap
nach dem Render der Geglättet-Ansicht 41 MB. Auf einer Teststage mit
seattleV4 (Event-Replay vom `worker_prod`) und **echtem Browser**
(Headless-Chromium über WebDriver, Login-Cookie aus dem Stage-Hub)
nachgestellt: Lesen 28 MB, Bearbeiten 30–42 MB. `LiveViewTest` ohne Browser
reproduziert das **nicht** (Spitze 7–11 MB) — der Browser stellt den
gemerkten Modus und die Hooks wieder her, der Test nicht.

**Gemessen wurde zweimal, weil die erste Messung zu grob ist.** Die
Heap-Abtastung (jede Millisekunde `total_heap_size` der Ansicht) springt in
Erlangs Heap-Stufen und streut bei identischem Stand um 10 MB. Entschieden
hat eine deterministische Messung: an der offenen Ansicht die Seite so
rendern, wie der Channel es beim ersten Aufbau tut
(`Renderer.to_rendered/2` + `Diff.render/4` mit frischen Fingerprints, alle
Assigns als geändert markiert — `__changed__: nil` scheitert am Layout), je
Variante der Assigns, und die Diff-Größe vergleichen:

```
Bearbeiten, wie geladen              3,94 MB
  ohne Review-Liste (567 Fakten)     3,27
  ohne Fakten-Spalte (860 Fakten)    2,49
  Fakten 50 je Session               2,83
  Geglättet 50 je Session            2,99
  alle drei Hebel                    1,22   (-69 %)
Lesen, frischer Aufbau               1,47
  Geglättet 50 je Session            0,52   (-65 %)
```

Ein Voll-Render braucht im Render-Prozess ~18 MB Heap für 3,94 MB Diff — die
Spitze ist ein Vielfaches des Diffs, jede Einsparung schlägt mehrfach durch.

**Gebaut, alle drei nach dem #1198-Muster** (der Worker hält die Liste, der
Hub bekommt, was er zeigt):

- **Geglättet 50 statt 150 Blöcke je Session** (`@tail_default` in
  `Worker.Repo.GlattAnsicht`, `HubWeb.CampaignLive.GlattAnsicht.tail/0`). Eine
  eigene Zahl — `Components.window_default/0` bleibt 150 fürs Protokoll.
  Lesen-Spitze 28 → 12–16 MB (Abtastung, je drei Läufe).
- **Die Review-Liste reist nur als Zahl.** Mit `"review_facts" => "anzahl"`
  im `campaign`-Scope schickt der Worker `review_facts_count` statt der Liste
  (`Worker.Repo.FaktenFenster.review/4`); `HubWeb.CampaignLive.ReviewListe`
  holt sie über `campaign_review_facts`, wenn jemand aufklappt, und verwirft
  sie beim Zuklappen. Vorher ging sie zu **jedem** Betrachter (1,15 MB Heap,
  auch im Lesen-Modus und bei Mitgliedern, denen sie nie gezeigt wird) und
  wurde im zugeklappten `<details>` trotzdem vollständig gezeichnet. Das
  Akkordeon ist jetzt server-verwaltet (Muster #836) — nur so weiß der Hub,
  wann er laden muss.
- **Die Fakten-Spalte bekommt je Session ein Fenster.** Der
  `campaign_facts`-Scope nimmt `"fakten_tail"` (50) und `"fakten_fenster"`
  (geblätterte Fenster je Session) und antwortet mit `fakten_fenster`
  (`%{session_id => %{"total", "from"}}`, `Worker.Repo.FaktenFenster.fakten/2`).
  „ältere/neuere anzeigen" läuft über das Event `fact_fenster`
  (`HubWeb.CampaignLive.FaktenFenster`, dieselbe Schritt-Rechnung wie
  Protokoll und Geglättet, Deckel 200). **Die Anfrage entsteht an EINER
  Stelle** (`FaktenFenster.ergaenze/3` in `Snapshot.start_scope_load/3`): der
  Scope wird aus drei Wegen geladen (Wechsel nach Bearbeiten, Kurations-Event,
  Blättern), und der eine, der das Feld vergisst, holte still wieder alles
  (#1153-Lehre).

**Mischbetrieb.** Ohne Flag antwortet der Worker byte-identisch — ein
zurückgerollter Hub merkt nichts. Ein neuer Hub vor dem Worker-Update bekommt
die Review-Liste weiterhin mit (die Zahl wird aus ihr gezählt, gezeichnet
wird sie erst beim Aufklappen) und die volle Fakten-Liste ohne
`fakten_fenster` (dann zeigt die Spalte alles wie bisher, ohne Blätterknöpfe);
Geglättet-Sessions ohne Wunsch bleiben bis zum Worker-Update bei 150.

**Ehrliche Grenzen.** Wie weit die **Pod-Spitze** (`anon`) sinkt, ist aus
Render-Mechanik und Diff-Größe gefolgert, nicht gemessen — die
`voll_read_rendered`-Marke nach dem Deploy liefert die Zahl (#1204). Die
Teststage läuft mit `debug_heex_annotations`, ihre **HTML**-Größen liegen über
Prod; die Diff-Größe ist davon kaum betroffen. Die Fenster gelten je Session
(20 Sessions = 1.000 Fakten bzw. Blöcke). Die **aufgeklappte** Review-Liste
zeichnet weiterhin alle Einträge — auf ausdrückliche Aktion eines Betrachters
statt für alle. Wer von Bearbeiten nach Lesen zurückschaltet, behält die
schwere Seite (Diff 3,27 MB, Teile per CSS versteckt) — der Preis des
sofortigen Umschaltens aus #1200. Der Sync-Index kennt nur die gezeichneten
Fakten. Blättern lädt die ganze (gefensterte) Spalte neu, nicht nur die eine
Session. Und die Utterance-ID-Liste steht je Fakt weiterhin zweimal als
`phx-value-quell` im HTML (~20 % der Fakten-Spalte) — offen.

### Liegengebliebenes Audio + Deploy-Schutz für die Transkription (Issue #1055)

Am 13.08.2026 fehlte das Transkript eines vollständig aufgezeichneten
Spielabends. Das Audio lag heil auf der Platte, aber niemand transkribierte es
je. Dahinter stecken **zwei** Defekte mit verschiedenen Auslösern — nur einer
hat mit einem Neustart zu tun.

**Der Bootpfad trug schon vorher.** `AudioBuffer.init/1` schickt sich
`:recover_orphans`, der Scan liest den `audio_dir`, holt `SessionEnded` nach
und schickt jedes verwaiste Verzeichnis durch denselben Transcribe-Handoff wie
`finalize`. Ein Auftrag, der einen Neustart nicht überlebt, wird beim
Hochfahren wieder aufgegriffen.

**Defekt A: Verlust OHNE Neustart wurde nie bemerkt.** Der Timer stand
ausschliesslich in `init/1`, ohne Wiederholung — anders als `:sweep_ghosts` und
`:purge_expired`. `Worker.GpuQueue` ist aber ein eigener GenServer unter
`:one_for_one`: stirbt er, verliert er beide Queues, der wartende
`GenServer.call(…, :infinity)` im Transcribe-Task stirbt mit, und der
`DOWN`-Zweig loggt „Audio bleibt … für Crash-Recovery-Retry" — ein Retry, das
es bis zum nächsten Boot nicht gab. Der Kommentar versprach etwas, das der Code
nicht einlöste. Der Scan wiederholt sich jetzt alle **15 Minuten**
(`@recover_interval_ms`) und lebt in `Worker.Recording.AudioBuffer.Recovery`
(der Split war fällig: der `AudioBuffer` riss mit den neuen Zeilen die
1000-Zeilen-Grenze des God-Module-Checks).

**Damit wird eine Frage sicherheitskritisch, die vorher trivial war:** welche
Verzeichnisse der Scan anfassen darf. Beim Boot ist `state.sessions` leer, also
ist alles verwaist. Periodisch liegt dort auch die **laufende** Aufnahme —
griffe der Scan sie auf, bekäme sie mitten im Betrieb ein nachgeholtes
`SessionEnded` und liefe ein zweites Mal durch Whisper. `Recovery.plan/4` ist
pur und sortiert in vier Klassen, deren Reihenfolge die Aussage ist:
**aktiv** (offen inkl. Late-Append-Fenster #949, oder Transcribe-Task lebt —
`GpuQueue.run/2` blockiert, der Task deckt „wartet" UND „läuft" ab) schlägt
alles; dann **leer** (kein `.webm`, eigene Klasse, damit ein Restverzeichnis
nicht über den Versuchsdeckel als Fehlschlag gemeldet wird); dann
**aufgegeben**; sonst **recover**. Nach **drei** erfolglosen Anläufen wird
**einmal laut** aufgegeben (`/admin/errors`, Klasse `recovery_abandoned`) statt
im 15-Minuten-Takt weiterzuversuchen — das ist der „Anhaltspunkt, warum", der
dem Spielleiter fehlte.

**Defekt B: der Idle-Check des Updaters kannte die Transkription nicht.**
`Updater.idle?/0` las `gpu_recording_active?` — das klingt passend, ist aber
ein anderes Signal: `list().recording_active?` sagt, ob eine **Aufnahme**
läuft, nicht ob ein **GPU-Job** läuft. Von den drei `GpuQueue.run/2`-Aufrufern
deckte `pipeline_busy?` nur `pipeline.ex` ab; der Whisper-Lauf aus dem
`AudioBuffer` und die kurations-getriggerte Neuableitung (`Pipeline.Dirty`,
eigener Prozess) liefen ungeschützt. Ein Deploy während der Nach-Transkription
schoss den laufenden Whisper ab. `gpu_busy?/0` zählt jetzt **laufende und
wartende** Jobs (ein Halt verliert wartende ersatzlos — die Queue hält
Closures) und ist im Fehlerfall **konservativ busy**; der abgelöste Check war
an dieser Stelle fail-**open** und liess bei hängender Queue ein Update durch.

**Warum die Queue nicht persistiert wird.** Naheliegend wäre „Warteschlange auf
Platte". Geht nicht: sie hält **Closures**, und eine Closure überlebt keinen
BEAM-Neustart. Persistenz hiesse, die Queue auf serialisierbare Aufträge
umzubauen — ein Eingriff in alle drei Aufrufer, für ein Problem, das das
Verzeichnis auf der Platte bereits vollständig beschreibt. **Das Audio IST der
persistente Auftrag**; es fehlte nur jemand, der regelmässig nachschaut.

**Ehrliche Grenze:** Versuchszähler und Melde-Set leben im Arbeitsspeicher. Ein
Neustart setzt beide zurück, eine dauerhaft abstürzende Sitzung bekommt danach
erneut drei Anläufe. Das entspricht dem bisherigen Verhalten (der Bootpfad
versuchte es immer erneut) und ist keine Verschlechterung — aber es ist auch
kein dauerhaftes Aufgeben.

### Eine abgebrochene Spur reißt die anderen nicht mehr mit (Issue #1054)

Am 13.08.2026 starb die Transkription einer Aufnahme bei **Spur 2 von 18**. Die
restlichen 16 wurden nie transkribiert, und das Audio wurde trotzdem als
erledigt weggeräumt. Gerettet hat den Abend allein, dass ein Archiv-Verzeichnis
gesetzt war — bei `audio_done_dir = nil` heißt Archivieren **löschen**, und der
Mitschnitt wäre weg gewesen. Der auslösende Absturz (#1027) ist längst behoben;
die Struktur dahinter wiederholte das Muster bei jeder künftigen Ausnahme.

**Zwei Mechanismen griffen unglücklich ineinander.** Die Spuren liefen in einem
blanken `Enum.map` ohne Absicherung um die einzelne Datei — die erste Ausnahme
beendete die Schleife. Und der Fehlschlag wurde unterwegs in einen Erfolg
verwandelt: die `GpuQueue` fängt jede Ausnahme im Job-Prozess ab und reicht sie
als **Rückgabewert** weiter, der Task verwarf diesen Wert und endete damit
**normal**. Der `:DOWN`-Zweig sah `:normal` und archivierte. Der `else`-Zweig
daneben, der „Audio bleibt liegen für Crash-Recovery-Retry" verspricht, war für
jede Ausnahme in der Transkription **toter Code** — erreichbar nur noch bei
einem harten Kill von außen.

**Gebaut sind drei Dinge:**

- **Isolierung pro Spur** (`Worker.Recording.Transcribe.Spuren.isoliert/3`,
  eigenes Modul aus demselben Grund wie `Transcribe.Confidence` #791: der
  `Transcribe` steht an der 600-Zeilen-Grenze). Vorbild ist die Fehlerisolierung
  pro Handlungsbogen (#838). **`catch` neben `rescue`** ist kein Zierrat: ein
  `throw` oder `exit` erzeugte vorher **gar keinen** Fehlereintrag, nur die
  Erfolgsmeldung der Warteschlange.
- **Der Ausgang reist mit.** `run_mixed/3` liefert `:ok` oder
  `{:teilweise, keys}`, der Task meldet ihn dem Puffer
  (`{:transcribe_ergebnis, …}`), und `AudioBuffer.Archivierung.entscheide/2`
  entscheidet daraus — nicht mehr aus dem Ende-Grund allein. Bei offenen Spuren
  meldet Stufe 1 **nicht** „ended": im Dashboard stünde sonst „fertig" über
  einem unvollständigen Transkript.
- **Archiviert wird je Spur, nicht je Verzeichnis.** Die geglückten Spuren
  wandern ins Archiv, die gescheiterten bleiben liegen.

**Warum die letzte Feinheit den Ausschlag gibt.** Naheliegend wäre „sobald
etwas schiefging, alles liegen lassen". Das wäre eine **Verschlechterung**: die
Wiederherstellung (`Recovery.recover_files/2`) baut ihre Arbeitsliste aus den
`.webm`-Dateien, die sie im Verzeichnis **vorfindet**. Läge alles noch da,
transkribierte sie beim nächsten Durchgang auch die geglückten Spuren erneut —
in einer Discord-Sitzung sind das hunderte Segmente (real gemessen: 651 Spuren
in einer Sitzung), und jede erzeugte ihre Utterances ein zweites Mal. Aus einem
Loch im Protokoll würde ein doppeltes Protokoll. So braucht die vorhandene
Wiederherstellung **keine Zeile Änderung**: sie findet genau das Offene vor.

**Fail-closed, wenn nichts gemeldet wurde.** Ein Task, der normal endet, ohne
sein Ergebnis gemeldet zu haben, ist kein Beleg für Erfolg, sondern ein
unbekannter Zustand — dann bleibt alles liegen. Das Risiko ist damit ein
doppeltes Protokoll (sichtbar, korrigierbar) statt eines verlorenen Abends
(unsichtbar, endgültig).

**Fund im Bestand, im selben Zug behoben:** das Archivieren löschte das
**Ziel**-Verzeichnis vorab (`File.rm_rf(dest)`) und benannte dann das
Quellverzeichnis um. Solange eine Sitzung genau einmal archiviert wurde, war das
harmlos; mit dem zweiten Anlauf einer teilweise archivierten Sitzung wäre es
Datenverlust **im Archiv** geworden — der erste Lauf legt dort die geglückten
Spuren ab, der zweite hätte sie gelöscht. Verschoben wird jetzt Datei für Datei,
das Ziel wird nie geleert.

**Sichtbar** sind zwei neue Klassen in `/admin/errors` (Stage `stage1`):
`spur_abgebrochen` je Spur und `spuren_unvollstaendig` als Abschluss-Befund über
die Sitzung — letzterer nennt die Zahl der offenen Spuren und sagt zu, dass das
Audio liegen bleibt. Beide stehen in `Stage1Status.classify/1` **ganz vorn**:
ihre Meldungen tragen den Grund der Ausnahme wörtlich mit, und der kann jedes
Stichwort der übrigen Zweige enthalten.

**Ehrliche Grenzen.** Der Transkriptions-Pfad ist ohne Whisper, GPU und
Mnesia-Sitzung **nicht end-to-end fahrbar** — geprüft sind die pure
Entscheidungslogik, die echte Dateibewegung und per Quelltext-Wächter die
Stellen, an denen die Verdrahtung still bricht (`self()` vor der Closure, die
Meldung an den Puffer, der Entscheid über die pure Regel). Dass eine echte
Ausnahme in einer echten Spur so durchläuft, zeigt erst der nächste Vorfall.
Der „automatische zweite Anlauf" ist der bestehende 15-Minuten-Scan aus #1055
mit seinen drei Versuchen; sein Zähler lebt im Arbeitsspeicher, ein Neustart
setzt ihn zurück. Und die vom Ticket mitgeführten kleineren Funde bleiben
**offen**: ein leeres Whisper-Ergebnis gilt weiterhin als Erfolg, es gibt
keinen Abgleich „so viele Audio-Dateien, so viele Utterances", und das
Whisper-Zeitlimit hängt nicht an der Spurlänge.

### Deploy-Gate: aktive Aufnahme erkennen (Issue #703)

Ein Auto-Deploy restartet den Prod-Hub mitten in einer laufenden Session-
Aufnahme (Browser-Mikro → Hub → Worker). Der Restart wird technisch überlebt
(Browser reconnectet, Worker-First-Apply, Hub ist stateless), aber der
Audio-Pfad ist für die Restart-Dauer unterbrochen — bei schlechtem Timing
entstehen unbemerkte Transkript-Lücken. **Bewusst warn-only, kein Blocking-
Gate**: Sessions laufen stundenlang, ein hartes Warten/Retry auf dem
Free-Tier-Single-Replica-Setup wäre ein Verfügbarkeits-Risiko und würde
Merges am Spielabend faktisch verhindern.

- `GET /health/recording` — unauthentifizierter, prod-live Endpoint
  (`HubWeb.HealthController`, eigene `:public_api`-Router-Pipeline, da CI
  sich nicht als Hub-User einloggen kann). Liefert nur
  `{"active_recording": true|false}` — bewusst kein Session-/Campaign-Detail
  an einem öffentlich erreichbaren Endpoint. Backing-Signal:
  `Hub.WorkerRegistry.any_active_recording?/0`, nutzt das bestehende
  `held_sessions`-Tracking (Issue #468) — keine neue State-Quelle.
- **`tools/ci/deploy_gate_check.py`**, als erste Commands im bestehenden
  `deploy`-Step (`.woodpecker/woodpecker.yml`, vor dem `git push --force
  gigalixir`) — immer `exit 0`, gibt bei aktiver Aufnahme nur eine laute
  Log-Zeile aus, deployt aber sofort weiter. Netzwerk-/HTTP-Fehler sind
  fail-open (u.a. der erwartete Fall beim allerersten Deploy nach diesem
  Feature-Merge, wo die noch laufende alte Prod-Version den Endpoint noch
  nicht kennt).
- **Ehrliche Grenze**: kein echtes Blocking-Gate, kein Graceful-Shutdown —
  ein Merge während einer Session restartet den Hub weiterhin, nur jetzt
  sichtbar im CI-Log statt lautlos. Flankierend bleibt Merge-Disziplin am
  Spielabend (vor Merges `curl https://loretracker.gigalixirapp.com/health/recording`
  prüfen).

### Woodpecker-API: eigener Dienst, eigener Token (2026-08-19)

`ci.codeberg.org` ist **nicht** `codeberg.org`. Der Codeberg-Token aus
`~/.config/tea/config.yml` gilt dort nicht — er liefert `401`, und zwar nicht
wegen fehlender Rechte, sondern weil er am CI-Dienst überhaupt keine Gültigkeit
hat. Das war monatelang die Ursache für „Pipeline-Restart geht nur per Klick".

Dazu kommt eine Header-Umkehrung, die einen Fehlversuch kostet, wenn man sie
nicht kennt:

```
codeberg.org    Authorization: token <token>
ci.codeberg.org Authorization: Bearer <token>
```

**Lesen braucht gar keinen Token** — für Status-Polling reicht:

```bash
# Repo-Kennung bei Woodpecker ist die numerische ID, nicht der Slug:
curl -s "https://ci.codeberg.org/api/repos/17296/pipelines?perPage=50&page=1"
# Ein einzelner Lauf mit allen Schritten (workflows[].children[]):
curl -s "https://ci.codeberg.org/api/repos/17296/pipelines/<n>"
```

**`branch` ist bei einem PR-Lauf das ZIEL, nicht die Quelle.** Wer den eigenen
Lauf über `branch == "issue-1153-…"` sucht, findet nichts und hält das für
„die CI hat nicht ausgelöst" — dabei steht dort `branch: "master"` für jeden
PR-Lauf. Die Quelle steckt im `ref`:

```
push          branch=master  ref=refs/heads/master
pull_request  branch=master  ref=refs/pull/<PR-Nummer>/head
```

Gesucht wird also über `ref` (nach der **PR**-Nummer, nicht dem Branch-Namen)
oder über `event`. Kostet sonst eine volle Wartefrist, bevor der Irrtum
auffällt — der Lauf lief die ganze Zeit.

**Schreiben** (Restart, Löschen) braucht einen persönlichen Zugriffstoken aus
<https://ci.codeberg.org/user>. Wo er auf der jeweiligen Maschine liegt, gehört
in die `CLAUDE.local.md` — hier steht nur, dass es ihn braucht.

#### Logzeilen lesen: Token, Pfad, Fallen (2026-09-06)

**Logzeilen brauchen den Token** (anders als die Pipeline-Liste, die ohne Auth
lesbar ist) — und zwar den Woodpecker-eigenen, nicht den aus
`~/.config/tea/config.yml`. **Wo er auf der jeweiligen Maschine liegt, steht in
der `CLAUDE.local.md`**, siehe den Absatz darüber. Ohne ihn liefert der
Log-Endpunkt **HTTP 200 mit der Weboberfläche als HTML**, was wie ein
Auth-Fehler aussieht, aber keiner ist.

```bash
TOKEN=$(cat <pfad-aus-CLAUDE.local.md>)
curl -s -H "Authorization: Bearer $TOKEN" \\
  "https://ci.codeberg.org/api/repos/17296/logs/<lauf>/<step_id>" | python3 -c "
import sys,json,base64,re
lines=json.load(sys.stdin)
txt=''.join(base64.b64decode(l['data']).decode('utf-8','replace')
            for l in lines if l.get('data'))
print(re.sub(r'\\x1b\\[[0-9;]*m','',txt))
"
```

Vier Fallen, jede einzeln schon einen Fehlversuch wert:

- **Header ist `Bearer`**, nicht `token` (umgekehrt zu `codeberg.org`).
- **Pfad ist `/logs/<lauf>/<step_id>`**, nicht `/pipelines/<lauf>/logs/…` —
  letzteres liefert stumm HTML.
- **`step_id` ist nicht die `pid`.** `coverage` hat pid 10, aber step_id
  2713667. Sie steht im Pipeline-JSON unter `workflows[].children[].id`.
- **`data` ist Base64**, einzelne Einträge sind `null` (ungeprüft wirft der
  Dekoder), und die Chunks tragen an ihren Grenzen **keine Zeilenumbrüche** —
  wer zeilenweise filtert, verklebt sich das Ergebnis.

**Warum das hier steht.** Am 2026-09-06 haben zwei Sessions unabhängig
gemeldet, es gebe auf dieser Maschine keinen CI-Token — beide hatten an der
falschen Stelle gesucht und sich gegenseitig bestätigt. In den zwei Stunden
bis zum Fund wurden **fünf** Hypothesen zur Ursache eines roten Schritts
aufgestellt und vier davon selbst widerlegt (Prozess-Kollision zwischen
parallelen Schritten, geteiltes `MIX_HOME`, Runner-Überlast, zu knappe
Wartefristen). Getragen hat am Ende ausschliesslich das Lesen der echten
Fehlermeldung. **Zwei Sessions, die dasselbe nicht finden, sind kein Beleg
dafür, dass es nicht existiert.**

**Und eine dritte Kategorie für die Regel unten:** der Fall war weder „unser
Code“ noch Infrastruktur im dortigen Sinn, sondern **`exit 1` aus der
Umgebung** — reproduzierbar rot in CI, grün auf jeder Entwicklermaschine, weil
der Lauf unter `cover` langsamer ist und Zeitannahmen im Testcode bricht
(#1157, #1158). Ein Neustart wiederholt ihn, ein lokaler Lauf findet ihn nicht.

#### Roter Check heißt fast nie „unser Code"

Gemessen über 786 abgeschlossene Läufe (Juni–August 2026): **23,9 % brechen an
der Infrastruktur ab** (`killed`/`error`), gegenüber 11,5 % echten
Fehlschlägen. Die Quote ist über drei Monate stabil (Jun 25 %, Jul 21 %,
Aug 27 %). In den 50 jüngsten Läufen waren **13 nicht-grün und alle 13
Infrastruktur — kein einziger Code-Fehler**. Codeberg betreibt Woodpecker als
Spendenprojekt; das ist der Preis dafür, und keine Störung, die jemand abstellt.

**Nachmessung 2026-09-06 — die Quote ist gestiegen.** Über die 50 jüngsten
Läufe liegt sie bei **31–34 %** statt 23,9 % (zwei Sessions haben unabhängig
gerechnet und kommen auf 31,1 % bzw. 34,1 %; die Differenz ist die Behandlung
von `canceled`). Echte Fehlschläge unverändert niedrig (~9 %). **Ehrliche
Grenze:** 50 Läufe gegen 786 sind eine Momentaufnahme, dazu zeitlich dicht —
das belegt keinen Trend, aber es widerlegt „stabil bei 24 %".

Herausgerechnet sind dabei **Geister-Läufe**: jeder Push auf einen
Feature-Branch **ohne** PR erzeugt einen Lauf, der mit `error` und
`workflows: 0` endet (`could not load config from forge` /
`pipeline definition not found`) — es startet **kein einziger Schritt**. Diese
Läufe kosten keine Runner-Zeit und belegen keine Bahn, zählen aber roh
mitgerechnet in die Quote (5 von 50, gut 7 Prozentpunkte). Wer die Quote
nachrechnet, filtert sie über das `errors`-Feld der Listen-API heraus. Wer
einen roten Lauf auf einem Feature-Branch sieht, prüft **zuerst**, ob
überhaupt Schritte gestartet sind.

Praktische Folge: **bei rot nicht zuerst im eigenen Diff suchen.** Erst die
Schritte ansehen, dann entscheiden. Weder der Pipeline-Status noch der
Schritt-Status trägt die Antwort — beide können `failure` sagen, wo
Infrastruktur gemeint ist (`#860` und `#844`: `state=failure` bei
`exit_code 0`; `#872`: `status=failure`, gescheitert ist `clone` mit
`exit_code 128`, ein Codeberg-504). Der eine verlässliche Test:

> **`exit_code != 0` an einem Schritt ausser `clone`** ⇒ unser Code, ein
> Neustart wiederholt nur den Fehler. Alles andere (`clone` gescheitert, oder
> `exit_code 0`) ⇒ Infrastruktur, Neustart ist richtig.

Etikette bei mehreren parallel arbeitenden Sessions: fremde Läufe nie ohne
Absprache neu starten, höchstens zweimal selbst neu starten (danach ist es ein
Befund, kein Zufall) — und **nach jedem Restart die anderen informieren, mit
Lauf-Nummer und ausdrücklich dem Ergebnis**. Ein Restart füllt die Bahn: am
2026-08-19 liefen zwei Pipelines parallel, weil eine „die Bahn ist frei"-Freigabe
und ein Restart-Klick in dieselbe Minute fielen.

**Vorprüfung vor jedem Restart: den git-Handshake messen, nicht die API
(2026-09-07).** Drei Läufe in Folge (#984–#986, derselbe Commit) starben am
`clone` mit exit 128 — im Log `git fetch … 504` —, während
`https://codeberg.org/api/v1/repos/…` zur selben Zeit sauber antwortete
(0,03–4,7 s). Der Runner spricht nicht die API, sondern den git-HTTPS-Endpunkt,
und genau der lief dreimal hintereinander in den 30-s-Timeout. Eine Vorprüfung
auf die API sieht grün aus und prüft das Falsche — die Silent-Failure-Klasse in
der Regel selbst. Gemessen wird deshalb der Handshake, den auch der Runner macht:

```bash
curl -s -o /dev/null -w "%{http_code} %{time_total}\n" --max-time 30 \
  "https://codeberg.org/tomloresys/lore-tracker.git/info/refs?service=git-upload-pack"
```

Neu gestartet wird erst, wenn dieser Aufruf **viermal in Folge** `200` unter
5 s liefert — und bei mehreren Sessions startet **genau eine** davon, vorher
abgesprochen, nicht hinterher. Ein Restart in die Störung hinein belegt die Bahn
für Minuten und liefert nur denselben `clone`-Tod noch einmal.

**Nachtrag 2026-09-10: auch der Handshake prüft nicht alles.** Lauf 1020 und
1021 (PR #1199) starben am `clone` mit exit 128, obwohl der Handshake davor
viermal `200` unter 0,35 s lieferte. Das Log zeigt, warum: der Runner klont
partiell (`git fetch --depth=1 --filter=tree:0`) — das gelingt —, und erst
`git reset --hard` holt die Bäume beim „promisor remote" per **POST auf
upload-pack** nach; genau dieser Abruf bekam `504` („could not fetch … from
promisor remote"). Lokal mit denselben Befehlen nachgestellt: ebenfalls `504`.
Das GET auf `info/refs` sieht diesen Abruf nicht. Die belastbare Vorprüfung
sind deshalb **die Runner-Schritte selbst**, gegen den Commit des Laufs:

```bash
D=$(mktemp -d) && cd "$D" && git init -q -b master &&
git remote add origin https://codeberg.org/tomloresys/lore-tracker.git &&
git fetch -q --no-tags --depth=1 --filter=tree:0 origin "+<sha>:" &&
git reset --hard -q "<sha>" && echo OK; cd /; rm -rf "$D"
```

Neu gestartet wird erst nach **drei** `OK` in Folge (je Versuch ein voller
Checkout, also sparsam wiederholen).

#### Aufbewahrung

Woodpecker löscht nichts von selbst; bis 2026-08-19 lagen ~790 Läufe im
Bestand. Aufgeräumt wird jetzt auf die **50 jüngsten**, wobei die Metadaten
(Status, Zeiten, Commit, Titel — ~300 Byte pro Lauf) vorher lokal gesichert
werden. **Was dabei verloren geht, sind die Log-Zeilen**: danach ist
feststellbar, DASS ein Lauf abbrach, nicht mehr WORAN. Wer einer Ursache
nachgehen will, muss das vorher tun.

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

- Issues live on Codeberg at https://codeberg.org/tomloresys/lore-tracker — use `tea issues …`. Dein Codeberg-Login + Token-Setup gehört nach `CLAUDE.local.md` (siehe „Tea CLI" Abschnitt).
- Prod hub: https://loretracker.gigalixirapp.com (Auto-Deploy via Codeberg-Woodpecker bei jedem master-Push, seit Issue #31).
- Local dev hub: http://localhost:4000 (`cd apps/hub && mix phx.server`).
- **Issue-Audit-Snapshot**: `docs/issue-audit-2026-08-13.md` — letzter Relevanz-Snapshot (Milestone-Fit / Gültigkeit / Reihenfolge über alle 45 offenen Issues, jedes inkl. aller Kommentare gegen master `5569ffe` code-verifiziert; Stichtag: nach der Discord-Voice-Serie #985–#1016, den #911-Cuts 1–3 und dem kompletten I7-Fold-Audit; löst `docs/issue-audit-2026-07-22.md` ab). Enthält zusätzlich die Spielabend-Prio-Linse „Bis Sonntag 16.08.". Bei der nächsten Refinement-Runde aktualisieren oder durch ein neueres Stichtag-Doc ersetzen, damit die Liste nicht stale wird.

## Development workflow

**Goldene Regel: jede Zeile Sourcecode hängt an einem Issue. Jedes Issue bekommt genau einen Branch. Bevor der Branch geöffnet wird, holt man sich das Ticket (`tea issues edit -a <dein-codeberg-login> <N>` — Assignee setzen).**

**Session-Start: einmal `git fetch origin master` (via HTTPS-Token wenn SSH-Agent nicht greifbar — siehe `CLAUDE.local.md` für den Token-Trick).** Sonst arbeitet man gegen einen stale `refs/remotes/origin/master`-Ref, `git status` lügt über „N Commits vor origin", und man baut Branches auf einem master der eigentlich schon längst weiterbewegt wurde. Konfliktreiche PRs + redundante Bug-Fixes sind die Folge.

**Coordination-Scan vor Issue-Pick / bei Multi-Session-Fragen** (Issue #330): wenn du ein Issue anpacken willst, oder der User fragt was lokal/woanders läuft → **erst** `ls ~/Projekte/.claude-issue-locks/` + `epmd -names`. **Nicht** den Codeberg-Tracker, **nicht** die per-Worktree `CLAUDE.local.md` (die ist strukturell blind für andere Worktrees). Dateinamen-Konventionen im Lock-Verzeichnis:

| Datei | Bedeutung |
|---|---|
| `<N>.lock` | Issue N wird in einem Worktree bearbeitet (Inhalt: worktree\|pid\|ts\|branch) |
| `pr-test-<PORT>.lock` | PR-Test-Stack auf Port PORT läuft (Inhalt: worktree\|hub_pid\|worker_pids\|branch\|ts) |

Beide werden von den Workflow-Schritten/Mix-Tasks automatisch geschrieben/entfernt. Wenn `epmd -names` mehr Nodes zeigt als das Lock-Verzeichnis listet → andere Session(en) sind crash-gestorben oder eine Mix-Task hat Lücken, nachpflegen.

For every development task the user assigns, follow this loop:

1. **Find a matching issue.** Run `tea issues list -r tomloresys/lore-tracker --state open` and pick the one that fits. If none fits, ask the user whether to file a new one (Default: ja, anlegen via `tea issues create -t … -d … -L <label-csv> -m "<milestone>"`). Ohne Issue keine Codezeile — Ausnahme nur für die unten gelisteten Doc-/Typo-/Hotfix-Sonderfälle.
   - **Neue Issues bekommen immer mindestens einen Label** aus der bestehenden Liste (`tea labels list -r tomloresys/lore-tracker`): primär `feature` oder `bug`; zusätzlich Domain (`llm` / `ui` / `audio` / `infra` / `docs` / `permission` / `mobile` / `i18n` / `architecture` / `live-transcription`); `blocked` falls auf ein anderes Issue wartend. Ungelabelte Issues fallen aus der Filterbarkeit raus und werden vergessen — Labels sind nicht optional.
2. **Take the ticket.** Vor dem Branch das Issue dem aktiven Bearbeiter zuweisen: `tea issues edit -a <dein-codeberg-login> <N>`. So sieht jeder im Tracker wer woran arbeitet, kein doppeltes Anpacken.
3. **Branch-Check + Lock vor Branch-Anlage.** Prüfen ob das Issue schon einen Branch hat — sonst entstehen zwei parallele Branches auf demselben Ticket (z.B. wenn eine andere Claude-Session schon dran ist oder eine alte Session unterbrochen war). Zusätzlich Filesystem-Lock setzen, weil der Codeberg-Comment-Marker einen Race-Window hat (zwei Sessions können gleichzeitig anfangen, bevor eine den Comment postet):
   ```bash
   git fetch origin "refs/heads/issue-<N>-*:refs/remotes/origin/issue-<N>-*" 2>/dev/null
   git branch -a | grep -E "(^|/)issue-<N>-"   # lokal + remote
   tea issues <N> | grep -iE "^[[:space:]]*Branch:"   # Comment-Marker

   # Issue-Lock-Check (Multi-Clone-Schutz):
   LOCKDIR=~/Projekte/.claude-issue-locks
   mkdir -p $LOCKDIR
   LOCK=$LOCKDIR/<N>.lock
   [ -f $LOCK ] && { echo "Issue <N> locked by:"; cat $LOCK; exit 1; }
   ```
   - **Existiert ein Branch ODER ein Lock** → STOP. Bei Branch: an dem bestehenden weiterarbeiten (`git checkout` + `git pull`/`git rebase master`). Bei Lock: andere Session hängt schon dran — anderes Issue picken. Bei stale Lock (PID nicht mehr existent + Timestamp > 6h alt): manuell prüfen, ggf. löschen.
   - **Kein Branch + kein Lock da** → Lock setzen + neuen Branch `issue-<N>-short-slug` anlegen (e.g., `issue-11-self-critic`) **und sofort als Issue-Comment hinterlegen** damit's beim nächsten Check auffindbar ist:
     ```bash
     echo "$(pwd)|$$|$(date -Iseconds)|issue-<N>-short-slug" > $LOCK
     tea comment <N> "Branch: \`issue-<N>-short-slug\`"
     ```
   Genau ein Branch pro Issue — wenn der Scope sich auf etwas anderes ausweitet, neues Issue + neuer Branch. Never work directly on `master`.
4. **Build the change.** Commit each time the code compiles cleanly (`mix compile` passes — tests staying green is preferred but not required for intermediate commits). Small focused commits beat one big WIP commit. Don't push during this phase.
   - **Version bumpen** in `apps/<app>/mix.exs` wenn die Änderung App-Verhalten / Wire-Protocol / Schema berührt. Pre-1.0: Minor (`0.3.0`) bei Feature / rückwärtskompat. Wire-Erweiterung, Patch (`0.2.1`) bei Bugfix / Polish ohne Verhaltens-Änderung. **`shared`-Bump erzwingt `hub` + `worker` mit-bumpen** (Wire/Schema-Sync). Reine Doc-/Doku-/Tooling-PRs brauchen keinen Bump — **ebenso reine Dependency-/Security-Bumps ohne Verhaltensänderung** (z.B. ein CVE-Patch-Update wie #952, der keine Call-Site-Semantik ändert): die Versionszeile in `mix.exs` bleibt unangetastet. Grund: bei parallelen Branches/Worktrees kollidiert sonst dieselbe Zeile unnötig oft beim Merge (jede Berührung ist potenzielle Konfliktfläche); das Signal "diese Version enthält den Fix" steht ohnehin im Commit/PR. Wo doch gebumpt wird: möglichst spät machen (kurz vor dem Merge, nach dem letzten Rebase gegen `master`), nicht schon beim ersten Commit — sonst bumpt man von einem beim Merge längst überholten Stand. Nach Merge auf master: Tags `hub-v<N>` / `worker-v<N>` / `shared-v<N>` lokal setzen + pushen (`git tag … && git push origin --tags` — Token-Trick siehe `CLAUDE.local.md`).
5. **Doku mit-pflegen.** Wenn die Änderung etwas berührt, das in `CLAUDE.md`, `README.md`, `apps/hub/README.md`, `apps/worker/README.md`, `apps/shared/README.md`, `docs/Worker-Setup.md`, `docs/Spieler-Anleitung.md`, `docs/Backup-Recovery.md`, `CONTRIBUTING.md` oder einem Modul-`@moduledoc` beschrieben ist, **im selben PR** die Doku nachziehen — nicht in einem Folge-PR. Doku-Drift sammelt sich sonst unsichtbar an, und die nächste Session arbeitet auf falschen Annahmen. Faustregel: wenn ein bestehender Doku-Satz nach deinem PR nicht mehr stimmt, ist es Teil deines PRs ihn zu fixen. Gilt auch für gelistete Befehle, Pfade, Env-Vars, Architektur-Skizzen und Workflow-Schritte.
6. **Test-Instanz hochfahren** mit `mix lore.pr_test.spawn` (Issues #186 + #190, ab Issue #167). Detect current branch via `git rev-parse`, räumt stale Stacks auf den eigenen Slot-Ports ab, wählt freien Port aus dem cwd-Slot in `CLAUDE.local.md` (siehe Local-Setup-Skelett unten), spawnt Hub + pre-gepairten Worker als detached BEAMs, seedet die Romeo-Schlegel-Demo (Owner = Caller), öffnet den Browser. **Volle Stack-Anatomie + Spawn-Flow + Tear-Down: `docs/PR-Test-Setup.md`.** **Pflicht** bevor die Review-Frage gestellt wird — User muss den Branch klickbar im Browser haben können. Reine Doc-/Typo-/Config-PRs ohne UI-Wirkung dürfen das überspringen; im Zweifel hochfahren. Manuelle Variante mit anderen Flags (`--admins`, kein Seed, expliziter Branch): `mix lore.pr_test <branch> [--seed] [--admins id1,id2]` — siehe `mix help lore.pr_test`.
7. **Ask for review.** Tell the user what was built und **benenne die laufende Test-Instanz konkret** — immer in der Form „**Teststage auf Port `<PORT>` bereit unter http://localhost:`<PORT>`**" (mit der echten Port-Nummer aus Schritt 6). Nie vage „ich teste auf PR-Test" / „getestet auf PR-Test" — der User muss den klickbaren Port direkt vor sich haben, ohne nachfragen zu müssen. Danach frag explizit ob's gut ist („ist das so gut?"). Wait for confirmation.
   - **If yes** → open a pull request to `master` via `tea pulls create`, merge it (`tea pulls merge`). **Der Gigalixir-Deploy passiert ab Issue #31 automatisch** über Codeberg-Woodpecker beim master-Push — **kein manueller `git push gigalixir` mehr** (sonst Doppel-Deploy). Danach Test-Instanz runterfahren + Worktree/Mnesia-Dirs aufräumen + **Issue-Lock entfernen** (`rm -f ~/Projekte/.claude-issue-locks/<N>.lock`). **Den gemergten Branch lokal + remote löschen** — Codeberg behält sonst Branch-Leichen (typischer Backlog wenn niemand putzt):

     ```bash
     git checkout master                       # auf master wechseln (sonst greift -d nicht)
     git branch -d <branch>                    # lokal
     git push origin --delete <branch>         # remote (HTTPS-Token-Trick wenn SSH-agent nicht greifbar — siehe CLAUDE.local.md)
     ```

     Codeberg-Woodpecker deployt seit Issue #31 automatisch beim master-Push (siehe „Deploy"-Sektion) — der frühere manuelle Gigalixir-Push entfällt. **Falls der PR Worker-Code verändert hat** (`apps/worker/` oder `apps/shared/`): den User darauf hinweisen, dass der lokale `worker_prod`-Daemon neu gestartet werden muss (`cd apps/worker && LORE_MNESIA_DIR=… HUB_BASE_URL=https://loretracker.gigalixirapp.com elixir --sname worker_prod --no-halt -S mix run`), damit er den neuen Code gegen den frisch deployten Hub läuft. **Ausnahme**: läuft `worker_prod` als self-updating systemd-Daemon (#492, `LORE_WORKER_AUTOUPDATE=1`), zieht er sich nach dem Hub-Deploy automatisch nach — dann entfällt der manuelle Restart-Hinweis.
   - **If no** → the user will say what to change. Iterate from step 4 (Code + Doku); Test-Instanz weiterlaufen lassen.

Exceptions (don't enforce the branch+PR-loop, kein Issue nötig): pure docs-only tweaks (CLAUDE.md, README, docs/*), trivial typo fixes, or explicitly user-driven hot-fixes can go straight on `master`. When in doubt, branch.


```bash
mix lore.pr_test.spawn                          # Default: current branch, Hub + 1 Worker + Romeo-Schlegel, cwd-Slot-Port
mix lore.pr_test <branch> --seed                # explizite Variante (Branch + Flags)
mix lore.pr_test <branch>                       # leere Mnesia — nur für Onboarding-Flow-Tests
mix lore.pr_test <branch> --seed --admins id1,id2   # Multi-Worker (z.B. pull_since-Tests)
```

**`mix lore.pr_test.spawn`** (Issue #186) ist der Default-Befehl in Schritt 6 — er automatisiert Branch-Detect + Port-Slot-Lookup + Romeo-Seed + Browser-Open. Refuse auf `master` (Sicherheits-Gate gegen Versehen).

**Der Stage-Worker hält NIE das Prod-Discord-Gateway — außer mit `--discord` (Issue #1156).** Am 07.09.2026 fingen Teststages zweimal `/lore`-Befehle ab (Discord stellt eine Interaction genau EINEM verbundenen Worker zu; der Stage-Worker antwortete falsch, Tom verlor einen `/lore start`). Ursache: `load_dotenv/0` in `lore.pr_test.ex` schrieb JEDE `.env`-Zeile per `System.put_env` ins OS-Env — auch über eine in der Shell gesetzte Variable hinweg —, und der detached Worker erbte das echte `DISCORD_BOT_TOKEN`. Das war die Umkehrung von `config/runtime.exs` (dort gewinnt das OS-Env). Seit #1156: `.env` setzt nur noch, was im OS-Env fehlt (`dotenv_neu/2`, pur), und `Runner.worker_env/5` gibt dem Stage-Worker **fest** `DISCORD_BOT_TOKEN=invalid-prtest-token` mit — ein sicherer Default, keine Konvention. Nachweis im Worker-Log: `Discord.BotGate` meldet `:rejected`, nicht „Gateway verbunden". Wer das echte Gateway auf einer Stage braucht, sagt `mix lore.pr_test.spawn --discord` — und weiß dann, dass `worker_prod` es gleichzeitig hält. Port kommt aus dem **cwd-spezifischen Slot** in `CLAUDE.local.md` (siehe Local-Setup-Skelett) — jeder Worktree hat zwei reservierte Ports.

**`--seed` ist Default**: ohne Daten zeigt die UI praktisch nichts (leeres Dashboard, kein Klick auf REC / Edit / Promote / Regenerate möglich). Romeo-Schlegel hat 5 Sessions à mehrere Utterances, pre-generated Resümees / Epos / Chronik — voll-bestückt für jeden Spalten- und Button-Test.

Default-Admin-Discord-ID kommt aus `LORE_LOCAL_ADMIN_DISCORD_ID` (.env). Der Task:

- Wählt freien Port aus dem cwd-Slot in `CLAUDE.local.md` (Discord-OAuth-Redirect-URIs sind für 4000-4007 eingetragen, davon 4001-4006 in 3 Slot-Paare aufgeteilt + 4007 als Reserve)
- Legt Worktree `../lore-pr-$PORT` an
- Mintet JWT direkt aus dem lokalen Hub-Secret (kein Discord-Pair-Klick), pre-seedet das Worker-Mnesia
- Startet Hub + Worker als detached BEAMs (PIDs in `/tmp/pr-$PORT/{hub,worker-0}.pid`, Logs daneben)
- Öffnet Browser auf `http://localhost:$PORT/`
- Trägt den Stack ein in `~/Projekte/.claude-issue-locks/pr-test-<PORT>.lock` (Issue #330, cross-worktree sichtbar)

**PR-Test-Worktrees haben detached HEAD** (Issue #190) — sie zeigen auf den Feature-Branch-Commit, aber ohne Branch-Ownership. Damit kann derselbe Branch auch im aktuellen Worktree ausgecheckt sein (typisch wenn `mix lore.pr_test.spawn` aus dem Arbeits-Worktree heraus läuft). Konsequenz: im PR-Test-Worktree commiten ist nicht gedacht — Änderungen passieren im Arbeits-Worktree, dann normaler `git push` + Hub im PR-Test-Worktree reload.

**Tear-down nach PR-Approval:**

```bash
mix lore.pr_test_down 4001
```

Killt BEAMs via PID-Files, entfernt Worktree, löscht `/tmp/pr-$PORT`, räumt CLAUDE.local.md auf.

**Logs anschauen wenn was schiefläuft:** `tail -f /tmp/pr-$PORT/hub.log /tmp/pr-$PORT/worker-0.log`.

## Local setup recommendation (`CLAUDE.local.md`)

Neue Claude-Code-Sessions auf einer neuen Maschine sollten als ersten Schritt eine eigene **`CLAUDE.local.md`** im Repo-Root anlegen. Die Datei ist in `.gitignore` und gehört dem jeweiligen Entwickler — sie hält maschinen-spezifische Pfade, Ports, Workarounds und Operational-Do-Nots fest, die nirgendwo sonst hingehören (CLAUDE.md = Repo-weit, `docs/Worker-Setup.md` = User-Onboarding, `CONTRIBUTING.md` = Code-Contributor-Onboarding).

Empfohlenes Sektions-Skelett:

```markdown
# CLAUDE.local.md — <name> @ <hostname>

Gitignored. Machine-local context für Claude Code.

## PR-Test-Port-Slots pro Worktree

Jeder Claude-Code-Worktree bekommt einen festen 2-Port-Slot reserviert. `mix lore.pr_test.spawn` matched den aktuellen `git rev-parse --show-toplevel` gegen diese Tabelle und allokiert daraus den ersten freien Port. Format pro Zeile: `- <abs-pfad> → <port1>, <port2>`.

- /home/<user>/Projekte/lore_tracker → 4001, 4002
- /home/<user>/Projekte/lore_tracker2 → 4003, 4004
- /home/<user>/Projekte/lore_tracker_issues → 4005, 4006

Reserve / ad-hoc: 4007. Discord-OAuth-Redirect-URIs müssen für **alle** verwendeten Ports einmalig in der Discord-Developer-Console eingetragen sein.

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
| Worker against local hub | `worker` | `priv/mnesia/dev-worker` | http://localhost:<ports> |
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

## Test seeding scripts / ad-hoc artifacts
- Kurz-Notizen über `/tmp/`-Skripte die noch nützlich sind und welche bereits durch committed Mix-Tasks ersetzt wurden.
```

Wichtig: **CLAUDE.local.md anlegen ist explizit `.gitignored`** — niemals committen, auch nicht den Beispiel-Inhalt aus diesem Block 1:1 als File einchecken. Sensible Tokens, Discord-IDs, Mnesia-Pfade gehören in keinen Git-History.

## Local multi-BEAM setup

Hub + worker run in **separate** BEAMs locally because each owns its own Mnesia schema. Schemas are node-name-bound — start each BEAM with the sname matching the schema in its data directory.

- **Hub** (no sname → `nonode@nohost`): `cd apps/hub && mix phx.server` — uses `priv/mnesia/dev/`.
- **Worker against local hub** (sname `worker`): `cd apps/worker && LORE_MNESIA_DIR=$(pwd)/../../priv/mnesia/dev-worker elixir --sname worker --no-halt -S mix run`.
- **Worker against gigalixir prod hub** (sname `worker_prod`): same but with `LORE_MNESIA_DIR=…/prod-worker` and `HUB_BASE_URL=https://loretracker.gigalixirapp.com`. **Seit #492** kann `worker_prod` stattdessen als **self-updating systemd --user Daemon** laufen (`LORE_WORKER_AUTOUPDATE=1` + `LORE_WORKER_DEPLOY_REPO=…`) — er zieht sich nach jedem Hub-Deploy automatisch nach (git→`compile --force`→`hard_halt` = `:erlang.halt(0, flush: false)` (#776), nur wenn idle — **seit #1055 zählt dazu auch jeder laufende ODER wartende GPU-Job**, s.u.; `--force` seit #516, damit die SHA auch ohne Worker-Versions-Bump neu gebacken wird → kein Drift-Loop). Drei Robustheits-Säulen: **#512** systemd-Watchdog (`WatchdogSec=`+`NotifyAccess=main`, `Worker.SystemdWatchdog`) killt Zombie-BEAMs, wenn der Halt nicht durchkommt. **Achtung — der Watchdog ist weiterhin der Vollstrecker, nicht der Backstop.** Hier stand bis #542, seit #776 halte der Node flush-frei und komme zu einem „sauberen `exit 0` statt SIGABRT-Core-Dump". Der Fix ist gebaut (`hard_halt/0` = `:erlang.halt(0, flush: false)`, gegen den am pending IO deadlockenden `System.halt/1`) — **die Wirkung ist ausgeblieben**: #1048 zählte 34 `beam.smp`-Coredumps in acht Tagen, alle SIGABRT, und am 17.09. um 09:18 lief dieselbe Kette erneut, vollständig im Journal (`graceful halt` → `Application worker exited: :stopped` → **50 s nichts** → `Watchdog timeout` → SIGABRT an beam.smp, epmd, erl_child_setup und vier inet_gethost → `code=dumped, status=6/ABRT`). Die Eingrenzung daraus: der Halt hängt **nach** dem Teardown der Anwendung, beim Anhalten der VM selbst. Offen in #1048; #776 ist als Vorgänger geschlossen. **#516** `compile --force` garantiert SHA-Konvergenz; **#500** Boot-Crash-Rollback (`Worker.Updater.boot_guard/1` beim Start) — bootet eine frisch self-updatete SHA wiederholt nicht durch (>2 Versuche, nie via Hub-Join als „good" markiert), rollt der Worker selbst auf die letzte gute SHA (`:last_good_sha`) zurück. Setup: `apps/worker/priv/systemd/worker_prod.service` + `docs/Worker-Setup.md`.

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

### Die Pipeline: Wahrheitsbild (Issue #651; seit #786 der einzige Pfad)

> **Visueller Flow-Überblick** (Audio → Whisper → Wahrheitsbild → Chronik/Epos/Resümee, mit Datei:Zeile + Events + Settings): `docs/Pipeline-Flow.md` (Mermaid-Diagramm + Schritt-Tabelle; interaktive HTML-Fassung `docs/pipeline-flow.html`). Der folgende Absatz ist die dichte Referenz dazu.

`Worker.Recording.Pipeline.run_for_session/1` (bzw. der `UtterancesTranscribed`-Trigger) fährt pro Session den Wahrheitsbild-Pfad — die frühere Chain (Stage 2→3→4 Prosa-Kette) und das `pipeline_mode`-Setting sind mit #786 **komplett entfernt** (kein Fallback; die Chain fabrizierte auf echtem Tisch-Deutsch nahezu vollständig):

- **Glättung (Stage 1.1)** (`smooth_transcript`, Status `"smooth"`, Epic #861: #862+#863+#864) — **deterministische** Transkript-Glättung VOR allem anderen (kein LLM): Sprecher-Merge (Adjazenz + `merge_gap_seconds`, Default 8 s), Stotter-Dedup, Füllwort-Strip, ⚠-Propagation; **OOC bricht den Merge-Run** (Verworfenes auditierbar in `ooc_verworfen`). Output = **Blöcke** mit **content-adressierten IDs** (`b_<hash(sorted quell_utterance_ids + rules_version)>`; die `rules_version` ist compile-zeit-**abgeleitet** aus den Regeldaten). Persistiert als `TranscriptSmoothed`-Whole-Snapshot (`worker_smoothed_blocks`, 1 Row/Session, LWW). **FAIL-LOUD**: scheitert die Glättung, stoppt die Pipeline (kein degradierter Pfad). **Die ganze Pipeline rechnet ab hier auf Blöcken** — `source_refs` der Fakten zitieren Block-IDs; `restrict_to_refs` restringiert auf Block-Texte; `Smoothing.to_context/3` ist der Adapter (Block → utterance-förmige Map mit `effective_text`, EINMAL pro Lauf aufgelöst). **Fakt-IDs sind ebenfalls content-adressiert** (`f_<hash(⋃ Roh-Utterance-Mengen der Refs + normalize(claim))>`, `Parsing.fact_content_id/2`) — transform-**entkoppelt** (Adress-Invariante: keine versionsbehaftete Adresse als Input einer anderen); der frühere `extraction_event_id`-Generation-Pin der Fakt-Overrides ist damit **entfallen** (Override matcht gdw. der Fakt inhaltlich derselbe ist). `SessionFactsExtracted` trägt zusätzlich `extraction_saw` (`%{block_id => text_hash}`, eigene Spalte) — die **Zeit-Adresse**, gegen die die künftige Dirty-Weiche (#866) Text-Identität prüft; **JEDER** `SessionFactsExtracted`-Republish schleppt sie feldkonservativ mit (Entity-Registry-Re-Key seit #879 — der ließ sie weg und clobberte die Adresse per LWW 4 s nach jeder Extraktion → Erst-Kuration routete immer in die Voll-Adoption; Publisher-Tripwire-Test pinnt das. Bis J4 #1207 gehörte `Verify.verify_session` zu diesen Republishern; seit J4 schleppt der Dirty-`:reverify` zusätzlich `verify_backend`/`verify_model` mit — vorher ging die Herkunft dort per LWW verloren). Re-Smoothing von Bestandssessions passiert **on-demand über den Regenerate-Button** (kein Deploy-Trigger; versionsgemischter Korpus ist akzeptiert + im Snapshot auditierbar).

- **Gap-Fill + Kuration (Stage 1.1, Fortsetzung — #865, Epic #861 D+E)** — Blöcke mit erkannter ASR-Lücke (`hat_luecke`, deterministische Signale aus #862; Satzzeichen am Ende schließt den Satz — kein Funktionswort-Fehlalarm) bekommen einen **Verflüssigungs-Vorschlag** (flüssige, inhaltstreue Neuformulierung des ganzen Blocks; `original` = ganzer Block-Text, Wort-Ebene-Skip gegen kosmetische Edits, Längen-Deckel gegen Fabulieren) von einem **lokalen** Modell (`Worker.Recording.Pipeline.GapFill`; Setting `gapfill_model`, leer = Feature aus, LOCAL-only by design). **Seit #924 läuft er SYNCHRON innerhalb der `smooth`-Stufe** (inline im selben GpuQueue-Job, `pipeline.ex:371`) und speist damit schon DIESEN Lauf — vorher lief er asynchron dahinter und die erste Extraktion sah den Roh-Text. Praktische Folge: der Gap-Fill ist der lange Teil der Glättung — **wie lang, hängt an der Blocklänge, und zwar um zwei Größenordnungen**: im #1062-Fall 244 lange Monolog-Blöcke à ~30 s (gut zwei Stunden ohne Stufenwechsel), am 2026-08-21 dagegen 339 kurze Blöcke (Median 66 Zeichen) in 7,5 Minuten, also ~1,3 s je Block. Wer mit der 30-Sekunden-Zahl plant, ohne die Blocklänge zu kennen, verrechnet sich entsprechend. Seine Blöcke sind die zählbare Einheit dieser Stufe im Laufband (#1122). Vorschlag = separates :generiert-Artefakt (`LueckenVorschlagGeneriert` → `worker_luecken_vorschlaege`, Key = Block-Content-ID, LWW; nur für Blöcke OHNE existierenden Vorschlag/Override). **Explizite Nicht-Kante: das Eintreffen eines Vorschlags triggert NIE eine Re-Extraktion.** Fehler → eigene `/admin/errors`-Klasse `gapfill` (best-effort pro Block). **~~ANY-Klemme (E3)~~ — mit #917 (Cut 3) ENTFERNT (vertrauen-aber-markieren):** die frühere Klemme (`Verify.apply_gap_clamp/2` + `Smoothing.clamp_block_ids/2`) hielt jeden Fakt zurück, dessen `source_refs` einen uncurierten Lücken-Block berührten — auf frischen Sessions die Masse. Der #911-Flip nimmt bei uncurierter Lücke den Vorschlag (sonst Original), klemmt NICHTS; `verified?` = nur noch `grounded? AND attributed?` (damals das Verify-Gate; seit J4 #1207 setzt Jacks Belegprüfung beide Flags). Reader-sichtbare Mitigation: der 🕳-**Gap-Trust-Marker** auf den Ableitungen (Chronik/Resümee/Epos, `HubWeb.CampaignLive.GapMarker` — Join `entry.source_refs ∩ {hat_luecke ∧ uncuriert}`, seit #1198 im Worker gerechnet (`Worker.Repo.GlattQuellen.marker/2`, Antwort-Schlüssel `luecken_marker`), der Hub zeigt nur an) + die #915-⚠-Falsifikation. Ehrliche Grenze: eine echt verstümmelte ASR-Lücke kann einen falschen Fakt erzeugen, der als wahr zählt bis jemand ihn flaggt — Mitigation, keine Garantie; betrifft NUR die Gap-Schicht, nicht Grounding/Attribution. **Kuration (Zwei-Klassen-Welt, :kuratiert):** ALLE Member dürfen (`:curate_luecken`, E4) — INLINE in der „Geglättet"-Spalte (#871; Snapshot-Key `smoothed`, schmaler Reload-Scope `campaign_luecken`; seit #883 liefert der Reader ALLE Blöcke und die Spalte fenstert render-seitig wie das Protokoll — gleitendes #709-Fenster über die gefilterte Ansicht-Liste, Scroll-Sentinels „ältere/neuere anzeigen", Ansicht-Wechsel resettet aufs Tail; **seit #1152 kann der Reader die TEXTE fenstern, das Skelett bleibt vollständig, und seit #1153 fragt der Hub danach und lädt die fehlenden Texte nach; seit #1198 rechnet der Worker Ansicht, Filter, Zähler und Fenster und liefert nur das Fenster samt Text (Scope `campaign_glatt_ansicht`)** — s. eigene Abschnitte unten); Status-Enum `bestaetigt | manuell_korrigiert | original_bestaetigt` (kuratiert) `| unbrauchbar` (der EINZIGE subtraktive Akt seit #917 — Block fällt aus der Extraktions-Oberfläche, `to_context` filtert ihn, F5; Badge bleibt). Event `LueckenKurationSet` → `worker_luecken_overrides` (LWW, NIE delete, `quell_utterance_ids` sortiert-kanonisch gesnapshottet, `set_by` sichtbar). **Re-Attach ist reine Read-Zeit-Berechnung** (`Worker.Repo.Luecken.luecken_overrides_effective/2`): nach einem Rules-Bump paart der Override über die identische Utterance-Menge auf die neue Block-ID (`original_bestaetigt` nur bei exaktem Text-Match); nicht-paarende Overrides landen als `verwaist` in der Review-Anzeige, nie still weg; Mehrfach-Paarung → LWW-by-event_id. `/settings` hat dafür ein Stage-1.1-Panel (`merge_gap_seconds` mit Warnung „berührt N Kurationen (Review nötig)" bei bestehenden Kurationen + `gapfill_model` + **`ctx_gapfill`**). **Das Kontextfenster ist seit #1135 einstellbar** — vorher war Gap-Fill der EINZIGE LLM-Aufrufer ohne `num_ctx` und bekam ollamas Servervorgabe statt einer Einstellung; eine serverweit gesetzte `OLLAMA_CONTEXT_LENGTH` konfigurierte damit still die längste Pipeline-Stufe um (gemessen 2026-09-06: 93 % statt 76 % Kartenbelegung). Der Default 8192 ist gemessen (längster Block im Bestand ~1826 Token, Median 43, keiner über 2000) und **absichtlich verschieden vom Fenster der damaligen Extraktion** (`ctx_stage2`, mit J4 #1207 entfallen): bei Gleichstand entfiele der Modell-Reload zwischen Stage 1.1 und Stage 2 — und mit ihm dessen VRAM-Aufräumeffekt, der bislang verhindert, dass die Karte über eine lange Session vollläuft. Seit J4 setzt Stufe 2 selbst kein `num_ctx` mehr (Jack spricht `/v1`); verglichen wird deshalb gegen das Fenster, mit dem Ollama Jacks Modell lädt — ob der Reload damit weiter entsteht, ist nach dem Umbau nicht gemessen.
- **Dirty-Mechanismus (Stage 1.1, Abschluss — #866, Epic #861 Slice F)** — Kuration triggert die Neuableitung automatisch: `Worker.Recording.Pipeline.Dirty` (eigener GenServer, gleiche `:applied`-PubSub-Quelle wie die Pipeline, `elected?`-gegated) hält die EINE Kanten-Tabelle `@dependency_graph`: `LueckenKurationSet` → **Text-Identitäts-Weiche** (debounced, `dirty_debounce_ms` Default 15 s — Kuration ist ein Batch-Vorgang), `SessionFactDateSet` → deterministischer Timeline-Republish (aus der Pipeline hierher gezogen). Die Weiche keyt auf TEXT-Identität, nie aufs Status-Label: `hash(effective_text) == extraction_saw[block_id]` → **Re-Verify** = deterministische Klemm-Neuberechnung aus den persistierten `grounded?`/`attributed?`-Verdikten (KEIN LLM; Fakt-IDs stabil, Fakt-Overrides überleben); sonst — oder bei fehlendem `extraction_saw`-Eintrag (fail-closed, benannte Regel) — **Re-Extract mit Carry-over** (session-scoped Jack-Lauf seit J4 #1207 — `Worker.Jack.Pipeline.extract_facts_raw/4`, ein ganzer Durchgang, ohne Laufband-Meldung; nur Fakten text-geänderter Blöcke adopted — sie tragen Jacks Belegprüfung, der frühere LLM-Judge für sie entfällt —, unveränderte verbatim samt Verdikten, `unbrauchbar` zählt als ENTFERNT). NICHT-Kanten (Negativtests): `LueckenVorschlagGeneriert`, `TranscriptSmoothed`, `SessionFactsExtracted` triggern nie. Ehrliche Grenze v1: Prosa-Renders (Resümee/Epos) ziehen erst beim nächsten Regenerate nach — Fakten + Timeline sofort.

- **Extraktion** (Status `"extract"`) — **seit J4 (#1207) Jack**, s. „Stufe 2 ist Jack“ unten: Blöcke → Aussagen mit wörtlichem Beleg → über `Parsing.parse_facts_json/2` die Pipeline-Fakten. Das Fakt-Schema blieb gleich; die Feldregeln stehen jetzt in `Worker.Jack.Felder` (dieselben Enums wie `Parsing`, ein Quelltext-Wächter hält beide gleich). **Historie (alte Extraktion `Stages`, mit J4 entfernt):** Map-Reduce für lange Sessions (#683) + Halbierungs-Retry degenerierter Chunks (#763) + **Satzgrenzen-Split überlanger Glättungs-Blöcke (#1045)**: ein Solo-Sprecher-Monolog kollabiert mit großem `merge_gap_seconds` zu EINEM Block (Prod-Fall: 228 Utterances → 1 Block, 9.793 Zeichen) — als unteilbarer 1-Element-Chunk scheiterte er GARANTIERT mit `extraction_empty`, weil die #763-Halbierung nichts zu halbieren hat. `split_oversized/3` zerlegt solche Blöcke NUR für den Extraktions-Input in Teil-Elemente mit derselben Block-ID (Teil-Größe ≤ budget/3, damit auch Overlap-geseedete Chunks im Budget bleiben); Anzeige/Kuration/Lücken-Vorschläge/Fakt-Adressen hängen an der Block-ID und bleiben unberührt (`resolve_source_refs` uniq't Mehrfach-Refs ohnehin). Verlustfrei per Konstruktion (Konkatenation der Teile ist byte-identisch; Rückfall-Kaskade Satz → Wort → Graphem). Der EINE Generativschritt — das ist er auch mit Jack. **Feldsemantik (gilt weiter, weil Jacks Ausgabe durch denselben Parser läuft):** **Seit #831 (Epic #829 Slice B)** trägt jeder Fakt zwei Handlungsbogen-Felder: `fact_type` (Enum `ereignis|zustand|zustandsänderung|beziehung|absicht|enthüllung|auflösung` — `zustand` seit #1075, s.u.; unbekannte Werte fallen im Parser auf `ereignis`) + **seit #953 `threads` (LISTE von Kurzlabels, `[]` = keiner — vorher Skalar `thread`; N:M: ein Fakt kann mehreren Erzählsträngen gehören)**. Beide `required` im GBNF-Schema (#676-Lektion), rekonstruiert in `normalize_fact/4` (die EINE Stelle mit fixer Feldliste — die Republish-Pfade sind feldkonservativ). Migration feldkonservativ: `Parsing.fact_threads/1` (die EINE Leser-Quelle) liest `threads` und den Alt-Skalar `thread` als 1-Element-Liste — kein Regenerate-Zwang für Bestandsfakten. Laufzeit-**ungegated** (die Prüfung galt schon immer `claim`/Attribution, nicht Labels); das Offline-Gate `mix lore.eval.threads` ist mit J4 entfernt. **Seit #1066 trägt ein Fakt MEHRERE Figuren.** Bis dahin gab es zwei Skalare (`character` + `cast_match`), und „Verrin versorgt die Wunde des Alten" konnte nur eine der beiden festhalten — wer nach der anderen suchte, fand die Aussage nicht. An der eingefrorenen Fable-Referenz gemessen (419 Aussagen, S3) wären **42 für mindestens eine Figurensicht unsichtbar** gewesen, bei einer Figur jede fünfte ihrer Aussagen; das Ticket selbst nannte auf der abgelösten Extraktion noch 4 von 49. Jacks Schema führt jetzt EIN Feld `characters` — eine **Liste von Objekten** `%{"name", "cast"}`, die handelnde Figur zuerst. **Eine Liste von Objekten, nicht zwei parallele Listen:** das Werkzeug kann jede Form erzwingen (auch gleiche Länge), aber nicht die ZUORDNUNG — zwei gleich lange Listen mit vertauschter Reihenfolge wären formal einwandfrei und semantisch still falsch. Die Form erzwingt die Werkzeug-Laufzeit (`Worker.Agent.Schema.streng/2` wirkt rekursiv durch `items`: `name` ist Pflicht und nicht leer, `cast` darf leer sein), die Prüfung je Figur macht `Worker.Jack.Formregeln` und nennt dabei die Position (`characters[2].cast steht nicht in cast()`). Parsing schreibt daraus `characters` + `entity_ids` und behält `character_alias`/`entity_id` als **erstgenannte** Figur — feldkonservativ wie `thread` → `threads`, ohne Regenerate-Zwang. Die EINE Lesequelle sind `Parsing.fact_characters/1`, `fact_entity_ids/1` und `fact_identities/1` (Paare `{entity_id, name}` für jede Aggregation, die bisher „ein Fakt, eine Identität" annahm: Cast-Roster, Who-is-who der Nachlese, Entitäten eines Strangs). **Ehrliche Grenze:** ob das Modell die Nebenfiguren tatsächlich einträgt, ist **nicht gemessen** — der Auftrag nennt die Regel und zeigt sie an zwei Beispielen (zwei Beteiligte gehören hinein, eine bloße Erwähnung nicht), die Wirkung zeigt erst ein Lauf gegen die Referenz.

**Seit #976 (Epic #911 Slice 3)** gab es dafür `cast_match` (seit #1066 das Feld `cast` je Figur): in der alten Extraktion ein required Enum-Feld (GBNF-erzwungen) gegen den bekannten Kampagnen-Cast (`Worker.Repo.character_roster_for/1` — PCs aus `character_names_for/1`, NPCs aus einer Häufigkeits-Ernte über verifizierte Fakten früherer Sessions, Schwelle ≥2 verschiedene Sessions, Startwert ohne echte Kalibrierung) + einem festen Escape-Sentinel `"(kein Cast-Treffer)"` (`Parsing.no_cast_match_sentinel/0`) für Figuren außerhalb des Rosters — Enum ist dadurch nie leer. Löst das "Alias-Chaos" (Discord-Handle statt Figurenname in `character_alias`): das bestehende Freitext-Feld `character` bleibt unverändert (Ist-Zustand als Fallback), `cast_match` gewinnt in `normalize_fact/4` nur bei einem echten Treffer (nicht blank, nicht der Sentinel). Roster wird EINMAL pro Session-Extraktion gebaut, nicht pro Map-Reduce-Chunk. Ehrliche Grenzen: Einmal-Figuren (nur 1 Session) bleiben dauerhaft im Freitext-Pfad; Cloud-Backends (kein GBNF-Zwang, #783) bekommen keine strukturelle Garantie für `cast_match`, dort bleibt es effektiv unvalidiertes Freitext-Vertrauen wie `character` selbst. **Seit J4** ist der Cast-Abgleich in Jacks Schema ein freies Feld, das leer bleiben darf — Jack bekommt den Roster als Liste, eine Enum-Garantie gibt es nicht mehr; den Escape-Wert „(kein Cast-Treffer)“ hatte der Spike gemessen und verworfen, `Worker.Jack.Formregeln` weist ihn ab. Der Vorrang (Cast-Treffer vor Freitext) gilt unverändert — seit #1066 je Figur statt je Aussage. **Historie — der alte Extraktions-Prompt (#1075; mit J4 entfernt, ob Jacks Aufträge dieselben Regeln tragen, ist hier nicht geprüft).** #1075 überarbeitete ihn: vier Regellücken, ein beschriebenes Schema, `time_anchor` als Producer. Gemessen wurde gegen ein starkes Modell mit sichtbarer Denkspur: der Prompt wird wörtlich zurückzitiert, bevor er angewandt wird — wo die Extraktion schwächelt, liegt es an den Regeln, nicht am Modell. `zustand` ist der siebte `fact_type` und fängt das Weltwissen, das keine Handlung ist; die sechs bisherigen sind alle handlungsförmig, „Ryumyo ist ein großer Drache" passte in keinen, und in 446 Zeilen Denkspur fiel über das Feld **kein einziger Gedanke** (28 von 29 Fakten `ereignis`; mit dem siebten Wert 32 × `zustand` / 9 × `ereignis` und nebenbei 45 % mehr Fakten). Die frühere Prompt-Anweisung „im Zweifel ereignis" ist deshalb entfallen — der Parser-Fallback auf `ereignis` bleibt für Modell-Garbage. `threads` ist als fortlaufende Handlung **ODER** zeitloses Weltthema definiert: die alte Nur-Handlung-Definition ließ das Modell korrekt folgern, eine reine Weltbau-Sitzung habe gar keine Stränge (**29 von 29** Fakten ohne Label — für genau dieses Material hält das System seit #885 die `context`-Klasse, die so nie gefüllt werden konnte). `narration_time` nennt die Schilderung der Spielleitung ausdrücklich als Flashback; die figurenzentrierte Definition ließ bei `think: medium` **alle elf** Rückblenden auf `present` kippen. Neu ist ein Abschnitt zu **Eigennamen**: verstümmelte ASR-Formen werden abgeschrieben, nicht korrigiert — das Modell erwog rund 500 Wörter lang mit fünf Richtungswechseln, ob „Arts Technology" zu „Ares Technology" zu bessern sei, und erzeugte in einem Lauf eine Top-10-Liste, in der derselbe Konzern zweimal steht. Dazu trägt **jedes** Schema-Feld eine `description` (bei Ollama erzwingt GBNF die Struktur token-weise; die Beschreibungen sind der Teil, der auch bei Cloud-Backends ankommt — ohne Schema fielen die Stränge auf 0, mit Schema kamen 6 bei identischem Prompt), und die Formulierung ist durchgehend **bejahend**: eine Verneinung definiert keinen Zielzustand, das Modell füllt den Negativraum selbst und von Lauf zu Lauf anders. Der Gegenbeweis stammt aus diesem Umbau selbst — „rechne sie NICHT um und ergänze nichts" drückte `in_game_date` von 6/29 auf 4/42; gewollt war „kopiere den Ausdruck", angekommen ist „Finger weg vom Feld". Stehen bleiben die fünf Verneinungen, die gegen einen konkreten konkurrierenden Attraktor abgrenzen (Sprecher-Feld, Erzählzeit vs. erzählte Zeit, Beispiel-Labels, Halluzinationsunterdrückung, Zeitpunkt gegen Dauer). **`time_anchor` wird seit #1075 (E4) abgefragt** — required nach der #676-Lektion, ohne Enum. **Seit #1109 in DREI Formen** (`absolute` / `session` / `unknown`): die vierte, `event:<Stichwort>`, ist wieder zurückgenommen. Ihr Matcher (`Graph.normalize_event_anchor/3` → `claim_contains?/2`) sucht den Ausdruck als case-insensitiven **Teilstring** in den Claims der übrigen Fakten — genau das Verfahren, das der Zeit-Vorlauf (#1069, mit #1213 entfernt) im selben Repo mit Zahlen widerlegt hat („Gang" trifft *Vergangenheit* in 10 von 14 Fällen, „Nacht" trifft *Nachteil* in 4 von 6); der Vorlauf bekam daraufhin Wortgrenzen und eine Negativliste, der Ereignis-Matcher hat beides nicht. Entscheidend ist die **Richtung** des Fehlers: zwei Treffer gelten als mehrdeutig und werden `unknown`, ein EINZELNER Falschtreffer wird zur bindenden Kante — ein erfundenes `event:Gang` datiert einen Fakt auf einen unbeteiligten anderen, ohne Fehler und ohne Spur. Der Riegel sitzt in `normalize_anchor/1` (laut, mit `Logger.warning`) und nicht allein im Prompt, weil das Feld freier Text ist: nennen und erzwingen sind zweierlei. Graph- und Resolver-Code bleiben erhalten und getestet — die Form wird wieder erreichbar, sobald ihr Matcher gehärtet ist. Bis dahin kam das Feld **ausschließlich aus der GM-Kuration** (7 von 225 Fakten an Free Seattle), die Formen `session` und `event:…` in echten Daten **null Mal**: `Worker.Timeline.{Resolver,Graph}` hielten seit #724 Fuzzy-Match, Kahn-Fixpunkt und Zyklusschutz bereit — ein Apparat ohne Producer. **Bewusst in Kauf genommen** (Entscheidung 2026-08-19): weil `Graph.time_signal?/1` jeden gesetzten Anker als „dieser Fakt verdient einen Chronik-Eintrag" liest, hebt ein flächig gesetztes `session` den #958-Vorfilter praktisch auf und die Chronik wird wieder zur Vollansicht — der Faktendump ist als **Zwischenschritt akzeptiert**, nicht übersehen. `pipeline_time_anchor_test.exs` pinnt die KETTE statt der Einzelteile (Prompt-Form → Parser → Graph-Fuzzy-Match → Resolver-Zweig); bricht ein Glied, ist der Effekt sonst unsichtbar: das Modell liefert brav einen Anker, `normalize_anchor/1` macht `nil` daraus, und der Fakt landet still im Präsens-Fallback. **Ehrliche Grenze: ob die Überarbeitung die Extraktion auf echtem Tisch-Deutsch messbar verbessert, ist offen** — die Belege oben stammen aus Einzelläufen an Free Seattle S1, nicht aus einer Messreihe. Zwei Felder waren im alten Schema zudem schwächer geführt als der Rest: `narration_time` und `precision` hatten **kein** Enum, ein abweichender Wert fällt im Parser still auf `present` bzw. auf `nil` — in Jacks Schema (`Worker.Jack.Felder`) sind beide Enums.
- **Entity-Registry** (best-effort, kein Status) — campaign-weites Guise-Merging (`EntityRegistry.resolve_campaign_entities`, #714; Cluster-Fehler lässt die Fakten unverändert).
- **Thread-Registry** (best-effort, im selben `resolve`-Schritt, #832) — campaign-weites **Handlungsbogen-Clustering** der rohen `thread`-Labels (#831) zu kanonischen Strängen. **Whole-Snapshot-Artefakt** (`ThreadRegistryComputed` → `worker_thread_registry`, 1 Row/Kampagne) — anders als die Entity-Registry re-keyt es die Fakten NICHT; die Map lebt separat, der Reader (`campaign_threads/1`, Slice D1) wendet sie zur Lesezeit an. **Seit #885 klassifiziert das Clustering jeden Kanon-Strang als `arc` (auflösbarer Handlungsbogen) oder `context` (zeitloses Weltwissen — schließt nie ab), seit #901 (Epic #900, kinds-Trichotomie) zusätzlich als `rauschen` (Meta-/Tisch-/Werkzeug-Gerede — fällt aus den inhaltlichen Sichten)**: die `kinds`-Map reist im selben Snapshot (JSON-Envelope `{map, kinds}` im Blob, Alt-Rows/Alt-Events bleiben lesbar → kind `arc` fail-safe; unbekannte kind-Werte kollabieren auch am Reader sichtbar auf `arc`), das Fäden-Panel listet Arcs zuerst, Contexte als eigenes „📚 Themen"-Register OHNE Auflösungs-Semantik (kein auflösen-Button/🏁; `false_resolve` ist für Contexte undefiniert — Vorbedingung fürs #837-Gate) und Rauschen-Stränge in einem zugeklappten „🔇 Rauschen"-Unter-Register mit Rettungs-Buttons (raus aus Hauptliste + Header-Zähler), Member stufen per dritter Override-Dimension `kind` um (`mark_arc | mark_context | mark_rauschen | clear_kind`, gleiche LWW-Overlay-Mechanik wie #836). Cluster-Fehler → eigene `/admin/errors`-Klasse `resolve_threads` (wie #820), Fakten behalten ihr Roh-Label. **Seit #903 (Epic #900 S2) ist der Arc ein erstklassiges Objekt** (`worker_arcs`, eine Row pro Bogen, drei fold_meta-Gruppen `:arc_created`/`:arc_act` (geteilt Closed+Reopened)/`:arc_leitfrage`): Geburt maschinell im selben resolve-Schritt (arc-kind-Stränge ohne paarenden Arc; `arc_id` content-adressiert über campaign_id + sortierte Seed-Roh-Labels; Leitfrage-Draft deterministisch, kein LLM) — **die Paarung läuft seit #1071 über den KANON, nicht über die Roh-Labels**, Status NIE geschrieben sondern am Reader ABGELEITET (offen | geschlossen(geloest|versandet); versandet reopent automatisch gdw `max_fakt_session > wasserlinie_session` — die Wasserlinie reist ZUR SCHREIBZEIT im ArcClosed-Payload, max `last_touched_session` der campaign_threads), Arc-Felder reiten flach in den `campaign_threads`-Maps. Panel: Arc-Stränge schließen/öffnen über `ArcClosed`/`ArcReopened` (Member-Recht `:curate_threads`), Legacy-`resolve`-Override nur noch für arc-lose Stränge lesbar (Akt-Präzedenz: irgendein Arc-Akt überstimmt Legacy); Leitfrage inline kuratierbar (`LeitfrageSet`, leer = Undo → Draft). **#539 ist mit #903 erledigt:** `Shared.Events.k/1`-Compile-Zeit-Makro (Pattern-Head-tauglich, validiert gegen die 0-arity-Konstanten) — Consumer-Matches (CampaignLive/Updates/Seed-Tasks) laufen darüber; neue Event-Kinds in Emits als Funktions-Call, in Pattern-Heads via `k(:...)`. **Seit #907 (Epic #900 S4)** gibt es die **Nachlese-Seite** `/campaigns/:id/nachlese` (`HubWeb.NachleseLive`, 📖-Link in der CampaignLive): die erste REINE Ableitung der Wahrheitsbasis für den #687-Use-Case — Recap der letzten Session (+#715-Flagging), offene Bögen (aktiv zuerst, Leitfrage + Prosa-Progressions-Chronik #838, s.u.; Abgeschlossene zugeklappt), Who's-who (deterministisch aus verifizierten Fakten; `pc?` = Alias-Match gegen Member-Figurennamen — benannte Heuristik) + zugeklapptes 📚-Themen-Register; eigener schmaler member-gated Snapshot-Scope `campaign_nachlese` (`Worker.Repo.Nachlese`), kein LLM (die Blöcke selbst, Prosa-Progressionen sind bereits fertig gerenderte Artefakte aus dem Pipeline-Schritt unten), kein Live-Refresh in v1. **Seit #838** rendert die Pipeline zusätzlich pro in einer Session berührtem Handlungsbogen EINEN Prosa-Absatz (`render_arc_progressions`, Status-Name im Pipeline-Log; s.u. „Geschwister-Render"), gespeichert als EIN eigenständiger, NIE überschriebener Eintrag pro `{arc_id, session_id}` (`worker_arc_progressions`) — die Nachlese zeigt pro Bogen ALLE bisherigen Einträge chronologisch (nicht nur einen zuletzt überschriebenen „Stand"), Fallback auf die alte „N Fakt(en)…"-Zeile solange ein Bogen noch keinen Eintrag hat. **Seit #905 (Epic #900 S3)** dazu: **Arc-Merge als Read-Zeit-Redirect** (`ArcMergeSet` → `merged_into`-Spalte, Fold-Gruppe `:arc_merge`; Redirect wirksam gdw. Ziel existiert UND selbst un-gemerged — Ein-Level, Zyklen/Ketten degradieren zu wirkungslos-aber-sichtbar), **⚠-Arc-Review-Register** im Fäden-Panel (verwaiste Bögen mit sichtbarem Close-Status + Merge-Select mit Kanon-Überlapp-Vorauswahl = Duplikat-Heilung, seit #1071 über den Kanon statt über Roh-Labels; Gemergte mit Undo; die Listen „atmen" im Verify-Fenster — benannte Grenze) und **Fakt→Arc-Override** (`FactArcSet`, `worker_fact_arc_overrides`; `max_fakt_session` ist seit #905 FAKT-genau — ein Override rein/raus kippt das versandet-Gate präzise; Fakt-Liste id+claim pro Strang reitet im Snapshot). **Seit #953 ist der Override ein SET (N:M): Payload `arc_ids: [ids] | null` mit DREI sauber getrennten Zuständen (#766-Klasse): `[ids]` = Override auf genau diese Bögen · `[]` = explizit KEINE Bögen · `null`/absent = RÜCKNAHME (Extraktions-Label-Kette gilt wieder — löst „einmal übersteuert = taub gegen Re-Extraktion"). `overridden?` wird am Reader aus dem Set-Wert abgeleitet, NIE aus Row-Präsenz (H1). Alt-Skalar `arc_id` (`""` = Rücknahme, `"X"` = 1-Element-Set) feldkonservativ mitgelesen. Verwaiste arc_ids (Ziel weg-geclustert/gemergt) bleiben im Storage (NIE bereinigt) und fallen erst am Read fürs Rendern raus (flag-not-drop), im Fäden-Panel als „⚠ N verwaist" sichtbar. UI: Multi-Select-Checkboxen pro Bogen + „🔄 Auto"-Rücknahme-Button. Das arc-STATUS/versandet-Gate (#903) bleibt bewusst 1:1 (erstes Set-Element), nur der Render (`fact_render_assignments/2`) + die Panel-Anzeige gehen N:M.** **Seit #842 läuft das Clustering inkrementell** statt bei jedem Pipeline-Lauf komplett neu: nur die Roh-Labels, die seit dem letzten Lauf neu dazugekommen sind, werden gegen die bestehenden Kanon-Stränge als Kontext geclustert (`resolve_campaign_threads/2`) — bestehende Kanon-Texte werden dabei nie verändert (schützt die ältere `worker_thread_overrides`-Kuration #836 vor Verwaisen im Normalfall, auch wenn diese Tabelle selbst weiterhin auf dem kanonischen Anzeigetext keyt, kein Re-Attach analog Arc). Der frühere Vollpfad (`full_recluster_campaign_threads/2`) bleibt als seltener, expliziter, GM-getriggerter Button im Fäden-Panel („Fäden neu clustern") erhalten — dabei KÖNNEN sich Kanon-Texte ändern (bekanntes Restrisiko, Confirm-Warnung im UI).
**Wo Wahrheit erzwungen wird — und wo bewusst nicht (Issue #1124).** Die
**Fakten sind die Basis und müssen echt sein**; dort sitzt die Prüfung, und nur
dort — seit J4 (#1207) als Jacks Belegprüfung, vorher als Verify-Gate. Was die Prosa daraus macht, ist abgestuft frei: das **Resümee darf leicht**
fabulieren, das **Epos ein wenig mehr**. Das ist eine Produktentscheidung, keine
Nachlässigkeit — und sie beendet eine Doppelprüfung, die es bis #1124 gab.

Bis dahin lief hinter jedem Render ein **NLI-Gate**, das jeden erzeugten Satz auf
die Fakten zurückzuführen versuchte. Es maß am Epos das Falsche: der Prompt
erlaubt Ausschmückung ausdrücklich („Handlung treu, Erzählweise frei"), geflaggt
wurden 63 von rund 90 Sätzen — darunter „Der Regen kam wie immer." und „Genug.".
Am Resümee waren drei von vier Flags eines echten Laufs **Splitting-Artefakte**
statt Fabrikation (zerschnittene Sätze, die gar keine Behauptung sind). Ein
Warnzeichen, das zwei Drittel eines Kapitels markiert, versteckt genau den einen
Fall, für den es da wäre.

Praktische Folge für künftige Arbeit: **kein neues Prosa-Gate bauen.** Wer
Dazudichtung fangen will, prüft nicht Sätze auf Entailment, sondern Namen auf
Existenz — eine Figur oder ein Ort, den kein Fakt kennt, ist ein Befund; ein Satz
über Regen nicht. Ob es dafür überhaupt genug zu fangen gibt, ist offen und wird
in #1125 gemessen, bevor etwas gebaut wird.

**Seit J5 (#1209) schreibt das Resümee der Resümee-Jack** — und dort sitzt die
Prüfung am Satz, ohne Entailment: jeder Satz nennt die Fakten, auf die er sich
stützt, oder ist ausdrücklich als Übergang (ohne Fakten) bzw. Rückblick (nur
frühere Sitzungen) markiert (`Worker.Jack.Resuemee.Entwurf.satz_pruefen/2`). Die
Durchsicht danach ist gnädig: sie ersetzt nur grobe Schnitzer. Hinweise auf
großgeschriebene Wörter ohne Fundstelle in den Fakten des Satzes zeigen ihr, wo
sie genauer hinsieht, lehnen aber nie ab — die Namen-auf-Existenz-Richtung von
oben, als Fingerzeig statt als Gate. Details: „Resümee durch den Resümee-Jack“.

- **~~Verify-Gate~~ (Stufe 3) — mit J4 (#1207) entfernt.** `Verify.verify_session` (Quell-Grounding + Attribution durch ein zweites Modell, Flag-statt-Drop) gibt es nicht mehr; Jacks Aussagen tragen ihre Belegprüfung, `grounded?`/`attributed?`/`verified?` stehen auf `true`. Nach den Registries liest `Worker.Jack.Pipeline.geprueft/1` nur den gespeicherten Bestand zurück (`bestand_lesen/3` in `pipeline.ex`, keine Laufband-Stufe; ein Fehler dort steht in `/admin/errors` weiter unter Stage `verify`). **Flag-statt-Drop gilt seitdem für die Kuration, nicht mehr für ein Modell-Urteil:** was die Belegprüfung nicht besteht, lehnt Jacks Werkzeug ab — es wird nie ein Fakt und erscheint in der Kampagne nicht; sichtbar bleiben der `verified?`-Override der Fakten-Spalte und die Falsifikations-Flags.
- **Resümee durch den Resümee-Jack** (J5 #1209, Epic #1195; Stufen `resuemee_ueberblick` → `render` → `resuemee_durchsicht`, `Worker.Jack.Resuemee.Pipeline`) — an der Stelle des früheren Render-Resümees; `Render.render_summary` ist entfernt, **es gibt keinen Rückfall**. Drei frische Läufe auf derselben Eingabe (`Worker.Jack.Resuemee.Eingabe.aus_repo/1`: die geprüften Fakten der Sitzung mit ihren Bögen samt Art, Fakten und Resümees früherer Sitzungen, die „vorigen Gedanken“ beider Jacks, der Mitschnitt zum Nachschlagen, Überschrift, Töne und die Länge): **Überblick** (alle Fakten lesen, aus der Überschrift der Resümee-Spalte die FORM ableiten, eine GLIEDERUNG als **Weg der Gruppe** anlegen — Station für Station vom Anfang bis zum Ende, höchstens `max(3, round(2 · max_woerter / 25))` Stationen (beim Standard zwölf; die 25 Wörter je Station sind gegriffen), jede mit mindestens einem Fakt dieser Sitzung; die Antwort von `notiz`, der Stand in `notizen_lesen` und `fertig` nennen als **Hinweis, nicht als Ablehnung** die Spanne ihrer Fakten in Blocknummern gegen die aller Fakten der Sitzung und ob die Stationen in Blockreihenfolge stehen (`Worker.Jack.Resuemee.Weg`; eine Station steht dort, wo ihr frühester Beleg liegt); die frühere Pflicht, jeden `arc`-Bogen darin aufzunehmen, ist entfallen), **Schreiben** (ohne Erinnerung an den Überblick, nur mit dessen Notizen; Ton → Notizen → Auftrag; Absatz für Absatz, jeder Satz nennt seine Fakten oder ist als Übergang/Rückblick markiert; Ziel `max_woerter` Wörter, höchstens das Doppelte; jede Station der Gliederung trägt mindestens ein Satz, der einen ihrer Fakten dieser Sitzung nennt; jeder `arc`-Bogen kommt vor oder steht begründet in `ausgelassen`) und **Durchsicht** (Absatz für Absatz gegen die Fakten, gnädig: nur grobe Schnitzer werden ersetzt, alles andere bestätigt; höchstens drei Durchgänge; eine Ersetzung über die Obergrenze wird abgelehnt, ebenso ein Ersetzen oder Streichen, nach dem eine Station der Gliederung, die vorher einen Satz hatte, keinen mehr hätte). **Länge (#1209):** der erste echte Lauf lieferte 1272 Wörter in 12 Absätzen und erzählte 107 von 114 Fakten — länger als das Epos-Kapitel. Seitdem ist das Resümee ein „Was bisher geschah“ mit einer Länge **je Kampagne in „Stil setzen“** (Resümee-Tab, Zahlfeld „Länge des Resümees (Wörter)“, erlaubt 30 bis 1000). Der erste Lauf mit dem damaligen Standard 75 lieferte 73 Wörter, in denen der Ablauf der Sitzung nur bruchstückhaft erkennbar war, und Sätze, die mehrere Ereignisse bündelten; Maintainer (13.09.2026): „Der Weg, den die Gruppe genommen hat, muss aus dem Resümee ersichtlich sein — wenn die 75 Wörter nicht reichen für die grobe Abdeckung, darf man bis zu maximal dem Doppelten erweitern.“ Der gesetzte Wert ist deshalb das **Ziel**, die **Obergrenze ist das Doppelte** (`Shared.ResuemeeLaenge.hoechstens/1`), und der **Standard ist 150 Wörter** (Obergrenze 300; drei Resümees einer anderen Kampagne mit je rund 210 Wörtern hält der Maintainer für eine gute Größe). Standard, Bereich und Obergrenze leben in `Shared.ResuemeeLaenge`, weil Hub und Worker sie beide brauchen. Gespeichert als eigenes Ereignis `CampaignResuemeeLaengeSet` (Tabelle `worker_campaign_resuemee_laengen`, eine Row je Kampagne, LWW über die fold_meta-Sidecar, nie ein Delete, Cascade bei `CampaignDeleted`) — **nicht** als Feld von `CampaignVorgabeSet`: dessen Fold ersetzt die Vorgabe-Row aus einem Payload, und jeder Producer, der nur den Namen kennt (ein älterer Hub, `Worker.Jack.StageKopie`, ein Alt-Event im Replay), hätte eine Länge dort still gelöscht. Eine neue Tabelle statt einer neuen Spalte, weil `ensure_table!` eine bestehende Tabelle nicht umbaut; sie entsteht beim nächsten Boot leer, Bestands-Mnesia bleibt unberührt. Ein ungültiger Wert gilt als Standard und steht laut im Log. Die Länge reist mit `Worker.Repo.get_campaign/1` (`resuemee_max_woerter`, `nil` = Standard) im Kampagnen-Snapshot und in `campaign_meta` zum Hub, der Resümee-Jack liest sie in `Eingabe.max_woerter/1`. **Hart geprüft in den Werkzeugen** (`Worker.Jack.Resuemee.Laenge`, `.Weg`): `notiz` lehnt einen Gliederungspunkt über dem Deckel ab (ersetzen und streichen gehen) und einen ohne Fakt dieser Sitzung (er ließe sich nie tragen); `fertig` im Schreiben lehnt ab, solange eine Station keinen Satz hat, der einen ihrer Fakten dieser Sitzung nennt, solange der Entwurf über der Obergrenze liegt, und über dem Ziel, solange das neue Pflichtfeld `laenge_begruendung` leer ist (bis zum Ziel darf es leer bleiben; die Begründung steht im Journal, im Stand und in den Zählwerten und reist in den Stand der Durchsicht mit) — gezählt werden alle Satztexte plus Absatztitel (`Stand.woerter/1`). `absatz` trägt über Ziel und Obergrenze ein — sonst ließe sich nie umformulieren — und warnt, über der Obergrenze deutlich; die Antworten nennen die Stationen ohne Satz. Jede Antwort des Schreibens nennt „X Wörter — Ziel M, höchstens 2M“, `Ergebnis.zaehlwerte/1` trägt `woerter`, `max_woerter` (Ziel), `obergrenze`, `laenge_begruendung` und `gliederung_ohne_satz`, die Laufsicht zeigt Wortstand, Obergrenze, Begründung und Stationen ohne Satz. **Ehrliche Grenzen der Länge und des Weges:** gezählt wird, was durch Leerraum getrennt ist (ein Gedankenstrich zwischen Leerzeichen zählt mit); der Deckel von 25 Wörtern je Station ist gegriffen; geprüft wird, dass ein Satz einen Fakt der Station nennt, nicht, dass er sie erzählt; ob eine Begründung trägt, prüft niemand; ob ein Modell unter diesen Regeln den Weg der Gruppe erkennbar erzählt, ist nicht gemessen. Modell, Endpunkt, Regler und Kontextfenster wie Jack; das Modell ist eigens wählbar (`resuemee_jack_model`, **leer = Jacks Modell**, Feld im Block „Jack: Extract/verify“, Leser `Worker.Jack.Resuemee.Pipeline.modell_name/0`). **Fehler:** scheitern Überblick oder Schreiben (Klassen `resuemee_ueberblick_ohne_abschluss`/`resuemee_schreiben_ohne_abschluss`; ein Fehler vor den Läufen — Modell, Kontextfenster, Eingabe — ist ein Fehlschlag von `render` mit der Klasse seines Grundes), gibt es kein neues Resümee, und der Lauf endet dort wie früher beim Render: **Chronik, Epos und Bogen-Progressionen laufen dann nicht**, das bisherige Resümee bleibt stehen. Scheitert nur die Durchsicht (best-effort, Klasse `resuemee_durchsicht_gescheitert`), wird der Entwurf aus dem Schreiben veröffentlicht, und der Lauf geht weiter. **Ereignisse:** `SessionSummaryGenerated` trägt additiv `satzquellen` (je Satz Text, echte Fakt-IDs, `uebergang`/`rueckblick`) und `zaehlwerte`, dazu `render_backend: "jack"` und als `render_model` das Modell des Resümee-Jack. **`source_refs` sind seitdem genau:** die Block-Belege der zitierten Fakten dieser Sitzung statt aller Fakten. Sprungmarken, Sync-Index und 🕳-Marker lösen sie unverändert über `Worker.Repo.GlattQuellen` auf; ein nicht zitierter Lückenblock trägt dem Resümee keinen 🕳 mehr ein. Die Satzquellen stehen im Event und im Stand, die Summary-Tabelle bleibt in ihrer Form. Dazu `JackResuemeeStandAbgelegt` (Tabelle `worker_jack_resuemee_staende`, eine Row je Sitzung, LWW über `event_id`, Cascade bei `SessionDeleted`/`CampaignDeleted`): Notizen, Entwurf, Satzquellen, Zählwerte (inkl. Durchsicht), Modell, Zeitpunkt — die Notizen liest der Resümee-Jack späterer Sitzungen als „vorige Gedanken“. **Laufband und Laufsicht:** drei Stufen — der Überblick zählt gelesene Fakten, die Durchsicht entschiedene Absätze je Durchgang, das Schreiben nichts (`Worker.Jack.Resuemee.Melder`); ihre Titel heißen nach der Resümee-Spalte („Run-Report: Überblick“ …, `Laufband.titel/2`). Die lokale Laufsicht zeigt die Läufe in einer eigenen, schlanken Ansicht (Lauf, offene Arbeit, Notizen, Entwurf, Durchsicht). „Neu generieren“, der Kampagnen-Replay und „noch N Iterationen“ schreiben das Resümee neu — alle drei laufen durch `run_wahrheitsbild`. **Gemeinsame Lesebasis (E0, #1210; der Epos-Jack nutzt sie danach):** in allen drei Läufen sucht `suche_sitzung(begriff, weiter?)` in Fakten, Mitschnitt und Bögen dieser Sitzung und `suche_bisher(begriff, weiter?)` in allem bis einschließlich dieser Sitzung (Fakten und Mitschnitte aller Sitzungen, Resümees und Epos-Kapitel samt bisheriger Fassung dieser Sitzung, Notizen der Jacks, Bögen mit Leitfragen, Chronik — aus späteren Sitzungen nichts); je Quelle höchstens 20 Treffer mit Adresse zum Nachlesen, `weiter: true` blättert (Position je Werkzeug und Begriff im Stand). **Gefunden wird am WORTANFANG (#1238):** „Kamera“ findet „Kameras“ und „Kamerafeeds“, „Gang“ findet nicht „Eingang“ und nicht „gegangen“. Vorher verglichen alle drei Suchwerkzeuge per Teilstring, und das ist auf Deutsch unbrauchbar — an 1802 Blöcken echten Mitschnitts gemessen lieferte „Gang“ 16 Fundstellen mit **null** echten Vorkommen, „Bar“ 14 (Bargäste, furchtbar, bombardiert), „Ort“ 28 mit einer. Die Grenze steht **nur vorn**, nicht beidseitig: Deutsch hängt Bedeutungsänderndes vorn an (*Ein*gang, *furcht*bar, *d*ort) und Flexion hinten (Kamera**s**, Wache**n**) — eine beidseitige Grenze hätte bei „kamera“ elf von 24 echten Treffern weggeworfen. Was die Regel **nicht** fängt, sind homograf beginnende Wörter („heiß“ findet weiter „heißt“); Lemmatisierung ist ausdrücklich nicht gewollt (#1109/#1213-Klasse). Findet sich nichts, nennt die Antwort die Wörter, in denen der Begriff im Inneren steckt — und **jede Werkzeug-Beschreibung sagt die Regel an**, damit das Modell sie nicht erraten muss. Das frühere `suche` (nur Mitschnitt) ist im Resümee-Jack entfallen, der Fakten-Jack behält es. `bloecke`/`block` nehmen ein optionales `sitzung`, `fakt(id)` zeigt auch bei früheren Fakten die Belegblöcke; der Mitschnitt früherer Sitzungen wird **erst beim Zugriff** über einen Lader aus `Eingabe.aus_repo/1` geladen und im Stand gehalten (`Worker.Jack.Resuemee.Mitschnitte`), ohne Glättung antwortet das Werkzeug mit dem Grund. Dazu `boegen_kampagne()` und `vorige_kapitel(von?, bis?)` (`Worker.Jack.Resuemee.Bisher`). **Die Wiederholungssperre trifft das Blättern nicht:** `Worker.Agent.Werkzeug` hat dafür die Option `wiederholung_merkmal:` bekommen — ein Merkmal des Stands vor dem Aufruf gehört zum Schlüssel des „gleichen Aufrufs“, bei den Suchen die Position des Blätterns; gezählt wird erst, wenn Blättern nichts Neues mehr bringt (`:bis_aenderung` konnte das nicht: es erkennt eine Änderung nur am Erfolg eines anderen Werkzeugs mit `aendert_bestand`). **Ehrliche Grenzen:** nicht gegen ein echtes Modell gemessen, nur mit geskriptetem Modell getestet; die Dirty-Neuableitung nach einer Kuration schreibt das Resümee weiterhin nicht neu (wie zuvor, s. #866); ein Worker-Neustart mitten im Lauf verliert ihn — das bisherige Resümee bleibt dann stehen. **Epos-Jack, die drei Läufe (E1–E3, #1210; den Einbau E4 beschreibt der nächste Punkt):** `Worker.Jack.Epos.laufen_ueberblick/2` bzw. `ueberblick/2` fährt auf demselben Stand (`art: :epos`), derselben Lesebasis, demselben Halter und derselben Laufmechanik (`Worker.Jack.Resuemee.Lauf`) wie der Resümee-Jack; wo ein gemeinsames Modul dem Modell „das Resümee“ nennt, richtet es sich nach `art` (beim Epos sucht `suche_sitzung` zusätzlich im Resümee dieser Sitzung), für den Resümee-Jack bleibt es byte-gleich. Eigen sind die Eingabe (`Worker.Jack.Epos.Eingabe`: Überschrift der Epos-Spalte, Grund- und Epos-Ton, der **Weg aus dem Resümee** = die GLIEDERUNG des abgelegten Resümee-Stands; fehlt der Stand oder zeigen seine Satzquellen auf andere Fakten als heute, ist der Weg leer und das steht im Log), die Notizen FORM (Form + Erzählhaltung), SZENEN (ohne Obergrenze, je mit einem Fakt dieser Sitzung), ABWEICHUNG (Schlüssel = Stationsschlüssel) und OFFEN, das Werkzeug `resuemee()` und `fertig(fakten, szenen, offen_geblieben)`, das ablehnt, solange eine Station des Wegs weder eine Szene hat noch unter ABWEICHUNG steht. **Lauf 2, Schreiben (E2):** `Worker.Jack.Epos.laufen_schreiben/3` (`laufen/2` fährt Überblick → Schreiben, `kapitel/2` dasselbe aus dem Repo) — **der Epos-Jack schreibt frei** (Maintainer, 13.09.2026): keine Prüfung je Satz, keine Fakten je Satz, keine Markierungen, **keine Länge des Kapitels** (auch keine Mindestlänge — die aus E1 ist samt `Shared.EposLaenge` wieder entfernt) und keine Pflicht, jede Szene zu erzählen. Der Auftrag (`epos_schreiben.md`) stellt den Stil ganz nach vorn (Überschrift, Grundton, Epos-Ton, FORM-Notiz), dann die Szenen, dann die Aufgabe („Handlung treu, Erzählweise frei“). `absatz(text, titel?, szene?)` hängt einen Absatz freier Prosa an (`Worker.Jack.Epos.Entwurf`; höchstens 400 Wörter, gegriffen, damit ein Absatz ein Absatz bleibt); `szene` ist optional, muss aber eine SZENE der Notizen sein und ist die einzige Zuordnung zu den Fakten (`Worker.Jack.Epos.Ergebnis.quellen/1`: Absatz → Szene → Fakt-IDs, für die Quellen im Einbau). Die Antworten nennen nur den Wortstand, die Wörter je Absatz und — ausdrücklich als Hinweis, nicht als Pflicht — die Szenen ohne Absatz; `fertig(absaetze, offen_geblieben)` lehnt nur ein Kapitel ohne Absatz ab. Das Markdown hat keinen Kapitelkopf (Nummer und Datum bleiben deterministisch, #752). **Lauf 3, Durchsicht (E3):** `Worker.Jack.Epos.laufen_durchsicht/4` liest das Kapitel Absatz für Absatz, anders als beim Resümee **auch stilistisch** (Lesefluss, Rhythmus, Wiederholungen, Ton nach der FORM, Übergänge zwischen den Szenen, Anschluss an das vorige Kapitel) und gegen grobe Schnitzer gegen die Fakten; jede Ersetzung braucht einen Grund, Hinweise auf großgeschriebene Wörter ohne Fundstelle (`Worker.Jack.Epos.Hinweise`) sind ein Fingerzeig, nie eine Ablehnung; scheitert sie, gilt das Kapitel aus dem Schreiben. Die gemeinsamen Teile liegen weiter unter `Worker.Jack.Resuemee.*`; sie in einen neutralen Namensraum zu verschieben ist ein eigener Schritt.
- **Epos-Kapitel durch den Epos-Jack** (J6 #1210 E4, Epic #1195; Stufen `epos_ueberblick` → `render_epos` → `epos_durchsicht`, `Worker.Jack.Epos.Pipeline`) — an der Stelle des früheren Render-Kapitels; `Render.render_epos` ist entfernt, **es gibt keinen Rückfall**. Die Reihenfolge bleibt Resümee → Chronik → Epos → Bogen-Progressionen: das Epos braucht den eben abgelegten Stand des Resümee-Jack, aus dessen GLIEDERUNG kommt der **Weg** (`Worker.Jack.Epos.Eingabe`). **Frei geschrieben** (Maintainer, 13.09.2026): keine Prüfung je Satz, keine Länge, keine Pflicht je Szene; Stil aus „Stil setzen“ hat Vorrang, „Handlung treu, Erzählweise frei“ steht im Auftrag. **Anders als das Resümee ist das Epos best-effort, alle drei Läufe:** scheitern Überblick oder Schreiben (Klassen `epos_ueberblick_ohne_abschluss`/`epos_schreiben_ohne_abschluss`; ein Fehler vor den Läufen — Modell, Kontextfenster, Eingabe — oder ein Raise ist ein Fehlschlag von `render_epos` mit der Klasse seines Grundes), gibt es kein neues Kapitel, **das bisherige bleibt stehen und der Lauf geht weiter** (Bogen-Progressionen). Scheitert nur die Durchsicht (`epos_durchsicht_gescheitert`), wird das Kapitel aus dem Schreiben veröffentlicht. **#753 bleibt:** ein Kapitel mit GM-Edit schreibt die Pipeline nicht neu, der Epos-Jack läuft dann gar nicht (die Stufe `render_epos` meldet wie früher „fertig“). **Kapitelkopf:** deterministisch wie bisher (`Render.chapter_header/3` aus den eben veröffentlichten Chronik-Einträgen, #752/#1092), vor das Markdown des Jack gesetzt. **Modell:** `epos_jack_model` (Feld im Block „Jack: Extract/verify“, **leer = Jacks Modell**, Leser `Worker.Jack.Epos.Pipeline.modell_name/0`); Endpunkt, Regler und Kontextfenster wie Jack. **Ereignisse:** `EposEntryEdited` in der bisherigen Form (`entry_id` = session_id, `parent_id` = campaign_id), additiv `quellen` (je Absatz `absatz`, `titel`, `szene`, `fakten`, `fakt_ids`) und `zaehlwerte`, `epos_backend: "jack"` und als `epos_model` das Modell des Epos-Jack. **`source_refs` sind seitdem die Block-Belege der Fakten dieser Sitzung aus den Szenen, die ein Absatz erzählt** (vorher: aller Fakten); ein Absatz ohne Szene trägt nichts bei. Sprungmarken, Sync-Index und 🕳-Marker (`epos_chapter:<id>`) lösen sie unverändert über `Worker.Repo.GlattQuellen` auf; die Quellen stehen im Event und im Stand, der Fold speichert sie nicht (Tabelle unverändert). Dazu `JackEposStandAbgelegt` (Tabelle `worker_jack_epos_staende`, eine Row je Sitzung, LWW über `event_id`, Cascade bei `SessionDeleted`/`CampaignDeleted`; die drei Jack-Tabellen legt `Worker.Schema.JackTabellen` an — `schema/mnesia.ex` lag an der 600-Code-Zeilen-Grenze): Notizen (FORM, SZENEN, ABWEICHUNG, OFFEN), Entwurf, Quellen, Zählwerte, Modell, Zeitpunkt. **Leser im selben Change:** `vorige_gedanken` zeigt zu früheren Sitzungen auch die Notizen des Epos-Jack, `suche_bisher` durchsucht sie unter „Notizen der Jacks“ („Epos-Notiz“). **Laufband und Laufsicht:** der Überblick zählt gelesene Fakten, die Durchsicht entschiedene Absätze je Durchgang, das Schreiben nichts (derselbe Melder wie beim Resümee, `Worker.Jack.Resuemee.Melder.gemeldet/5`); die Titel heißen nach der Epos-Spalte („Geschichte: Überblick“ …); die Epos-Spalte zeigt „arbeitet“ in allen drei Stufen (die Resümee-Spalte seitdem ebenso in allen drei ihren). Die lokale Laufsicht erkennt die Läufe an `"jack" => "epos"` und zeigt Szenen, Stationen des Wegs, Kapitel und Durchsicht. „Neu generieren“, der Kampagnen-Replay und „noch N Iterationen“ schreiben das Kapitel neu — alle laufen durch `run_wahrheitsbild`; von Hand: `Worker.Jack.Epos.Pipeline.schreiben/3`, dann `veroeffentlichen/4` mit dem Bestand der Sitzung (der Kopf kommt dann aus der gespeicherten Chronik). **Stage 5 entfällt** (s. unten „Seit #783 Phase 2“). **Stil setzen, Epos-Tab:** ein Hinweis statt der Live-Prompt-Vorschau (s. „Stil-Flavors“). **Ehrliche Grenzen:** nicht gegen ein echtes Modell gemessen (das ist E5, die Teststage), nur mit geskriptetem Modell getestet; die Zuordnung Absatz → Szene → Fakten sagt, welche Szene ein Absatz erzählt, nicht, dass er ihre Fakten wiedergibt; die Dirty-Neuableitung nach einer Kuration schreibt das Kapitel nicht neu (wie zuvor); ein Worker-Neustart mitten im Lauf verliert ihn, das bisherige Kapitel bleibt.
- **Geschwister-Render** (Status `"timeline"`; bis J6 auch `"render_epos"` für das Epos-Kapitel, bis J5 `"render"` für das Resümee) — Timeline/**Epos-KAPITEL pro Session** aus den **verifizierten** Fakten (das frühere Render-Gating ist mit #1124 entfallen, s.o.; das Kapitel schreibt seit J6 der Epos-Jack, s. vorigen Punkt); #752: Kapitel pro Session (bis J6 strikt isoliert aus E_n — der Epos-Jack liest die früheren Kapitel mit), deterministischer Kapitel-Kopf aus der Timeline-Tag-Range (seit #1092 als **Datum** formatiert, nicht als roher Epochen-Tageszähler — s.u.), Datenmodell entry_id=session_id/parent_id=campaign_id, Legacy-Buch („Alt-Epos") koexistiert in der UI. Timeline+Epos sind fehler-entkoppelte best-effort-Geschwister. **Seit #838 kommt ein drittes Geschwister dazu: die Prosa-Progression pro Handlungsbogen** (`publish_wahrheitsbild_arc_progressions/3`, Stage 4 wiederverwendet — kein eigener Stage 6, analog dem ursprünglichen Epos-Precedent) — EIN LLM-Call pro (Session × in dieser Session berührtem Bogen), Fehlerisolierung PRO BOGEN innerhalb des Schritts (nicht nur am äußeren best-effort-Wrapper, Design J: ein fehlschlagender Bogen darf weder andere Bögen noch den Rest der Pipeline mitreißen). Speicherung: EIN eigenständiger, NIE überschriebener Eintrag pro `{arc_id, session_id}` (`worker_arc_progressions`, `ArcProgressionGenerated`) statt einer stets überschriebenen kumulativen Zeile — macht das Feature strukturell replay-sicher (ein Regenerate einer älteren Session rührt spätere Einträge desselben Bogens nie an, `Repo.get_prior_arc_entry/3` bestimmt den „vorherigen Eintrag" zur Lesezeit über die größte `session_number < aktuelle`, nie über einen gespeicherten Zeiger) und ist die Grundlage der Nachlese-Chronik oben. Prompt sieht nur den unmittelbar vorherigen Eintrag + die Session-Delta-Fakten (Backfill-Fall: volle Arc-Historie beim ersten Lauf nach dem Feature-Rollout für einen Bestandsbogen); (das frühere Render-Gate prüfte dagegen immer gegen die VOLLE Arc-Fakt-Historie — mit #1124 entfallen). **Seit #909 (Epic #900 S5) renderten Stage 4+5 ARC-STRUKTURIERT statt als flacher Fakt-Dump** (Resümee bis J5, Epos bis J6 — die Annotation `annotate_boegen` ist mit dem Epos-Render entfallen; die Zuordnung `Repo.fact_render_assignments/2` nutzt weiter der Chronik-Filter): `render_with_gate` annotiert die Fakten via `Repo.fact_render_assignments/2` (Label-Kette + FactArcSet-Override + Merge-Redirect — exakt dieselbe Präzedenz wie das Fäden-Panel, geteilte `Threads.effective_kind/3`). **Seit #953 ist die Zuordnung N:M** (`%{fact_id => [%{titel, kind}, …]}`): ein Fakt mit mehreren `threads`-Labels (oder einem Override-Set) wird unter JEDEN zugeordneten Bogen dupliziert (`annotate_boegen` flat_map). Ehrliche Grenze: derselbe Claim geht N-mal in den Render-Kontext → **Prompt-Gewichtsverzerrung** (ein Zwei-Bogen-Fakt wiegt doppelt); Prosa-Dedup ist Folge-Arbeit. (Das frühere Render-Gate lief auf dem Original-verified-Set und war gegen diese Verzerrung immun; es ist mit #1124 entfallen.) Reine Sekundär-Labels ohne eigenen Thread (das Panel gruppiert 1:1 übers Primär-Label) werden fürs Render synthetisiert (Titel = Kanon, kind aus der Registry). Der frühere Resümee-Prompt (bis J5 #1209; er speist nur noch die Stil-Vorschau eines älteren Hubs) gruppierte nach Handlungsbögen mit **sichtbaren fetten Bogen-Abschnitten** (1–2 Sätze pro Bogen, strang-lose unter „Weiteres", Ein-Fakt-Bögen wandern dorthin — Anti-Fragmentierung), der frühere Epos-Prompt (bis J6 #1210; er speist nur noch die Stil-Vorschau eines zurückgerollten Hubs) nutzte die Bögen als rote Fäden bei fließender Erzählung. **rauschen-Fakten fliegen immer raus, context-Fakten beim Resümee** (die Free-Seattle-Regelwerk-Ursache; galt für den früheren Resümee-Prompt — der Resümee-Jack liest alle Fakten, die Art steht an jedem, erzählen muss er nur die `arc`-Bögen); beim Epos reist context als „Hintergrund (nur Farbe)"-Sektion mit. Die Leitfrage ist NIE Prompt-Input (Gruppen-Kopf = kanonischer Bogen-Titel). Fallback-Kaskade statt Fehler: nur-context-Session → context flach, alles-rauschen → Voll-Liste + Warning; ohne Kampagnen-Kontext/Annotation (Stil-Vorschau; bis J4 auch `mix lore.eval.summary`) rendert der flache Alt-Prompt unverändert. Dazu der **fail-loud Prompt-Größen-Guard** (#889): Local-Backend + `estimate_tokens(prompt) > ctx_stage4` (bis J6 auch `ctx_stage5`) → Fehlerklasse `render_prompt_too_large` in `/admin/errors` statt Ollama-Silent-Truncation mit persistierter Entschuldigung (Cloud-Backends bewusst ungeguarded — sie ignorieren `num_ctx`, Oversize failt dort als `http_error`).

**Arc-Paarung über den Kanon (Issue #1071).** Bis #1071 fand ein Bogen seinen Strang über die
**Schnittmenge normalisierter Roh-Labels**. Roh-Labels sind Modellausgabe: formuliert der Extraktor
dasselbe Thema beim nächsten Lauf um, sieht eine Mengen-Schnittmenge zwei verschiedene Strings, der
alte Bogen verwaist und ein zweiter wird daneben geboren. Die Regel schützte gegen *Hinzufügen* und
*Weglassen* von Labels — **nicht gegen das Umbenennen eines Labels**, und genau das tut ein LLM
ständig. An `free-seattle-bereinigt` gemessen (2026-08-20): 12 Arc-Zeilen für 7 Stränge, 5 verwaist,
darunter `["auftrag"]` neben `["der auftrag", "der fixer-vertrag"]`, `["charakter"]` neben
`["kodex' charakter"]`, `["dante's inferno"]` neben `["die einladung ins dante's inferno"]`.

Gepaart wird jetzt über den **Kanon**: die gespeicherten Seeds laufen durch dieselbe Auflösung wie
ein Fakt-Label (Cluster-Map → `merge`-Identitäts-Override → Normalform), die Strang-Seite ist
`key_canonical`. Die Registry löst diese Synonymie ohnehin auf — die Arc-Paarung ging bloß an ihr
vorbei, obwohl die Stränge selbst darüber gruppiert werden. **`key_canonical`, nicht `canonical`**:
letzteres ist der Anzeigetext und trägt einen `rename`-Override; darauf zu paaren hieße, dass ein
Umbenennen im Panel den Bogen still von seinem Strang trennt. Beide Seiten normalisieren, weil die
Seeds Normalformen sind und `key_canonical` der menschenlesbare Gruppenschlüssel ist — ohne das
scheitert die Paarung an der Groß-/Kleinschreibung, ebenfalls lautlos. Lese- und Geburtspfad teilen
sich dafür EINE Quelle (`Worker.Repo.Threads.arc_kanons_by_id/1`); liefen sie auseinander, hielte
die Geburt einen Strang für gepaart, den der Reader nicht paaren kann. Genau diese Klasse hatte
#953 erzeugt — der Reader nahm pro Fakt nur das ERSTE Label, die Geburt alle; die asymmetrische
`thread_label_set/1` ist mit #1071 entfallen.

**Bei Gleichstand gewinnt die Kuration.** Zwei Bögen können kanonisch auf denselben Strang zeigen
(Alt- und Neu-Label desselben Themas). Vorher entschied darunter die `arc_id`, also ein Hash —
faktisch zufällig, und der Verlierer nahm im Zweifel die Handarbeit mit. Kuration heißt kuratierte
Leitfrage oder gesetzter Akt; danach wie gehabt Überlappung, dann `arc_id` für Determinismus.

**Ehrliche Grenzen.** Die Zahl der verwaisten Zeilen sinkt dadurch **nicht von allein** — an der
Referenz-Kampagne bleibt sie bei 5. Was sich ändert: drei davon finden kanonisch ihren Strang und
erscheinen im ⚠-Register als **Duplikat mit korrekter Merge-Vorauswahl** (ein Klick) statt als
heimatlose Waise; die anderen zwei gehören zu Strängen, die keine Arcs sind, und bleiben zu Recht
ohne. Automatisch zusammengeführt wird **nicht** (das schriebe Events auf Verdacht). Bei zwei
unkuratierten Duplikaten kann außerdem der *bisher* gepaarte Bogen zum Verwaisten werden und
umgekehrt — die Auswahl ist deterministisch, aber nicht stabil gegenüber dem alten Zustand; wo
Kuration im Spiel ist, schützt sie der Rang. Und der Kanon ist stabiler als ein Roh-Label, aber
nicht unveränderlich: der **Vollpfad** des Clusterings (GM-Knopf mit Warnung) darf Kanon-Texte
ändern — dann verwaist auch die Kanon-Paarung. Der inkrementelle Pfad (#842) ändert bestehende
Kanons nie; aus einem Nebeneffekt jedes Laufs wird damit die Folge einer bewussten Handlung.

### Stufe 2 ist Jack (Epic #1195, J4 #1207)

Seit J4 extrahiert kein einzelner Prompt mehr, sondern **Jack**: ein Agent mit Werkzeugen (`Worker.Agent`, `Worker.Jack.Werkzeuge`), der den geglätteten Mitschnitt einer Sitzung mehrmals liest (`Worker.Jack.Pipeline`, aufgerufen aus `run_wahrheitsbild`). Die alte Extraktion (`Stages`: Chunking, Map-Reduce, Halbierung, Satzgrenzen-Split, Salvage #1115, `facts_json_schema`) und Stufe 3 (`Verify`, LLM-Judge) sind entfernt; auch die Dirty-Neuableitung extrahiert mit Jack. Wie es zur Laufzeit in Elixir kam (pi behalten, einbetten oder nachbauen): `docs/Entscheidung-Jack-Harness.md`.

**Ein Durchgang** besteht aus **Gedächtnis** (Phase 1), **Extraktion** (Phase 2) und **Verifikationen** bis zur Sättigung — zwei Verifikationen in Folge ohne neue Aussage (ein Fund setzt den Zähler zurück), höchstens 8 (der Deckel des Referenzlaufs; erreicht heißt das Ende `:fertig`). Eine einzelne Verifikation ohne Neues ist auf kleinen Sitzungen die Regel, nicht das Ende: auf der Teststage endeten zwei Sessions mit der früheren Regel nach einer einzigen. Ohne `fertig()` in Phase 1 oder 2 scheitert der Lauf — ohne abgeschlossene Extraktion gibt es keinen Bestand, der für die Sitzung steht. Eine abgebrochene Verifikation behält dagegen, was sie eingetragen hat (jede Aussage ist einzeln geprüft), und Resümee, Chronik und Epos laufen weiter. Der **Regellauf** gehört ebenfalls in den Durchgang, ist aber **noch nicht gebaut**. Endet eine Antwort ohne Werkzeugaufruf, hakt die Laufzeit bis zu dreimal nach („Deine letzte Antwort enthielt keinen Werkzeugaufruf …“, `Worker.Jack.Phase.nachhaken/1`, im Betrieb und in den Messläufen, nicht im Fable-Referenzlauf). Anlass war ein Modell, das einen Aufruf als rohes Markup in den Text schrieb: Ollama sah keinen Aufruf, die Phase endete ohne `fertig()`, und die ganze Sitzung (14 Minuten) war verloren.

**Eingabe und Übersetzung.** Jack bekommt dieselbe Blockliste wie Kuration und Dirty-Weiche (`Smoothing.to_context/3`, danach der OOC-Filter) — seine Blocknummer n ist Position n in genau dieser Liste, nur so zeigt sie auf die richtige Block-ID —, dazu den Cast (`Worker.Repo.character_roster_for/1`) und die bestehenden Stränge der Kampagne. Sprecher heißen nach ihrem Kampagnennamen; wer keinen hat (ein ausgetretenes Mitglied, ein Erzähler ohne Mitgliedschaft), bekommt seinen Nutzernamen, sonst „Sprecher ohne Namen N“ (laut geloggt) — **eine Discord-ID erreicht Jack nie**. Die alte Extraktion setzte in diesem Fall still die Discord-ID ein. Jacks Bestand wird über `Parsing.parse_facts_json/2` zu Pipeline-Fakten (inhaltsbasierte IDs, Normalisierung, Zeit-Grounding, Dedup wie bisher; `beleg` und Jacks interne Felder fallen weg, ebenso verworfene — durch eine abdeckende Aussage ersetzte — Aussagen) und als EIN `SessionFactsExtracted` mit `extraction_saw`, `verify_backend: "jack"` und Jacks Modell publiziert. Jede Aussage hat die Belegprüfung bestanden (ein wörtliches Zitat je genanntem Block, `Worker.Jack.Beleg`): `grounded?`/`attributed?`/`verified?` sind `true`.

**Die Aufträge** liegen als Vorlagen in `apps/worker/priv/jack/auftraege/` (`phase1.md`, `phase2.md`, `folgelauf.md`; gemessene Fassung aus dem Spike #1174, Blockzahlen als `{{letzter_block}}`/`{{anzahl_bloecke}}`, Herkunft in `LIES_MICH.md`). Fehlt eine, scheitert die Extraktion laut. Ihre Beispiele stammen aus der Demo — **die gemessene Sitzung selbst kommt NIE ins Repo**; `auftragsvorlagen_test.exs` hält eine Liste ihrer Begriffe aus allen Vorlagen heraus.

**Jacks Stand ist ein Ereignis.** Nach jedem erfolgreichen Lauf publiziert der Worker `JackStandAbgelegt` (Tabelle `worker_jack_staende`, eine Row je Sitzung, LWW über `event_id` — nur der letzte Stand zählt; Cascade bei `SessionDeleted`/`CampaignDeleted`): Bestand, Gedächtnis samt Iterations-Notizen, Kollisionszähler und die Block-IDs der Liste, auf der Jack lief — ohne Jacks interne Journale. Als Ereignis kann jeder Worker der Kampagne darauf weitermachen. Darauf baut der Knopf **„noch N Iterationen“** (Resümee-Spalte, Bearbeitenmodus, Recht `:regenerate_session`; N wird auf 1..8 begrenzt und ist eine Obergrenze — bei Sättigung ist früher Schluss): nur Verifikationen auf dem abgelegten Stand, **ohne neue Glättung** (die Kontextliste kommt aus der gespeicherten Glättung), danach wie jeder Lauf — `SessionFactsExtracted` mit dem ganzen Bestand, neuer Stand, Registries, Resümee, Zeitstrahl, Epos. Weg: `Hub.Commands.request_jack_iterationen/4` → Push `start_jack_iterationen` → `Worker.HubClient.Replay.on_jack_iterationen/2` → `Pipeline.run_for_session(sid, jack_weiter: n)`. Jacks Blocknummern gelten nur für die Liste, auf der er lief; hat sie sich geändert (neu geglättet, ein Block `unbrauchbar`), lehnt `abgelegter_stand/2` **laut** ab (Fehler im `extract`-Schritt, `/admin/errors`), statt einen Bestand mit verrutschten Belegen zu erzeugen — der Ausweg ist der ganze Lauf über „neu generieren“.

**Einstellungen** (`/settings`, Block **„Jack: Extract/verify“**, `HubWeb.EinstellungenLive.JackBlock`): Modell `model_stage2_local`, Endpunkt `local_endpoint` (ein globales Feld, im Block nur angezeigt — eine Stelle zum Ändern, eine zum Lesen), `jack_temperature` 0.7, `jack_top_p` 0.8, `jack_frequency_penalty` 0.4, `jack_max_tokens` 60 000, `ctx_jack` 98 304. Die Defaults sind exakt die Werte der Messreihe C, damit sich Jacks Verhalten ohne Eingriff nicht ändert — die alten Stufe-2-Regler (0.15/0.7/1.1) hätten ihn still verstellt. Die Messläufe (`Worker.Jack.Messlauf`) lesen keine Einstellungen und bleiben dadurch vergleichbar. **`ctx_jack` steuert nur Jacks eigene Kompaktierung** (ab `ctx_jack` − Reserve fasst Jack seinen Verlauf zusammen). Das Fenster des Servers setzt der `/v1`-Client nicht (`Worker.Agent.Modell.Ollama`, dort gibt es kein `num_ctx`) — der Wert muss zu dem Fenster passen, mit dem Ollama das Modell lädt (Modelfile `num_ctx` bzw. `OLLAMA_CONTEXT_LENGTH`); liegt er darüber, wird der Verlauf am Server zu lang, bevor Jack zusammenfasst. Unter `Worker.Jack.Phase.mindestfenster/0` bricht der Lauf vorher ab (Klasse `ctx_jack_ungueltig`). Stufe 2 ist **immer lokal**. Entfernt sind `backend_stage2`, `model_stage2_{anthropic,openai,google,local_endpoint,think}`, `ctx_stage2`, `{temperature,top_p,repeat_penalty}_stage2`, `extract_num_predict_cap`, `extract_chunk_tokens`, alle Stufe-3-Keys und `grounding_context_window`. Seit J5 (#1209) steht im Block zusätzlich das Modell des Resümee-Jack (`resuemee_jack_model`, leer = Jacks Modell; s. „Resümee durch den Resümee-Jack“).

**Entity- und Thread-Registry laufen auf Jacks Modell und Endpunkt** (`complete(:summary, …)` ist fest lokal) und schicken **kein** `num_ctx` — so nutzen sie dieselbe geladene Instanz; ein abweichendes `num_ctx` ließe Ollama das Modell neu laden, mit 98 304 womöglich über den Grafikspeicher hinaus (CPU-Ausweichen). `ctx_jack` dient dort nur der Größenprüfung. Ein Quelltext-Wächter hält das fest, weil ein falsches `num_ctx` keinen Fehler erzeugt, nur einen langsamen Lauf.

**Sichtbar** ist Jack im Laufband (Gedächtnis → Extraktion → Verifikation, s. #1122 unten; seit J5 auch die drei Läufe des Resümee-Jack) und in der **lokalen Laufsicht** des Workers (`Worker.Jack.Sicht`, `config :worker, jack_sicht_port`, Default `127.0.0.1:8099`; in Tests aus). Sie bindet nur an Loopback, weil ein Lauf den Mitschnitt der echten Runde enthält. Eine Laufsicht im Hub für alle Mitglieder ist eigenes Ticket (#1208).

**Jede Teststage bekommt ihren eigenen Port: Stage-Port + 10** (#1211), je weiterer Worker eine Dekade darüber — Stage 4001 also 4011, ihr zweiter Worker 4021. `mix lore.pr_test` gibt ihn als `LORE_JACK_SICHT_PORT` mit, `runtime.exs` liest ihn wie die übrigen Per-BEAM-Overrides; ohne die Variable bleibt es bei 8099, also bei `worker_prod`. Der Versatz von 10 hält Abstand zu den Stage-Ports selbst (4001..4007), die Dekade trennt zwei Worker derselben Stage, ohne in den Bereich der Nachbar-Stage zu laufen.

**Ein belegter Port ist eine Warnung, kein Startfehler — und das ist teurer, als es klingt.** Im Betrieb schreibt niemand ein `protokoll.jsonl`; das Denken eines Laufs existiert ausschliesslich im Strom der Laufsicht. Startet sie nicht, ist es **unwiederbringlich weg**, und es gibt keinen zweiten Weg, es nachzulesen. Am 18.09.2026 lief ein ganzer Pipeline-Lauf so: die Teststage arbeitete blind, während auf 8099 die **leere** Sicht von `worker_prod` antwortete und Beobachtbarkeit vortäuschte. Wer einen Lauf beobachten will, prüft deshalb **im Worker-Log**, auf welchem Port die Sicht wirklich läuft (`Jack-Laufsicht: http://127.0.0.1:<port>`), statt sich darauf zu verlassen, dass ein Port antwortet.

**Ehrliche Grenzen.**

- **Nach dem Abbau nicht gegen ein echtes Ollama gemessen:** weder Jacks Regler über `/v1` noch die Registries ohne `num_ctx` noch der Grafikspeicher. Die Defaults sind die Werte der Messreihe C, gemessen vor dem Umbau.
- **Der Regellauf fehlt.**
- **Wie sich „gesättigt“ auf echten großen Sitzungen verhält, ist nur aus dem Fable-Referenzlauf bekannt** — und der zählt nach seiner eigenen Regel (`Worker.Jack.Referenz.Folge`). Jacks eigene Läufe auf solchen Sitzungen stehen aus.
- **Die entfernten Eval-Gates haben keinen automatischen Ersatz.** Verglichen wird von Hand gegen die Fable-Referenz (s. „Treue-Scoring … entfernt“ weiter unten); eine Regression der Extraktion rötet keinen Merge.
- **Eine Kuration kostet einen ganzen Durchgang:** die Dirty-Neuableitung (`:reextract`) ruft Jack mit Gedächtnis, Extraktion und Verifikationen über die ganze Sitzung, auch wenn nur ein Block geändert wurde. Wie lange das auf echten Sitzungen dauert, ist nicht gemessen.
- **Jack-eigene Fehler** (`{:jack, grund}`) werden seit J5 (#1209) auf ihren inneren Grund klassifiziert (`kein_stand`, `blockliste_geaendert`, `keine_glaettung` …) statt `other`; eine Phase ohne `fertig()` (`{:phase1_ohne_abschluss, …}` und Geschwister) hat weiter keine eigene Klasse und steht als `other`.

### CampaignLive: Lesen|Bearbeiten-Modus + Falsifikations-Flags (Epic #911 „Ernte statt Pflege", Cut 1 = #915)

Die CampaignLive hat **einen Layout mit einem Lesen|Bearbeiten-Toggle** (Header, neben „Pipeline neu starten"). Der Modus lebt in `HubWeb.CampaignLive.ViewMode` (`view_mode.ex`), Default **`:lesen`** (der Erfolgs-Prüfstein „öffnet ein Spieler es freiwillig?"), per-Gerät in localStorage gemerkt (`view_mode_persist.js`, Muster `PersistCols`). Der Toggle ist nur für Kuratoren sichtbar (`can_edit_mode?` aus `HubWeb.CampaignLive.Derive` — GM ODER Member-Kurator; `derive_assigns/2` wanderte in #915/Slice 1 aus `campaign_live.ex` in `Derive`, God-Module-Entlastung). Der Modus schaltet **Palette + Affordances = f(Modus)**, NIE die Autz-Schranke (jeder Edit prüft sein `can?/3`-Recht serverseitig selbst): Lesemodus = Nachlese-Band (Recap + offene Bögen, lazy über den bestehenden `campaign_nachlese`-Scope) + read-only Prosa-Spalten; Bearbeitenmodus = zusätzlich die Protokoll-Spalte, das Fäden/Themen-Panel, die Review-Queue, die Kurations-Tabs und die Prosa-Edit-Pencils. Ehrliche Grenze: die read-only **Fakten-Spalte ist Cut 2 (#916)** — dort wird sie editierbar; Epos-Edit-Pencil + geglättet-Kuratieren-Affordance sind in Cut 1 noch ungegated (Kurator-in-Lesemodus-Leak, serverseitig weiter geschützt); der Moduswechsel-Anker ist best-effort.

**Umschalten sofort, danach füllen (Issue #1200).** An seattleV4 gemessen (Teststage, Zustand der offenen Ansicht, 2.868 geladene Protokollzeilen, 860 Fakten): der Wechsel nach Bearbeiten war **eine** Antwort von **2.733 KB** — Kurations-Panels ~513, Protokoll ~660, Fakten ~1.561 —, bei nur ~40 ms Server-Rechenzeit. Der Knopf war ein reines `phx-click` und sprang erst um, wenn der Browser alles eingebaut hatte; zurück war die Antwort 1 KB, aber auch dort wartete er. Seitdem drei Schichten: (1) `view_mode_persist.js` setzt beim Klick `data-view-mode` am Wurzel-`div` **selbst**, Knopf-Farbe und `.nur-bearbeiten`-Ausblenden hängen per CSS daran (`app.css`); bewusst kein `JS.set_attribute` — das wäre sticky und überstimmte den Server nach einem Reconnect mit anderem Modus. (2) Die erste Server-Antwort trägt nur das Gerüst (Spalten mit Kopf, „Wird geladen …"). (3) Die schweren Teile folgen einzeln per `{:bearbeiten_fuellen, lauf, rest}` (`ViewMode.teile/0`: `kuration`, `protokoll`, `fakten`, kleinster zuerst) — jede Stufe eine eigene Antwort, `lauf` entwertet eine überholte Füllung. Die Stifte in Chronik und Resümee hängen seitdem am **Recht**, nicht am Modus (CSS blendet sie aus): hinge ein Listeneintrag an `@view_mode`, zeichnete jeder Wechsel die ganze Liste neu. Quelltext-Wächter in `campaign_live_view_mode_fuellung_test.exs`. **Ehrliche Grenze:** sofort wird das Umschalten, nicht die Seite leichter — die 2,7 MB kommen danach trotzdem, und solange der Browser sie einbaut, ist er beschäftigt. Die Menge selbst (Fakten ~1,8 KB je Zeile, Fäden-Panel mit jeder Fakt samt Bogen-Häkchen) ist eigene Arbeit. **Seit #1204 teilweise eingelöst:** die Fakten-Spalte bekommt je Session ein Fenster (50) und die Review-Liste lädt erst beim Aufklappen (s. „Der erste Aufbau zeichnet nur, was man sieht"); das Fäden-Panel ist unverändert.

**Falsifikations-Flag** (der EINZIGE erlaubte Spieler-Signal-Pfad, „stimmt nicht" — meldet, korrigiert nicht): Events `FlagRaised`/`FlagResolved`/`FlagDismissed` (Shared.Events). Ein Member flaggt ein **rebuild-stabiles Objekt** (`target_kind ∈ {session, arc, fact}`, `target_id ∈ {session_id, arc_id, fact-content-id}` — NICHT ein gerenderter Span), ein Kurator löst/verwirft. Worker-Seite: EINE `worker_flags`-Row pro Objekt (Key `cid:target_kind:target_id`), die drei Events konkurrieren um den geteilten Fold `:flag_status` (LWW-by-event_id, `Worker.Materializer.FlagFolds`); der Lesepfad (`Worker.Repo.Flags.flags_effective/1-2`) berechnet den effektiven Status zur **Lesezeit** — insbesondere **Auto-Resolve für Fakt-Flags**, deren fact-content-id nicht mehr existiert (weg-regeneriert → `auto_resolved`, kein Write, `luecken`-`verwaist`-Muster). Member-gated `campaign_flags`-Snapshot-Scope liefert nur die offenen Flags (⚠-Marker + Kurator-Queue). Hub-Seite: `:flag_raise` = Member-Recht, `:resolve_flag` = **GM-only in Cut 1** (`permissions.ex`); Melden-Button pro Session im Recap, ⚠-Marker wenn offen, Kurator-Queue (GM, Bearbeitenmodus) mit erledigt/verwerfen (`HubWeb.CampaignLive.Flags`, serverseitiges Gate). Melden-UI ist in Cut 1 auf Session-Ebene verdrahtet (Arc/Fakt-Melden-Buttons = Folge-Arbeit; Backend + Queue tragen alle drei target_kinds bereits).

**Editierbare Fakten-Spalte (Cut 2 = #916).** Die Fakten-Spalte (Bearbeiten-Palette) ist die direkte L1-Wahrheitsbasis-Kuration: **claim / character / thread / verified?-Override / löschen(ausblenden)**, je als LWW-Overlay-Event `FactCurationSet` (kein In-Place-Edit). **Anker = die Utterance-Menge** eines Fakts (`⋃ source_ref_block.quell_utterance_ids`), NICHT die content-adressierte Fakt-ID — der claim-Edit ändert die ID, die Utterance-Menge bleibt stabil → der Override re-attacht nach einem Regenerate (`Worker.Repo.Artifacts.apply_fact_curation/2`, `by_quell`-Paarung wie die Lücken-Overrides). Worker: **neue** Tabelle `worker_fact_overrides` (getrennt von `session_fact_overrides` #724 = Datum/dismiss), EINE Row pro (Anker, Feld) → unabhängige LWW-Slots. **Mehrdeutigkeit** (zwei Fakten identische Utterance-Menge): mengen-sichere Felder (character/thread/verified) angewandt, claim/dismissed geblockt + `override_mehrdeutig`-Flag (nie stille Falschzuordnung); nicht-paarende Overrides bleiben sichtbar. `list_campaign_facts/1` filtert `curation_dismissed` (Render/Verify/Timeline), `list_campaign_facts_curation/1` hält sie sichtbar (Fakten-Spalte, Un-Dismiss). Member-gated `campaign_facts`-Scope (lazy im Bearbeitenmodus). Hub: `:curate_facts` Member-Recht (`HubWeb.CampaignLive.Facts`, serverseitiges Gate; `anchor_hash` deterministisch aus der sortierten Menge). **Scroll-Sync (#1095).** Die Fakten-Spalte läuft im `ColumnSync` (#10) mit — sie fehlte dort bis #1095 an **zwei** Stellen: die Fakt-Zeile trug keinen `data-anchor-id` (der IntersectionObserver beobachtet nur `[data-anchor-id]`/`[data-utterance-id]`, die Spalte war also für ihn leer), und `Refs.build_sync_index/6` bekam die Fakten nicht übergeben. Fakten brauchen dabei **kein** `expand_refs`: ihre `quell_utterance_ids` sind bereits Utterance-IDs (die Kurations-Anker aus Cut 2), während Resümee/Epos/Chronik ihre Block-IDs erst zurückrechnen müssen. Der Rebuild in `apply_scope(_, "campaign_facts", _)` ist **Pflicht, nicht Optimierung** — die Fakten kommen über einen lazy geladenen Scope, nicht im Haupt-Snapshot; ohne ihn wäre der Index dauerhaft faktenlos (dieselbe Kante wie `campaign_luecken` seit #871). Ausgeblendete Fakten bleiben im Index, weil sie in der Spalte sichtbar sind. **Ehrliche Grenze:** der Sync greift für Fakten erst ab dem ersten Wechsel in den Bearbeitenmodus — davor sind sie nicht geladen, und es gibt nichts zu synchronisieren.

**Span-Flag-Upgrade (Cut 2):** additives `target_kind "span"` (tid = komma-verkettete Utterance-Menge), Span-Melden auf der Fakt-Zeile; Auto-Resolve gdw. die Menge keine aktuelle Fakt-Utterance mehr berührt (`flags_effective/3` `covered_utts`, disjoint). Bestehende `fact`-Flags unberührt. **Cut-2-Nebenfix:** `session_fact_overrides` war in KEINER Cascade — jetzt in beiden geräumt. Ehrliche Grenzen: Mehrdeutigkeit blockt claim/dismissed statt zu raten; Span-Melden nur aus der Fakten-Spalte; Anker-Drift bei Smoothing-Kompositions-Änderung → verwaiste (sichtbare) Overrides, Re-Attach nicht automatisch.

Jeder Schritt läuft in `with_status` → eigene Fehlerklassen in `/admin/errors` (#716); Jack, der Resümee-Jack und der Epos-Jack melden ihre je drei Stufen selbst (`Pipeline.stufen_melder/3`). **Seit #783 Phase 2 (+ Nachtrag) haben die Render-Schritte je ein eigenes Backend + Modell**: `backend_stage4`/`model_stage4_<backend>` (bis J5 das Render-Resümee, seit J5 #1209 nur noch die Bogen-Progressionen), bis J6 (#1210) `backend_stage5`/`model_stage5_<backend>` (Render-Epos-Kapitel — Nachtrag, war anfangs Teil von Stage 4). **Stage 5 ist mit J6 entfallen:** alle `*_stage5`-Keys (Backend, Modelle, Endpunkt, Denk-Schalter, Kontextfenster, Sampling, `num_predict`), der Einstellungsblock „Render — Epos-Kapitel“, die Migration `migrate_stage4_to_stage5_if_unset!/0` und der `Worker.LLM`-Slot `:epos` (ein Aufruf damit ist ein `KeyError`, `CloudHelper.model_for_stage/3` raist) — sie hatten nach dem Einbau des Epos-Jack keinen Leser mehr. Ein gespeicherter Stage-5-Wert bleibt im `worker_state` liegen, wird aber weder gelesen noch geschrieben (nicht mehr in der Whitelist; ein alter Hub, der ihn pusht, trifft auf `:error`). Das Resümee wählt sein Modell seit J5 im Jack-Block (`resuemee_jack_model`), das Epos seit J6 ebenda (`epos_jack_model`). **Stufe 2 ist seit J4 (#1207) immer lokal** (Jack, s. „Stufe 2 ist Jack“); `backend_stage2`, die Cloud-Modelle der Stufe 2 und alle Stufe-3-Keys (`backend_stage3`/`model_stage3_<backend>` …) sind entfernt, ein gespeichertes `backend_stage2` wird ignoriert (ein Cloud-Wert erzeugt beim Boot eine Warnung). Bis J4 hatte auch der Verify-Judge ein eigenes Backend, damit er gezielt stärker sein konnte als der Extraktor („fox guarding henhouse“-Vermeidung, der #783-Ursprungs-Usecase); diese Trennung ist mit dem Judge entfallen. Die früheren Phase-1-Overrides `judge_model`/`render_model` (gleiches Backend, nur anderes Modell) sind mit der vollen Trennung entfernt. **Provenance-Stempel:** `SessionFactsExtracted` trägt `verify_backend`/`verify_model` (seit J4 `"jack"` und Jacks Modell), `SessionSummaryGenerated` trägt `render_backend`/`render_model` (seit J5 `"jack"` und das Modell des Resümee-Jack), `EposEntryEdited` trägt `epos_backend`/`epos_model` (seit J6 `"jack"` und das Modell des Epos-Jack; additiv, reine Persistenz — macht einen Backend-Wechsel zwischen zwei Sessions sichtbar, ist aber kein Pin-Mechanismus; der bleibt Phase 4 der Multi-Worker-Architektur-Arbeit). **Migration für Bestandsworker:** `Worker.Application.migrate_stage2_to_stage4_if_unset!/0` kopiert beim ersten Boot nach dem Update die alten Stage-2-Werte einmalig nach Stage 4 (bis J4 `migrate_stage2_to_stage34_if_unset!/0`, auch nach Stage 3; die Stage-2-Werte kommen per rohem Store-Read, weil ihre Keys nicht mehr in den Defaults stehen), bis J6 `migrate_stage4_to_stage5_if_unset!/0` (Nachtrag) analog Stage 4 nach Stage 5 — mit Stage 5 entfallen; die übrige Migration ist idempotent, gated auf einem rohen `backend_stage4`-Store-Read — ohne sie würde ein Bestandsworker mit `:no_model_configured` brechen. **Stil-Flavors (#787):** die Campaign-Flavors (`base` + `summary`/`epos`) wirken beim **Resümee-Jack** und beim **Epos-Jack**, die Grundton und den Ton ihrer Spalte vor dem Schreiben bekommen (beides hinter der Extraktion — Stil kann keine Fakten einschleusen; Dazudichtung in der Prosa wird seit #1124 bewusst nicht mehr geprüft); die Extraktion ist stilfrei, die Timeline deterministisch (kein Ton-Slot). Der Stil-Editor in der CampaignLive hat Tabs Resümee/Epos/Chronik; **eine Live-Prompt-Vorschau gibt es seit J6 (#1210) nicht mehr** (bis J5 für Resümee und Epos, bis J6 nur noch für das Epos). Der Epos-Tab erklärt stattdessen, dass Jack das Kapitel frei schreibt, die Überschrift die Form bestimmt, der Epos-Ton die Erzählhaltung und der Weg aus dem Resümee kommt; `Hub.PromptPreview` samt Kanal-Handler ist entfernt. Der Worker beantwortet eine Vorschau-Anfrage weiter (`Prompts.preview_prompt/2` mit `build_summary_render_prompt`/`build_epos_render_prompt`, `Worker.HubClient.Rpc.on_preview/2`) — nur für einen zurückgerollten Hub. Der Resümee-Tab erklärt, dass Jack schreibt, die Überschrift die Form bestimmt und die Töne ihm vor dem Schreiben mitgegeben werden; seit #1209 hat er zusätzlich das Zahlfeld **„Länge des Resümees (Wörter)“** (das **Ziel**, Standard 150; Hilfetext und Hinweis im Tab sagen, dass das Resümee bis zum Doppelten wachsen darf, wenn der Weg der Gruppe es braucht, und nennen die Obergrenze; leer = Standard, gespeichert als `CampaignResuemeeLaengeSet`, nur bei Änderung; eine ungültige Eingabe speichert nichts und lässt den Editor offen — s. „Resümee durch den Resümee-Jack“), und die „gesetzt“-Plakette des Tabs zählt eine eigene Länge mit. Die Überschrift (`vorgaben[stage].name`) setzt bei allen drei den **Spaltentitel**; beim Resümee und beim Epos bestimmt sie zusätzlich die **Form** — die Jacks leiten sie im Überblick daraus ab (FORM-Notiz). Die frühere **„Darstellungsform“ ist entfallen** (Feld, Hub-Leser, Payload — der Hub schickt nur noch den Namen); Fold und Tabellenspalte lesen Alt-Events weiter, gelesen wird die Spalte nicht mehr. Epos-Kapitel-Köpfe sind deterministisch (#752), die Timeline hat keinen Prompt. Historie: Default-Flip auf Wahrheitsbild 2026-07-08 nach dem Free-Seattle-Real-Lauf; Retention: historische Chain-Events/-Artefakte bleiben lesbar (Materializer-Folds + Event-Schemas unangetastet, nur die Producer sind weg).

### Die Chronik schreibt Jack — Phasen statt Einzelereignisse (Issue #1211, J7)

**Die Chronik entsteht seit J7 in einem Agentenlauf**, nicht mehr
deterministisch. Der frühere Weg (`Pipeline.Zeit.publiziere/3`) liess jeden
verifizierten Fakt durch drei Filter laufen und machte aus jedem Überlebenden
einen Eintrag mit gerechnetem Tag. Das trug nicht, und zwar belegt: 543 von
544 Einträgen einer echten Kampagne lagen auf demselben Tag (#1092), 49 von 70
Einträgen einer Sitzung waren Zustände statt Ereignisse (#1119), und die
Zeitfelder, auf die sich die Rechnung stützt, bleiben praktisch leer (#1140).

**Die Arbeitsteilung: Jack urteilt, Elixir rechnet.** Ein Sprachmodell kann
Tage nicht verlässlich addieren. Es kann aber sagen, was vor, nach oder
gleichzeitig mit etwas anderem geschah, und es kann bündeln.

**Die Flughöhe ist die Produktentscheidung** (Maintainer, 17.09.2026): Ein
ganzer Auftrag — von der Annahme über die Anfahrt bis zur Abrechnung — ist
**eine Phase**, nicht zwölf Einträge; das geht regelmässig über
Sitzungsgrenzen. Einen eigenen Eintrag (`wichtigkeit: "schluesselszene"`)
bekommt nur, was die Kampagne oder die Welt verändert: der Tod einer
Spielerfigur, ein Krieg, eine Seuche, ein Epochenereignis. Ein erschossener
Wachmann ist Teil der Phase. Aus mehreren hundert Fakten sollen **etwa zwanzig
Einträge** werden.

**Zwei Betriebsarten, und die zweite ist der Normalfall.** Ist die Chronik
leer, läuft der volle Aufbau (Überblick → Schreiben → Durchsicht) — genau
einmal je Kampagne. Sobald eine Chronik existiert, läuft nur noch die
**Verfeinerung**: lesen, ergänzen, einordnen. Auch bei „neu generieren" und
beim Replay. Eine halb entstandene Chronik zählt als vorhanden; nichts wird
weggeworfen. **Geleert wird nie** — `ChronikClearedForSession` bleibt lesbar,
wird aber nicht mehr geschrieben.

**Der Chronik-Jack sieht als einziger die ganze Kampagne.** Resümee (#1209)
und Epos (#1210) lesen nichts aus späteren Sitzungen; ihr Gegenstand ist eine
Sitzung. Die Chronik ist kampagnenweit — ohne den Blick nach vorn liesse sich
eine Einordnung nicht prüfen. Bezüge über Sitzungsgrenzen sind erlaubt.

**Die Reihenfolge** (`Worker.Jack.Chronik.Ordnung`) rechnet aus den Bezügen
(`nach` / `vor` / `gleichzeitig_mit` / `absolut` / `isoliert`) eine Ordnung.
Drei Entscheidungen darin: „gleichzeitig" ist **keine Kante, sondern eine
Klasse** (zwei gegenläufige Kanten wären ein Zyklus, und die Ordnung meldete
einen Widerspruch, wo Jack etwas Zulässiges gesagt hat); ein Widerspruch ist
ein **Befund** (`{:zyklus, ids}`) statt eines stillen Rückfalls auf `unknown`,
wie ihn `Timeline.Graph` für Einzelfakten macht; und bei Gleichstand
entscheidet die **ID**, damit zwei Worker dieselbe Reihenfolge zeigen (die
#1092-Lehre).

**Das Datum entsteht nur, wo ein Anker es trägt**
(`Worker.Jack.Chronik.Datierung`). Ein im Spiel genannter Zeitpunkt datiert
seine Stelle; der Session-Anker datiert den **ersten** Eintrag, nicht alle —
ihn auf jeden zu legen war der alte Fehler. Ein Eintrag zwischen zwei festen
Punkten bekommt die Mitte, aber mit **gröberer Präzision** (bis zwei Tage
Abstand taggenau, bis ein Vierteljahr monatsgenau, darüber das Jahr). Bleibt
ein Eintrag ohne Anker in Reichweite, bleibt er **ohne Tag** — lieber keine
Angabe als eine gerechnete, die niemand nachprüfen kann.

**Die Regeln stehen in den Werkzeugen**, nicht im Auftrag: Fakten müssen
existieren, ein Fakt liegt in höchstens einer Phase, das Ziel eines Bezugs
muss existieren, Kuratiertes wird nicht gestrichen (ergänzen und einordnen
aber schon — sein Text bleibt vollständig stehen), und ein Eintrag, auf den
sich andere beziehen, wird nicht entfernt. `fertig()` lehnt ab, solange ein
**ereignisförmiger** Fakt in keinem Eintrag liegt; Zustände zählen nicht mit
(#1119).

**Der Überblick hat eigene Notizen** (`Worker.Jack.Chronik.Notizen`,
Abschnitte PHASEN, SCHLUESSELSZENEN, OFFEN). Der **Abschnitt IST die
Wichtigkeit** des Eintrags, den das Schreiben daraus anlegt — deshalb trägt
`notiz` kein eigenes Feld dafür. Dieselbe Regel wie beim Schreiben: ein
Geschehen liegt in höchstens einer Gruppe, und `fertig()` lehnt ab, solange
eines in keiner liegt. Keine FORM, kein Deckel: wie viele Abschnitte eine
Kampagne hat, entscheidet die Kampagne; die Flughöhe steht im Auftrag, nicht
als Schranke im Werkzeug.

**Das war der Defekt des ersten echten Laufs** (18.09.2026, seattleV5 S1):
Der Überblick brach nach 638 s mit `{:wiederholung, "notiz"}` ab und konnte
unter keinen Umständen gelingen. Drei Ursachen, die zusammenwirkten — `notiz`
war unverändert das Werkzeug des Resümee-Jack (es sprach vom Resümee und
erzwang FORM/GLIEDERUNG/OFFEN), `Stand.abschnitte(:chronik)` fiel über einen
**Auffangzweig** still auf ebendiese zurück, und `Abschluss.hindernisse/1`
prüfte gegen die Chronik-**Einträge**, die es im Überblick noch nicht gibt:
Es verwies auf `chronik_eintrag()`, ein Werkzeug, das dieser Lauf gar nicht
hat. Jack wiederholte, bis die Sperre (#1174) den Lauf beendete.

Zwei Lehren daraus, beide im Code verankert: **`Stand.abschnitte/1` hat
keinen Auffangzweig mehr** — eine unbekannte Art wirft, statt still die
falschen Abschnitte zu liefern. Und ein Test darf einen Agentenlauf nicht
nur mit einem geskripteten Modell fahren, das `fertig` aufruft: Geprüft wird
seitdem der **ganze Weg** (notieren → Ablehnung → vollständig zuordnen →
Abschluss, `chronik/notizen_test.exs`). Kein bestehender Test hat die
Ablehnung je erreicht.

**Drei Korrekturen aus dem ersten Review der gerenderten Aufträge (18.09.2026),
alle vor dem zweiten Lauf gebaut:**

- **Der Eintrag speichert die ECHTEN Fakt-IDs.** Jack kennt Fakten nur als
  `S1-F12` (Position im Bestand); bis zum Review speicherten die Werkzeuge
  genau diese kurze Form — entgegen dem Moduledoc der Eingabe, das das
  Gegenteil behauptete, und ohne einen Test, der die Formen unterschied. Nach
  einem Regenerate hätte jeder Eintrag stumm auf andere Fakten gezeigt (die
  K6-Klasse). Jetzt übersetzt `Entwurf.fakt_ids/2` an genau EINER Stelle in
  die inhaltsadressierte ID; zurück in die kurze übersetzen nur die Anzeige
  der Durchsicht und die Ablehnungen (das Modell kennt nur die kurze). Die
  Eintrags-ID (`chr-<sha1 der sortierten echten IDs>`) ist damit über Läufe
  stabil, solange die Fakten es sind.
- **`zeit_bezug` ist eine LISTE.** „Gleichzeitig mit A und nach B" war mit
  einem Bezug nicht sagbar. `Ordnung.bezuege/1` ist die eine Lesestelle für
  beide Formen (eine gespeicherte Map wird zur Ein-Element-Liste, `isoliert`
  zur leeren Liste) — Bestand bleibt lesbar, geschrieben wird die Liste.
  Der Sortierer war schon ein Graph (Union-Find + Kahn), die Liste ändert
  nur den Kantenbau; weil dadurch mehr Kreise möglich sind, meldet
  `{:zyklus, ids}` seitdem nur den **Kern** (Knoten auf einem Kreis), nicht
  den Anhang dahinter. Permutationstest: dieselben Bezüge in anderer
  Reihenfolge ergeben dieselbe Ordnung.
- **`NICHT_ZEITLEISTE`** (Notiz-Abschnitt, in allen drei Läufen): Geschehen,
  das in keine Zeitleiste gehört (Würfelmechanik, Tischgespräch ohne
  Handlungsfolge), legt Jack mit Begründung dort ab; es gilt als behandelt,
  wird nie ein Eintrag, und der Trichter zählt es als `fakten_ausserhalb` —
  getrennt von `fakten_ohne_eintrag`, damit „bewusst draussen" von
  „verschluckt" unterscheidbar bleibt. Ohne den Abschnitt zwang `fertig()`
  Jack, alles irgendwo unterzubringen — also auch das, was nicht hineingehört
  (Maintainer-Anweisung). Dazu haben die **geteilten Werkzeugbeschreibungen**
  (`bloecke`, `block`, `boegen`) jetzt Chronik-Klauseln — vorher nannten sie
  dem Chronik-Jack das Resümee und ein `fertig(ausgelassen)`, das er nicht
  hat: dieselbe Klasse wie der `notiz`-Defekt.

**Was der erste durchgelaufene Lauf lehrte (18.09.2026, seattleV5 S1).** Er
kam durch — Überblick fünf Gruppen, Schreiben vier Einträge, `fertig`
angenommen, 15 Runden, 31 Minuten — und **die Chronik blieb leer**: Die
Durchsicht starb an `{:badmap, nil}` im Stand-Abbild, die Exception riss den
Prozess mit, veröffentlicht wurde nichts. Vier Befunde, alle gebaut:

- **Jeder Jack braucht sein eigenes Abbild für Beobachter.** Der Chronik-Jack
  hatte keins, also fiel der Halter auf das des Resümee-Jack zurück — die
  Laufsicht zeigte `jack: "resuemee"` mit Wörtern und Gliederung, und in der
  Durchsicht wurde daraus ein Absturz. `Chronik.Notizen.abbild/1` trägt jetzt
  die Zahlen dieses Jacks (Phasen, Schlüsselszenen, `ausserhalb`, offene
  Geschehen, Zyklen, Durchsicht-Stand); `Chronik.jack/0` gibt es mit.
  Dieselbe Auffangzweig-Klasse wie `abschnitte(:chronik)` und die geteilten
  Werkzeugbeschreibungen — dreimal am selben Tag.
- **Die Durchsicht ist best-effort auch gegen ein RAISE**, nicht nur gegen
  ein Fehler-Tupel (`durchsehen/5` hat ein `rescue`, Quelltext-Wächter in
  `chronik/kette_test.exs`). Ein Fehler in der letzten, verzichtbaren Stufe
  darf die Arbeit der vorigen nicht vernichten. Für die Kette gab es bis
  dahin **keinen** Test, nur für ihre Bausteine.
- **Werkzeug `offen()`** in allen drei Läufen: die Geschehen, die noch in
  keinem Eintrag liegen, **mit ihrer Aussage**. Im Denkstrom war zu sehen,
  wie Jack sich sonst durch 112 Fakten hakt („✓ F73: in Entry 3 … Wait, what
  about F81?"). Dazu nennt jede Antwort eines schreibenden Werkzeugs den
  Reststand (`Entwurf.reststand/1`), und `Abschluss.offene/1` ist die eine
  Stelle, die weiss, wogegen geprüft wird — im Überblick gegen die Notizen,
  beim Schreiben gegen die Einträge. Beide Verwechslungen sind an diesem Tag
  passiert.
- **`optional:` für die Bezugsliste.** Nach der Umstellung auf die Liste
  fehlten die Pfade `zeit_bezug.ziel`/`.zeit`, also verlangte das strenge
  Schema beide in jedem Element — `eintrag_einordnen` wurde viermal abgelehnt
  und war unbenutzbar. Der Schema-Pfad kennt keinen Index.

**Jedes Werkzeug ist erklärbar: `hilfe()`** (Maintainer-Anweisung, 18.09.2026;
`Resuemee.Werkzeuge.hilfe/1`, in `aus/3` vor allen anderen, gilt damit für
alle Jacks). Ohne Angabe die Liste mit erstem Satz, mit `werkzeug:` die
vollständige Beschreibung samt Feldern, Pflicht und Optional. `:frei`, ändert
nichts. **Alle 13 Auftragsvorlagen nennen es** — die Beschreibungen tragen
die Regeln und stehen nur einmal im Gespräch; nach einer Kompaktierung ist
der Wortlaut weg, und Fragen muss billiger sein als ein Probeaufruf, den die
Wiederholungssperre mitzählt.

**Die Ablehnung nennt die gezählte Zahl** (`Resuemee.Abschluss`, gilt für
alle drei Jacks). Bis dahin hiess es nur „das stimmt nicht mit der
Buchhaltung überein" — die Zahl blieb verborgen, damit Jack nachzählt statt
abzuschreiben. Am echten Lauf gesehen, was das kostet: Die Arbeit war
vollständig, Jack hatte sich um ein paar Fakten verzählt, und die Ablehnung
schickte ihn ins Nachzählen von 112 Fakten. Der Zweck des Abgleichs hängt an
den **Hindernissen**; sind die leer, trägt das Verschweigen nichts bei.

**Zustände: die Regel gilt für EINTRÄGE, nicht für Zugehörigkeit.** Die
frühere Formulierung („gehören nicht in den Zeitstrahl") hat der Maintainer
als grenzwertig benannt — zu Recht: Ein Zustand hat meist einen Anfang, und
das Etikett kommt aus der Extraktion, die laufzeit-ungegated ist; ein falsch
gelabeltes Geschehen fiele still heraus. Ein Zustand bekommt keinen **eigenen
Eintrag**, darf aber in einer Phase aufgehen, wenn er sie erklärt — und
`fertig()` verlangt ihn nicht. Die Aufträge sagen jetzt zusätzlich:
**entscheide am Inhalt, nicht am Etikett**.

**Zwei Werkzeuge gegen das Zählen und das Umschreiben** (beide
Maintainer-Wort, 18.09.2026, am Lauf beobachtet):

- **`fakt_umhaengen(fakt, von, nach)`** hängt EINEN Fakt um — im Überblick
  zwischen Notiz-Gruppen, beim Schreiben zwischen Einträgen, ohne die Texte
  anzufassen. `notiz` kennt nur „derselbe Schlüssel ersetzt", und
  `eintrag_ergaenzen` hängt nur an; wer einen Fakt umhängen wollte, musste
  Quell- und Zielgruppe mit ihrer **ganzen** Faktenliste neu schreiben — bei
  einer Phase mit 36 Fakten eine Wiederholung, die die Sperre mitzählt. Im
  Denkstrom stand es wörtlich: „I need to reorganize the groups by removing
  S1-F80 from weltbild and reapplying the seattle key without it." Der letzte
  Fakt wandert nicht heraus (eine Gruppe ohne Fakt trägt nicht, und die
  Eintrags-ID hängt an den Fakten); Ablehnungen nennen, wo der Fakt
  tatsächlich liegt.
- **`zahlen()`** nennt die Zähler des Laufs, auch die, die `fertig` als
  Quittung verlangt. Jack hat sie in **jedem** der drei Läufe falsch gezählt
  (108 statt 27 bewertete Fakten, 9 statt 8 Gruppen, dazu die Durchsicht);
  jede Fehlzahl kostet eine Runde, eine schickte ihn ins Nachzählen von 112
  Fakten. **Ehrlich dazu:** Der Zahlenabgleich ist damit keine Selbstprüfung
  mehr, sondern eine Bestätigung — geprüft wird inhaltlich über die
  Hindernisse, und die sind deterministisch. Der Abgleich hat in drei Läufen
  keinen einzigen inhaltlichen Fehler gefunden, aber vier Runden gekostet.

**Ein Name, eine Definition.** `Resuemee.Werkzeuge.aus/3` baut die Liste über
`Map.new(definitionen)` — zwei Definitionen gleichen Namens entscheidet die
Reihenfolge, also der Zufall. `fakt_umhaengen` gibt es zweimal (Gruppen und
Einträge), deshalb steht die Notizen-Variante nur im Überblick, und
`chronik/werkzeuge_test.exs` bewacht beides: kein Name doppelt, und jeder
Name aus `namen/1` hat eine Definition (sonst bricht `aus/3` mit `KeyError`).
Derselbe Test prüft, dass **jedes** Werkzeug jedes Laufs über `hilfe()`
erklärbar ist.

**Ein Werkzeugfehler ist kein Hindernis** (`Worker.Agent.Aufruf`, gilt für
alle Jacks). Eine Ausnahme im Werkzeug kam bis zum 18.09.2026 als
gewöhnliches `{:error, text}` zurück — für das Modell nicht von „dir fehlt
noch etwas" zu unterscheiden. Der Abschluss der Chronik-Durchsicht warf bei
JEDEM Aufruf `key :absaetze not found` (`Chronik.Abschluss.fertig` rief die
Resümee-Hindernisse, die `s.durchsicht.absaetze` lesen — die Chronik führt
`vorgelegt`/`erledigt`), und Jack verbrannte **28 von 51 Runden**: erst
Diagnose, dann der Versuch, das Feld zu erfinden, dann ein kompletter zweiter
Durchgang. Er hatte den Bug sogar richtig erkannt („This isn't something I
can fix by changing my parameters") und konnte trotzdem nicht aufhören — ein
Lauf endet nur über `fertig()`, und `fertig` ist `:frei`, läuft also nie in
die Wiederholungssperre. Seitdem sagt die Antwort, dass es **nicht an den
Angaben liegt**, und nach drei inneren Fehlern desselben Werkzeugs endet der
Lauf (`@innere_fehler_deckel`) — der Bestand bleibt, weil jeder Jack
veröffentlicht, was bis dahin steht. Der Rundendeckel liegt bei 5000; ohne
diesen Riegel liefe ein Bug im Abschluss stundenlang.

**Offen aus demselben Review:** `eintrag_ergaenzen` hängt Text an; werden
die Fakten einer Sitzung neu extrahiert und umformuliert, gelten sie als
offen, und die Phase wird ein zweites Mal geschrieben. Provenienz je
Textsegment ist eigene Arbeit. **Kein Eval gegen synthetische Seeds**
(Maintainer, 18.09.2026): Referenz ist seattleV5 bzw. der gesicherte
Teststage-Stand.

**Gemessene Laufzeit der Pipeline** (seattleV5 S1, 2.168 Utterances, 746
Blöcke, 112 Fakten, `qwen3.8:27b-text`, Teststage): **5,78 h** für den ganzen
Lauf. Davon Jacks Verifikation 2,6 h (6 Durchgänge, 46 %), Extraktion 47 min,
Resümee-Überblick 71 min, Epos zusammen 26 min, Jacks Gedächtnis 9 min. Die
Glättung samt Gap-Fill braucht **98 Sekunden** — sie ist entgegen der
#1062-Erfahrung auf dieser Kampagne kein Zeitposten. Die Zahlen samt
Mitschrift liegen unter `~/.local/share/lore-jack/laufzeiten/`; der
Fortschritt-Prozess hält sie nur im Arbeitsspeicher (#1122).

**Der Trichter wird gezählt** (#1111): Fakten hinein, Einträge hinaus, wie
viele Geschehen in keinem Eintrag liegen, dazu Zyklen und verwaiste Bezüge.
Bei einer gebündelten Chronik ist das die entscheidende Zahl — „gebündelt" und
„verschluckt" sehen im Ergebnis gleich aus. Genau dieser Zähler fehlte, als
wochenlang „16 → 175 Einträge" als belegter Erfolg in der Doku stand, während
die Wirkung null war.

**Gepflichtet ist die BEWERTUNG, nicht die Zuordnung** (Maintainer,
18.09.2026: „es darf keine pflicht geben — pflicht ist das sie bewertet
werden — also jedes ding anschauen — und wenn alle NICHT_ZEITLEISTE sind —
dann ist das ok"). Jeder Fakt muss entschieden sein: in einem Eintrag oder
mit Begründung unter `NICHT_ZEITLEISTE`. Was herauskommt, ist frei — stehen
am Ende alle Fakten ausserhalb, ist das ein gültiges Ergebnis, und die
Chronik bleibt zu Recht leer (eine Sitzung, die nur am Tisch stattfand, hat
keine Zeitleiste). Die Pflicht ist das Anschauen: Ein Fakt, den niemand
entschieden hat, ist unbemerkt verschwunden, und von aussen sieht das aus wie
ein gut gebündelter Abschnitt.

**Das gilt für ALLE Fakten, auch für Zustände.** Die frühere Regel nahm
`fact_type: "zustand"` von der Prüfung aus. An echten Daten ist das die
Mehrheit — **85 von 112 Fakten** an seattleV5 S1 (14 `ereignis`, 10
`absicht`, 2 `beziehung`, 1 `zustandsänderung`) —, und damit entschied ein
laufzeit-ungegatetes Extraktions-Etikett darüber, was die Zeitleiste
überhaupt sehen darf; Jack hat es im Lauf mehrfach selbst angezweifelt („F77
ereignis? No, it says zustand — wait"). Jetzt sieht er jeden Fakt, `offen()`
nennt die unbewerteten **mit Art und Aussage**, und die Aufträge sagen:
entscheide am Inhalt, nicht am Etikett. Ohne eigenen Eintrag bleibt ein
dauerhafter Zustand weiterhin (#1119) — das ist eine Regel über die Flughöhe,
keine über die Bewertung.

**Vorbereitung am Tisch gehört nach `NICHT_ZEITLEISTE`** (Maintainer-Wort):
Charaktererstellung, Regelerklärung, Weltvorstellung, Terminabsprachen. Im
Lauf plante Jack „Character creation 2080 (meta)" als Chronik-Eintrag und
nannte es selbst „meta"; zwei solche Einträge banden **73 der 112 Fakten**.
Nicht zu verwechseln mit dem, WAS dabei erzählt wird: Schildert die
Spielleitung die Vitas-Plage, ist der Inhalt Weltgeschichte und gehört in
eine Phase — nur der Akt des Vorstellens nicht.

**Keine Code-Prüfung gegen verschluckte Einschnitte** (Maintainer-Wort): der
Fakt-Typ `zustandsänderung` ist zu fein (jede Verletzung trägt ihn), und ein
Wortabgleich auf Todesfälle wäre das Verfahren, das #1109 abgeschaltet hat.
Die Regel steht im Auftrag, mit Beispielen.

**Datenmodell:** `worker_chronik_entries` trägt sechs Felder mehr
(`wichtigkeit`, `fakt_ids`, `zeit_bezug`, `rang`, `in_game_day_bis`,
`sitzungen`). Der `rang` hat beim Lesen Vorrang vor dem Tag — er IST die
Reihenfolge. Die Eintrags-ID hängt an den **Fakten**, nicht am Text (Muster
#916): Formuliert ein späterer Lauf denselben Abschnitt um, bleibt es derselbe
Eintrag, und Kuration wie Bezüge überleben. **Die Gestalt der Row steht an
EINER Stelle** (`Materializer.Chronik.row/2` und `aus_row/1`) — sie war an
sechs Stellen nachgebaut, und die neuen Spalten brachen 18 Tests mit einer
Meldung, die auf die Schreibstelle zeigt statt auf den Grund.

**Die Review-Liste ist abgebaut.** Sie sammelte, was der Rechner nicht
platzieren konnte; diese Kategorie gibt es nicht mehr. Ereignis
`SessionFactDateSet`, Fold und Tabelle bleiben lesbar (gesetzte Daten alter
Sitzungen, harte Anker für Jack), ebenso der Worker-Scope
`campaign_review_facts` für einen zurückgerollten Hub. Das Ausblenden eines
Fakts kann die Fakten-Spalte (#916).

**Ehrliche Grenzen.** `republish_timeline_for_session/1` ist stillgelegt: Es
gibt keinen deterministischen Weg zurück, und ein Modelllauf ist nichts, was
man als Nebenwirkung einer Kuration startet. Nach einer Kuration ziehen die
Fakten sofort nach, die Chronik erst beim nächsten Pipeline-Lauf. Die Spanne
einer Phase (Beginn und Ende) wird nicht gerechnet — dafür bräuchte es Tage an
den einzelnen Fakten, und genau die gibt es nicht. Der Epos-Kapitelkopf (#752)
nimmt sein Datum aus der Tagesspanne der Chronik-Einträge und bleibt ohne
Datum, wo keiner einen Tag trägt. **Und vor allem: ob die Flughöhe auf echten
Daten stimmt, ist nicht gemessen** — das zeigt erst ein Lauf mit dem echten
Modell.

**Seit Z3 (#1247) sieht der Chronik-Jack die Zeitlinie der Kette** — je Fakt,
mit dem Zitat, aus dem sie gelesen wurde, und **neben** dessen eigenem
`in_game_date`. Es ist ein Angebot mit Prüfpflicht: Er darf begründet
abweichen, soll nichts ungeprüft übernehmen, und wo etwas verdächtig aussieht,
liest er selbst im Mitschnitt nach. Details im Abschnitt „Die Zeit hängt an den
Äußerungen" weiter unten; der Session-Anker-Fallback in `feste_punkte/3` bleibt
davon unberührt, weil eine Chronik auch ohne Kette datieren können muss.

**Einstellung:** `chronik_jack_model`, leer = Jacks Modell.

### Die Zeit hängt an den Äußerungen: der Zeit-Jack und die Kette (Issue #1247)

Bis hierher trug der **Fakt** die Zeit, in Feldern, die die Extraktion
nebenbei ausfüllte. Das hat nicht getragen, und zwar belegt: 543 von 544
Chronik-Einträgen einer echten Kampagne lagen auf demselben Tag (#1092), der
deterministische Zeit-Vorlauf war gemessen wirkungslos und ist wieder
entfernt (#1213), und zwei der drei Ankerformen kamen in echten Daten **null
Mal** vor (#1109). Ein Fakt ist auch der falsche Träger: Er entsteht bei
jeder Extraktion neu, seine ID hängt am Wortlaut, und eine Zeitangabe an ihm
ist nach dem nächsten Regenerate weg.

**Seit #1247 hängt die Zeit an den Utterances** — der stabilsten Schicht des
Systems; sie werden nie neu erstellt.

#### Zwei Achsen

Maintainer, 20.09.2026: „es gibt 2 achsen — 1: die kette: in zeitlicher
reihenfolge, 2: die sprechlinie: was wann gesprochen wurde. 2 bleibt
unverändert, 1 wird komplett neu aufgebaut."

Vorher gab es nur eine: `Worker.Timeline.Linie` nahm die Sprechreihenfolge
und **mutierte** sie mit Verschiebungen. Was gesprochen wurde und wann es
geschah war dasselbe Ding — für eine Uhrzeit im Spiel fällt beides zusammen,
für einen Rückblick nicht. Am echten Lauf aufgeschlagen: Der Weltbau-Block am
Sitzungsanfang erzählt die Jahre 2000 bis 2011, die Sitzung spielt 2080; die
eine Achse las das als Folge und rechnete rückwärts.

#### Die Kette: ein Zeitstrahl, auf dem Bäume stehen

    Zeitstrahl:  [ Glied ]──[ Glied ]────────────[ Glied ]
                                │
                      ┌─────────┴─────────┐
                   [ Glied ]          [ Glied ]

Ein **Glied** ist ein zusammenhängender Kontext — eine Szene, ein Auftrag,
ein Abend. Es trägt die Äußerungen, die unmittelbar dazugehören, **und** kann
feinere Kontexte als Unterglieder enthalten. Ein Glied hängt **entweder am
Zeitstrahl oder an einem Glied**, nie an beidem; die Glieder an einem Glied
sind wieder eine Kette, mit denselben Wörtern (`vor`, `nach`, `anfang`).
Daraus folgt die Regel beim Versetzen: Ein Glied bewegt sich unter seinen
Geschwistern, nicht aus seinem Kontext heraus.

**Jedes Glied hat eine eigene Kennung, auf jeder Tiefe**, vergeben beim
Anlegen und **stabil über jede Änderung**: Wächst eine Szene um eine Zeile,
bleibt sie dieselbe Szene. Eine content-adressierte Kennung (Muster
`Linie.anker_id/3`) wäre hier falsch — sie änderte sich mit dem Schnitt, und
jeder Bezug zeigte danach ins Leere. **Der Preis ist benannt:** Eine
zufällige ID konvergiert nicht; zwei Worker, die dasselbe Glied bilden,
vergeben verschiedene. Hinnehmbar, weil ein Glied in EINEM Lauf entsteht und
dieser Lauf sein Autor ist — die Anker daneben bleiben content-adressiert und
konvergieren weiterhin.

**Die Äußerungen beginnen ohne Einordnung** (Maintainer: „jack soll bewusst
einsortieren"). Es gibt keine stillschweigende Übernahme der
Sprechreihenfolge; jede Äußerung braucht eine Entscheidung. Mit einem Default
hiesse „nicht angefasst" zweierlei zugleich: „die Reihenfolge stimmt hier" und
„ich bin noch nicht hingekommen".

**Die Kette selbst beginnt nicht leer** — sie gehört der Kampagne und ist
älter als der Lauf (s. „Die Kette ist persistent" unten). `Kette.neu/0` ist
der Anfang einer Kampagne, nicht der eines Laufs.

**Zwei Zeiten sind zwei Glieder.** Sobald in einem Abschnitt zwei
verschiedene Zeitpunkte der Spielwelt vorkommen, sind es zwei Glieder — auch
wenn derselbe Sprecher ohne Pause durchredet. Der Anlass war ein Lauf, in dem
ein Glied „Welteinleitung" über 127 Zeilen die Vitas-Plage (frühe 2000er),
die ersten Metamenschen (2010) **und** Ryumyo am Mount Fuji (24.12.2011)
trug: elf Jahre in einem Glied, das genau eine Zeit tragen kann. Der
Sprechabschnitt bleibt einer; die Kette ist nicht die Sprechlinie.

**Was hineingehört, entscheidet sich zweistufig** (Maintainer, 20.09.2026:
„tisch gehört nicht in die kette — die kette ist die timeline der
spielwelt"): Tisch fliegt immer heraus, auch wenn eine Uhrzeit darin vorkommt
(„es ist schon zehn, ich muss um vier aufstehen"); was in der **Spielwelt**
liegt, gehört hinein und an seinen zeitlichen Platz — auch Weltgeschichte,
die nie jemand gespielt hat.

Die Rechnung liegt pur in `Worker.Timeline.Kette` (`anhaengen/3`,
`unterhaengen/4`, `erweitern/4`, `versetzen/3`, `loeschen/2`, `draussen/3`).
Alle halten den Zeitstrahl **durchgehend**, und jede eingereihte Äußerung
steht **genau einmal** im ganzen Baum — das prüft `kette_test.exs` nach jeder
Operation als MENGE, nicht als Länge.

#### Die drei Läufe

    :gedaechtnis   den Ablauf verstehen, nichts setzen
    :einsortieren  durch den Mitschnitt gehen und einordnen
    :pruefen       die entstandene Linie lesen und geraderücken

Anders als die Extraktion **sieht dieser Jack sein Ergebnis**: `lies_kette()`
zeigt nicht die Eingaben, sondern die gerechnete Linie. Ein einzelner Anker
kann für sich richtig sein und die Reihe trotzdem falsch — das ist nur am
Ergebnis zu sehen.

**Der Prüf-Lauf erbt, was der Einsortier-Lauf getan hat** — Anker, Notizen,
Leseabdeckung, Einordnung, Kette und Konflikte, aus **einer** Liste
(`Zeit.erbe/1`), aus der beide Seiten lesen. Vorher stand sie an zwei
Stellen, und genau das ging schief: `kette` wurde übergeben und nie
ausgepackt. Der Prüf-Lauf startete vor einer leeren Kette, baute keine — sein
Auftrag sagt ihm, er solle von den Befunden ausgehen — und sein Stand gewinnt
am Ende. Die ganze Einsortier-Arbeit war weg, sichtbar nur an einem
Widerspruch in den Zahlen: 2168 Zeilen eingeordnet, null in der Kette.

#### Gespeichert wird nach JEDEM Werkzeugaufruf

Maintainer, 24.09.2026: „jeder werkzeugaufruf speichert in db" — und, auf den
Einwand „der Stand ist mehr als die Kette", geht der ganze Stand mit.

Der Anlass sind zwei Totalverluste an einem Tag: ein Lauf über 56 Minuten
(Wiederholungsschleife) und einer über 62 Minuten (2168 Zeilen gelesen, 1992
eingeordnet, 25 Glieder gebaut, dann Wiederholungssperre). Beide endeten mit
**null** Zeilen in der Datenbank, weil erst nach `Zeit.laufen/2`
veröffentlicht wurde — und dorthin kam keiner von beiden.

`Halter.start_link/2` nimmt dafür `:nach_aufruf` (`fn stand -> stand end`),
`aufrufen/3` ruft es nach jedem Werkzeug. **Der Halter weiss nichts vom
Speichern** — er ist geteilt (Resümee, Epos, Chronik, Zeit), und ein
Jack-spezifischer Schreibpfad dort wäre die Auffangzweig-Klasse aus #1211.
`Worker.Jack.Zeit.Speicher` schreibt drei Dinge und vergleicht jedes gegen
den Bestand, damit nur die Differenz als Ereignis rausgeht; ein Fehler dabei
wird laut geloggt und beendet den Lauf nicht.

#### Datenmodell

| Tabelle | Inhalt |
|---|---|
| `worker_zeit_kette` | **eine Row je Glied** (`ZeitKettengliedSet`). Schlüssel ist die Glied-Kennung; der Platz steht als Bezug auf die Kennung des linken Nachbarn (`vorher`) und des Elterngliedes (`eltern`). Gelöste Äußerungen liegen in derselben Tabelle mit `art: "draussen"` und der Utterance-ID als Schlüssel — die Schlüsselräume sind disjunkt. |
| `worker_zeit_anker` | eine Row je Anker (`ZeitAnkerSet`), content-adressiert über die sortierten Utterance-IDs. Eine menschlich abgesegnete Zeile überschreibt kein Lauf. |
| `worker_jack_zeit_staende` | der übrige Stand je Sitzung (`JackZeitStandAbgelegt`): Leseabdeckung, Einordnung, Notizen, Konflikte. |

Alle drei: LWW über `event_id`, **nie ein `:mnesia.delete`** — ein entferntes
Glied bekommt einen Grabstein (`entfernt: true`). Cascade bei `SessionDeleted`
und `CampaignDeleted`. `Worker.Timeline.Kette.zu_zeilen/1` und
`aus_zeilen/1` sind die Umkehrung voneinander; ein gerissener Bezug hängt das
Glied hinten an und **wird gemeldet**, statt es zu verlieren.

**Der Platz als Nachbar-Kennung war eine Entscheidung gegen zwei
Alternativen** (Maintainer, 20.09.2026): ein Bezug auf eine Äußerung des
Nachbarn (stabiler, aber die Reihenfolge müsste zur Lesezeit aufgelöst
werden) und ein Rang als Zahl (trivial zu sortieren, aber jedes Einfügen
schreibt die Nachbarn um).

#### Im Lauf

Eingehängt in `run_wahrheitsbild` als `zeit_gedaechtnis` und `zeit` (Gruppe
`zeit`, **best-effort**, keine Spalte) — nach Jacks Verifikation, vor dem
Resümee. Der Prüf-Lauf hat bewusst **keine** eigene Stufe: Er ist derselbe
Gegenstand wie das Einsortieren, und zwei Balken für eine Arbeit wären
irreführend. Ein Fehlschlag reisst Resümee, Chronik und Epos nicht mit; ein
`rescue` in `Pipeline.zeit_jack/4` fängt auch eine Ausnahme ab.

**Modell:** `zeit_jack_model`, leer = Jacks Modell. Eigene lokale Laufsicht
neben der von Jack: `LORE_ZEIT_SICHT_PORT`, sonst die Jack-Sicht **+ 10**
(Default also 8109 gegen 8099). `mix lore.pr_test` vergibt Stage-Port + 20 je
Worker — Stage 4005 bekommt 4025, ihr zweiter Worker 4045. Wie bei der
Jack-Sicht gilt: **im Worker-Log nachsehen, auf welchem Port sie wirklich
läuft**, statt einen anzunehmen; ein belegter Port ist eine Warnung, kein
Startfehler, und der Denkstrom eines Laufs existiert nur dort.

#### Gemessen am echten Lauf (seattleV5 S1, 2168 Äußerungen)

Der erste durchgelaufene Lauf (24.09.2026, 37 Minuten): **27 Glieder**, 1164
Zeilen eingereiht, 1004 draussen — alles entschieden, ein einziger Befund.
Die Weltgeschichte ist nach Zeitpunkten zerlegt (bis 2000 / 2010+2011 / nach
2011 / Gegenwart 2080 / Matrix-Crash 2060er), das Gelöste trägt brauchbare
Gründe (Charaktererstellung 389 Zeilen, Foundry-Technik 119, Regelklärung 75).

**Und trotzdem undatiert: alle zehn gesetzten Anker hatten `minute: nil`.**
Drei Ursachen, alle an genau diesen Werten gemessen:

* **Erläuterung im Wert** (fünfmal): „2070 (Konzernkriege, Fuji zerbricht)".
  Ohne den Klammerzusatz lesbar.
* **Zwei Ausdrücke mit Schrägstrich** (zweimal): „Ende 2011 / am 24. Dezember
  2011". Jeder für sich lesbar.
* **Dauer als Zeitpunkt** (dreimal): „60 Jahre her". Das lehnt der Parser zu
  Recht ab.

Dazu ein Parser-Mangel: „um 2010" war nicht lesbar, obwohl „2010" und „im
Jahr 2010" es sind — das Füllwort stand in keiner Liste. Es fällt jetzt, mit
derselben Schranke wie „kurz vor 2080": nur vor einer drei- bis fünfstelligen
Zahl, damit „um sieben" eine Uhrzeit bleibt.

**Jeder Hinweis nennt den Weg** (am laufenden Lauf gesehen, 25.09.2026). Jack
bekam „als Zeit lesbar ist er nicht — so ginge es: …", verstand es richtig und
wollte den Anker korrigieren — nur sieht kein Werkzeug nach „korrigieren" aus.
Er nahm `anker_ersetzen` (das eine Kennung aus einer **Rückfrage** braucht),
scheiterte an der leeren Kennung und benannte den Widerspruch selbst: „The
system accepted the anchor without asking for clarification, even though it
flagged that it couldn't read it clearly." Der Widerspruch ist echt — der
Anker GILT (er ordnet, er datiert nur nicht), und daneben steht „nicht
lesbar". Zwei Runden gingen verloren, dann fand er `nimm_anker_zurueck`
selbst. Seitdem sagt jeder Vorschlag beides: dass der Anker gilt, und dass
Ersetzen über `nimm_anker_zurueck` läuft; `anker_ersetzen` nennt in seiner
Beschreibung die Kennungspflicht und die Alternative.

**Die Antwort fragt jetzt, statt zu raten** (Maintainer, 24.09.2026: „man
muss den context auswerten — ‚um 7' kann beides sein"). Den Kontext hat genau
einer: Jack. Also probiert die Antwort beide Lesarten durch denselben Parser
und nennt nur, was aufgeht — „um 7" bekommt „sag es eindeutig, ‚7 Uhr' oder
‚im Jahr 7'", „um 70" nur „im Jahr 70" (70 ist keine Stunde). Das ist
ausdrücklich **keine** Bedeutungserkennung (#1109/#1213: zweimal gescheitert,
zweimal abgeschaltet), sondern eine Umformung mit anschliessender Prüfung.

#### Zurücknehmen können, ohne Ersatz

Ein Anker, der nicht trägt, muss weg — und das war bis zum 24.09. nicht
möglich. Im Denkstrom des Laufs steht fünfzehnmal derselbe Gedanke: die
Spanne „60 Jahre her" zieht die Linie auf 2055 zurück, sie braucht einen
Bezugspunkt, den es nicht gibt, *„the cleanest solution is to remove this span
entirely"*. Sechs Minuten, fachlich richtig erkannt — und `anker_ersetzen`
verlangt einen Ersatz, „nichts" ist keiner. Die Spanne stand am Ende des Laufs
unverändert da.

**Die Mechanik war längst gebaut**: `Setzen.loesche_kettenplatz/2` schreibt
die Rücknahme unter derselben Adresse mit Art `geloest`, samt der Begründung,
warum sie die Content-Adressierung dabei bewusst bricht — mit **null
Aufrufern**. Die Klasse „Apparat ohne Producer", zum dritten Mal in diesem
Repo (#724, #1109).

`nimm_anker_zurueck(zeilen, art, grund)` ist dieser Aufrufer. Das `art`-Feld
ist Pflicht, weil an einer Zeile mehrere Anker hängen dürfen (Spanne und
Zeitpunkt ergänzen sich, `Stand.an/3`); abgesegnetes bleibt, und die Absage
nennt Datum, Wortlaut und `melde_konflikt` als Weg. Der Grund steht danach an
der Stelle — ohne ihn wäre nicht nachvollziehbar, was Jack gesehen hat.

**Nebenwirkung: `anker.ex` riss die 600-Code-Zeilen-Grenze** (648).
Geschnitten ist nach der Frage, die ein Leser stellt — *setzt dieses Werkzeug
eine Zeit, oder hält es fest, dass keine gesetzt wird?* —, nicht nach Zeilen:
`Worker.Jack.Zeit.Vorbehalte` trägt `melde_konflikt`,
`kettenplatz_unklar` und `zweifel`. Der billige Schnitt (Definitionen gegen
Ausführung) hätte zwei Hälften derselben Sache getrennt. Dass die drei zusammen
knapp reichen, war Glück; dass sie zusammengehören, ist es nicht (#1097).

#### Die Kette ist persistent — ein Lauf ergänzt sie

Maintainer, 25.09.2026: „die kette ist ja persistent — jeder weitere lauf soll
diese kette ergänzen — nicht jede session schreibt eine neue kette." Als Frage
gestellt, und die Antwort war: **stimmte nicht**, an zwei Stellen.

**Jeder Lauf begann leer.** `Worker.Jack.Zeit.Eingabe.aus_repo/1` lud die
Kette nicht, `Stand.neu/3` fiel auf `Kette.neu/0` zurück — und weil
`Kettenspeicher.veroeffentlichen/4` gegen den Bestand vergleicht, bekam alles
Bestehende einen **Grabstein**. Ein Regenerate löschte damit die Kette der
Sitzung, statt sie zu ergänzen; seit „speichern nach jedem Werkzeugaufruf"
(derselbe Tag) passierte das schon beim **ersten** Aufruf, bevor der Lauf
irgendetwas eingeordnet hatte.

**Und über Sitzungsgrenzen gab es gar keine Ordnung.** Der Lauf sah die
Glieder anderer Sitzungen nicht und konnte nicht sagen, wo seine liegt; die
kampagnenweite Kette war eine Aneinanderreihung ohne verbindende Bezüge.

Seitdem lädt die Eingabe `Worker.Repo.Zeit.kette(campaign.id)` — **die ganze
Kampagne**, nicht die Sitzung, aus demselben Grund, aus dem die Chronik als
einziger Jack alles sieht: Geschehen hört an der Sitzungsgrenze nicht auf. Der
Stand erbt sie über `Zeit.erbe/1` (dieselbe eine Liste, aus der auch der
Prüf-Lauf liest).

**Drei Regeln im Speicher, und jede schliesst einen Verlustfall:**

- **Verglichen wird kampagnenweit.** Sonst gelten die Glieder anderer
  Sitzungen als neu, und der Lauf schreibt sie mit seiner `session_id` zurück.
- **Grabsteine nur für die eigene Sitzung.** Ein fremdes Glied, das in dieser
  Kette fehlt, ist kein gelöschtes — es ist eines, das dieser Lauf nicht
  kennt. Es zu begraben hiesse, fremde Arbeit wegzuwerfen.
- **Ein bestehendes Glied behält seine Sitzung** (`sitzung_fuer/3`, die Row
  trägt sie seit diesem Cut lesbar mit). Ohne das wanderte ein Glied bei jeder
  Änderung durch einen fremden Lauf mit, und `kette(cid, sid)` zählte es
  plötzlich anders.

Der Vergleich lässt `session_id` und `glied_id` aussen vor: Beide stehen in
Row-Spalten, nicht im Blob — ohne das sähe jede bestehende Zeile geändert aus,
und der Lauf schriebe die ganze Kette bei jedem Werkzeugaufruf neu.

**Der Auftrag sagt es jetzt auch.** „Die Kette ist älter als dieser Lauf": Du
ergänzt, du baust nicht neu; fremde Glieder darfst du erweitern und versetzen
(mit Grund), löschen ist die Ausnahme; und wo deine Sitzung liegt, entscheidest
du — meistens hinten, aber ein Rückblick am Sitzungsanfang gehört zwischen die
alten Glieder. Ein bestehender Wächter (`auftragsvorlagen_test.exs`) hing an
dem Satz „Die Kette beginnt leer" und hat den Widerspruch gefangen; er prüft
jetzt die neue Aussage.

**Die Einordnung kommt aus der geladenen Kette** (Maintainer, 25.09.2026: „ich
will den ersten Lauf nicht noch mal machen müssen, bevor wir den Lauf mit
Kette testen"). Ohne das war die Persistenz **halb**: Die Glieder überlebten,
die Einordnung nicht. Ein zweiter Lauf startete mit vollständiger Kette und
leerer `einordnung` — und weil `Stand.ohne_einordnung/1` genau die prüft,
verlangte `fertig()` eine Entscheidung für jede der 2168 Zeilen, die längst in
einem Glied liegen. Eine Stunde Modellzeit, um zu einem Zustand zurückzukehren,
der schon da war.

Abgeleitet, nicht erfunden: Eine Zeile in einem Glied ist `:ingame`, eine in
`draussen` ist `:tisch` — beides steht in der Kette und wird nur gelesen. Ein
ausdrücklich übergebenes `einordnung:` gewinnt, weil der Prüf-Lauf sie samt
Zweifeln erbt und **`:zweifel` aus der Kette allein nicht ableitbar** ist: Eine
unklare Zeile liegt darin wie eine sichere.

**Ein Lauf ohne geladene Kette begräbt nichts.** Der Speicher kann zwei
Zustände nicht am Zustand unterscheiden — „Jack hat das Glied gelöscht" und
„dieser Lauf hat die Kette nie geladen"; in beiden Fällen fehlen eigene
Glieder. Der Produktionspfad lädt sie (`Eingabe.aus_repo/1` liefert immer eine,
bei frischer Kampagne eine leere), aber `Zeit.laufen/2` ist öffentlich und
nimmt eine Eingabe-Map: Ein Test, ein Messlauf oder ein RPC von Hand mit
`session_id` und `campaign_id`, aber ohne `kette:`, hätte am 25.09.2026 die 13
Glieder der Teststage beerdigt — beim **ersten** Werkzeugaufruf, lautlos.

Unterschieden wird deshalb an der **Herkunft** (`Stand.kette_geladen?`), nicht
am Zustand. Der erste Anlauf prüfte den Zustand und traf damit auch den
legitimen Fall „Jack löscht sein letztes Glied" — ein bestehender Test hat das
gefangen. Der Riegel loggt laut; ein stiller Riegel erzeugte dieselbe Klasse
wie die Lücke, die er schliesst.

**Er liest auch die früheren Sitzungen** (Maintainer, 25.09.2026: „er muss die
Sachen, die vor vorherigen Sessions erarbeitet wurden, lesen/bearbeiten
können"). Seit die Kette kampagnenweit lädt, **sah** er fremde Glieder — aber
nur deren Titel; sein Mitschnitt ist die eigene Sitzung, und `suche_bisher`,
`fakten` und `vorige_gedanken` der anderen Jacks hat er nicht. Für den
einfachen Fall reicht das; erzählt die Runde am Anfang einen **Rückblick**,
muss er erkennen, WELCHES alte Glied gemeint ist, und dafür braucht er dessen
Inhalt.

`Worker.Jack.Zeit.Frueher` gibt ihm drei Werkzeuge, in **allen drei Läufen**
(auch im Gedächtnis-Lauf, der gerade dort den Ablauf verstehen soll):
`sitzungen()` (Nummer, Zeilen, Glieder, ob Notizen da sind), `lies_frueher`
(Mitschnitt einer anderen Sitzung) und `vorige_gedanken` (die Notizen früherer
Zeit-Läufe).

**Die Nummern bleiben getrennt, und das ist die wichtigste Entscheidung
dabei.** Jacks Zeilennummer n ist Position n in **seiner** Liste — nur so zeigt
sie auf die richtige Utterance. Eine fremde Zeile mit derselben Nummer setzte
einen Anker an die falsche Stelle, lautlos. Fremde Zeilen tragen deshalb ein
Präfix (`S1/45`) und sind über die setzenden Werkzeuge nicht erreichbar; die
eigene Sitzung wird von `lies_frueher` abgewiesen, mit dem Verweis auf
`lies_sprechlinie`. **Fremde Glieder kann er MELDEN, nicht bearbeiten** — und diese Doku hat
zwischenzeitlich das Gegenteil behauptet. Die Ketten-Werkzeuge adressieren ein
Glied über eine **Zeilennummer des eigenen Mitschnitts**
(`Mitschnitt.aufloesen` → Utterance → Glied); für ein fremdes Glied gibt es
keine solche Zeile, es ist damit nicht ansprechbar. Gefunden hat es Jack im
Prüf-Lauf, als er einen falschen Anker in S1 fand — „um 10" als Uhrzeit
gelesen, gemeint war das Jahr 2010 — und fragte: „But I can't anchor in S1. So
what can I do?" Die Antwort war: nichts.

Seitdem nimmt `melde_konflikt` eine **Glied-Nummer** aus `lies_kette()`
(`Kettenwerkzeuge.glied_nach_nummer/2`) — die einzige Adresse, die auch für ein
fremdes Glied trägt. Melden ja, ändern nein: Die Begründung für die Sperre
bleibt richtig, ein falscher Anker ist aber kein Entscheid des anderen Laufs,
sondern ein Fehler, und er verbiegt die Linie kampagnenweit. Fremde Glieder
tatsächlich zu bearbeiten wäre eigene Arbeit.

**Und `lies_kette()` zeigt sie überhaupt erst seit diesem Fund.** Der Filter
verglich die höchste Zeilennummer eines Gliedes mit `ab`, und `max_nr/2`
liefert 0, wenn keine seiner Äußerungen im eigenen Mitschnitt steht — für ein
fremdes Glied immer. Jack sah nur seine eigene Hälfte und benannte es selbst:
„Ich sehe nur Glieder 15-34, aber die Befunde beziehen sich auf frühere Glieder
1-14 aus S1, die ich noch nicht gesehen habe." Er konnte die Befunde nicht
prüfen, weil ihre Glieder unsichtbar waren. Fremde Glieder gelten jetzt
unabhängig von `ab` und tragen „andere Sitzung" statt eines Strichs — ein
Strich sagt nicht, warum keine Nummern dastehen.

Ebenfalls von ihm gefunden: `sitzungen()` nennt Gliederzahlen vom **Beginn des
Laufs** (sie entstehen beim Bau der Eingabe). Nach 86 Runden stand dort 0,
während die Kette 34 hatte, und Jack hielt es für einen Datenfehler — „the
session shows 2660 lines with 34 chain elements, but the earlier output
indicated zero". Die Antwort sagt es jetzt und verweist für den aktuellen Stand
auf `lies_kette()`.

Geladen wird **beim Zugriff** (Muster `Resuemee.Mitschnitte`, #1210): Die
Übersicht reist vorgeladen mit (vier Zahlen je Sitzung), die Mitschnitte nicht
— bei seattleV5 wären das rund 12.000 Zeilen im Stand, die ein Lauf meist nie
ansieht. Der Prüf-Lauf erbt Übersicht, Lader und schon Geladenes über
`Zeit.erbe/1`, sonst lüde er jeden fremden Mitschnitt ein zweites Mal.

**Dabei bekam `worker_jack_zeit_staende` seinen ersten Leser**
(`Worker.Repo.Zeit.jack_stand/1`): Die Tabelle wurde nach jedem Werkzeugaufruf
geschrieben und nie gelesen — dieselbe Klasse wie `loesche_kettenplatz/2` in
diesem Ticket, zum zweiten Mal.

**Gemessen am ersten Lauf mit Bestand** (25.09.2026, seattleV5 S1, 14 Glieder
standen):

```
zeilen=2168 gelesen=2168 -> anker=11  kette=14 Glieder
(geschrieben=0 grabsteine=0)  geprueft=true  runden=9  ms=170815
```

**`grabsteine=0`** ist die Zeile, auf die es ankam — vorher hätte dort 13
gestanden. Der Einsortier-Lauf brauchte 9 Runden und 2,8 Minuten statt einer
Stunde: Er sah alle 2168 Zeilen als eingeordnet und ergänzte ein Glied, statt
alles neu zu entscheiden. `geschrieben=0` beim Abschluss, weil die
Zwischenstände nach jedem Werkzeugaufruf längst geschrieben hatten.

**Ehrliche Grenze:** Dass ein zweiter Lauf **derselben** Sitzung den Bestand
respektiert, ist gemessen (s.o.). Offen bleibt der Fall, um den es eigentlich
geht: ob er seine Sitzung relativ zu den Gliedern einer **anderen** einordnet,
statt sie hinten anzuhängen. Dafür hat er seit diesem Cut die Werkzeuge; ob er
sie nutzt, zeigt der Lauf auf einer Sitzung ohne eigene Kette.

#### Die Chronik sieht die Kette — als Angebot mit Prüfpflicht (Z3)

Maintainer, 25.09.2026: „die chronik soll sich entscheiden können die kette zu
benutzen — aber soll sich auch dagegen entscheiden dürfen", und schärfer: „er
kann und darf abweichen — und er soll nicht ungeprüft übernehmen."

`Chronik.Eingabe.mit_zeitlinie/2` hängt an jeden Fakt die Zeit, die die Kette
für seine Äußerungen kennt — **neben** dessen `in_game_date`, nicht statt
dessen. `Lesen.zeit_text/1` zeigt beides; wo sie sich widersprechen, sieht das
Modell den Widerspruch. Würde eines das andere ersetzen, gäbe es nichts zu
prüfen, und ein falscher Anker verbiegt die Chronik lautlos.

**Jede Angabe trägt ihren Beleg** — das wörtliche Zitat, aus dem die Zeit
gelesen wurde; ohne das wäre die Prüfpflicht nicht erfüllbar. Und **belegt und
gerechnet sind unterschieden**: Ein interpolierter Wert heisst „(gerechnet)",
und der Auftrag sagt, dass er für die Reihenfolge taugt, nicht für ein Datum —
genau der Fehler, der die Chronik einmal auf einen einzigen Tag gelegt hat
(#1092).

**Der Rang ist benannt, nicht dem Gefühl überlassen:** Die Zeitlinie ist
*meistens* die bessere Angabe (am gesprochenen Wort gelesen, von einem Lauf,
der nichts anderes tut), das Fakt-Datum ist ein Nebenprodukt der Extraktion.
Und wo etwas verdächtig aussieht, **liest Jack selbst nach** — `block(n)`,
`bloecke`, `suche_sitzung`, `fakt(id)`. Der Satz, um den es geht: zwei Angaben
gegeneinander abwägen ist ein Münzwurf, im Mitschnitt nachlesen ist eine
Prüfung. „Verdächtig" ist mit Beispielen unterlegt (Zitat aus einer anderen
Szene, Zeiten Jahre auseinander im selben Abschnitt, Datum gegen die gelesene
Reihenfolge, Zeitrede am Tisch).

**Der Befund, ohne den Z3 wirkungslos geblieben wäre:** `Linie.aus_kette/3`
rechnet auf **Gliedern**, und `auf_glieder/2` ersetzt dafür die
`utterance_ids` eines Ankers durch Glied-IDs. Damit lag `anker_an` unter
Glied-IDs, und `anker_fuer/2` fand für eine Äußerung **nie** einen Anker — es
lieferte nur die gerechnete Stelle, ohne Ausdruck und ohne Beleg. Unsichtbar,
solange niemand die Details braucht. Gefunden hat es der Test, weil er den
Beleg **einforderte**; ein Test auf „das Feld ist gesetzt" wäre grün gewesen.

**Best-effort auf beiden Seiten:** Läuft der Zeit-Jack nicht, fehlt das Feld,
und die Chronik arbeitet wie vor #1247. Ein Fehler beim Lesen der Kette wird
laut geloggt und lässt die Fakten unverändert — still wäre er nicht von „die
Kette hatte eben nichts" zu unterscheiden. Der Session-Anker-Fallback in
`Datierung.feste_punkte/3` bleibt bewusst stehen: Wer sich gegen die Kette
entscheiden darf, muss auch ohne sie datieren können.

#### Ehrliche Grenzen

* **Ob die Korrekturen an den Ankerwerten greifen, ist nicht gemessen.** Den
  bisherigen Hinweis („er ordnet, datiert aber nicht") hat das Modell zehnmal
  bekommen und zehnmal übergangen; ob ein konkreter Vorschlag es ändert,
  zeigt erst der nächste Lauf.
* **Die Bäume sind ungenutzt.** In drei echten Läufen kam
  `unterhaenge_kettenglied` **null Mal** vor, ebenso `versetze_kettenglied`.
  Ob die Sitzungen flach sind oder die Werkzeuge nicht ankommen, ist offen.
* **`verschiebungen: 0`** — die Weltgeschichte steht in Erzählreihenfolge, die
  hier zufällig chronologisch ist. Ein Rückblick mitten in der Sitzung würde
  heute am falschen Platz landen.
* **Ein abgebrochener Lauf hielt seine Ollama-Verbindung offen** — am 24.09.
  hing daran ein `llama-server` mit 12,5 GB über Stunden, obwohl `ollama ps`
  leer war, und eine andere Session wartete auf die Karte. Der Ollama-Client
  hat seitdem einen **eigenen** HTTP-Pool mit Idle-Frist
  (`Worker.Agent.Modell.Pool`, eine Minute) statt Reqs geteiltem Default-Pool,
  dessen Verbindungen ohne Frist offen bleiben. **Die Kausalität ist dabei
  nicht belegt:** dass die offene Verbindung den Runner gehalten hat, ist
  plausibel und nicht gemessen — ob mit der Frist auch der Speicher fällt,
  zeigt der nächste Lauf. Diagnose weiterhin über `ss -tnp | grep 11434`; ein
  `beam.smp` als Halter bei leerem `ollama ps` ist der Fall.
* **Z3 ist eingelöst** (s. Abschnitt darüber) — mit einer Einschränkung, die
  bleibt: Ob das Modell die Prüfpflicht tatsächlich erfüllt, statt die
  Zeitlinie zu schlucken, ist **nicht gemessen**. Die Regeln stehen im
  Auftrag, die Wirkung zeigt ein Lauf. Dazu kostet der Aufbau der Linie samt
  Block-Index je Chronik-Lauf einen vollen Kampagnen-Read.
* **Z5 bleibt bewusst liegen** (Maintainer, 25.09.2026: „lass es drin"): Die
  Zeitfelder stehen weiterhin in Jacks Extraktionsschema
  (`Worker.Jack.Felder`). Mein Einwand dagegen — ohne sie könne die Chronik
  nur zustimmen oder schweigen — war falsch, und die Korrektur steht im
  Abschnitt darüber: Jack kann in den Mitschnitt sehen, und das ist die
  bessere Prüfung. Die Felder bleiben trotzdem, solange die Kette nur einen
  gemessenen Lauf hinter sich hat.


**Zeitstrahl / Datums-Auflösung (#724) — HISTORIE, mit #1211 ersetzt.** Der folgende Absatz beschreibt den deterministischen Pfad, den der Chronik-Jack abgelöst hat (s. Abschnitt darüber). Er bleibt stehen, weil Kalender, Session-Anker und die Tageszähler-Rechnung weiterleben — nur der Weg von den Fakten zur Chronik ist ein anderer. Der Timeline-Publish war verdrahtet: `run_wahrheitsbild` datiert die verifizierten Fakten deterministisch und schreibt sie als Chronik-Einträge (`Pipeline.Zeit.publiziere/3` → `Timeline.Graph.resolve` → `Render.timeline` → `ChronikEntryChanged`). Kernprinzip: das LLM liefert pro Fakt **Anker + Offset + Präzision + narration_time** (Erzählzeit vs. erzählte Zeit — Flashback/Prophezeiung), **Elixir rechnet das Datum** deterministisch auf einem Tageszähler (`Worker.Timeline.{Calendar,Resolver,Graph}`) — so landet eine erzählte Rückblende chronologisch in der Vergangenheit statt zur Aufnahmezeit. Persistenz: eigene Tabellen `@campaign_calendars` (per-Campaign-Kalender, Default Gregorian) + `@session_anchors` (In-Game-Datum-Anker pro Session), gesetzt via Events `CampaignCalendarSet` / `SessionInGameAnchorSet`; `chronik_entries` trägt `in_game_day` (primärer Sort-Schlüssel) + `precision` + seit #1092 `source_pos` (Zweitschlüssel innerhalb eines Tages, s.u.). UI: pro Session ein 📅-Datumsfeld, ein „Kalender"-Config-Tab, und ein `~`-Präzisions-Marker in der Chronik. Ehrliche Grenze (#686): `narration_time` (required) ist das verlässliche Signal; relative Offsets sind modell-abhängig (Eval-Frage). **Seit #911/#958 filtert der Timeline-Publish VOR `Graph.resolve` Vorstufen weg** (zwei damals, seit #1068 E3 drei — der Typ-Filter `Graph.datierbar?/2` kam dazu), die die Chronik sonst zum Fakten-Dump machten (Free-Seattle-Befund: 544 von 548 verifizierten Fakten wurden Chronik-Einträge): `Graph.time_signal?/1` (pure) verlangt ein EIGENES Zeit-Signal des Fakts (Anker/Offset/`in_game_date`-Bridge #676/#729) statt des reinen Präsens-Fallbacks (`narration_time == "present"` ohne jedes Signal sitzt sonst automatisch am Session-Anker-Tag), und `Repo.filter_arc_kind/2` lässt nur `kind == "arc"`-Fakten durch (gleiche Zuordnung wie Resümee/Epos seit #909, `fact_render_assignments/2`) — die Chronik ist ein Bogen-Zeitstrahl, kein Protokoll-Abzug.

**#1069 (E7) ist mit #1213 wieder entfernt — gemessen wirkungslos.** Bis dahin leitete ein deterministischer Zeit-Vorlauf (`Worker.Timeline.Vorlauf`) nach der Glättung aus den geglätteten Blöcken einen Session-Zeitrahmen ab (Tageszeit, Tagesgrenzen, Jahres-Kandidaten), legte ihn als `SessionZeitrahmenSet` ab, und `Graph.time_signal?/2` liess bei belegtem Rahmen **jeden** Fakt der Session durch den ersten Vorfilter.

**Die Wirkung auf die Chronik war null**, am 2026-08-20 an `seattle-bereinigt-1` nachgemessen (225 Fakten, 175 verifiziert, Anker 15.11.2080 gesetzt, Rahmen über Tageszeit `:abend` belegt):

```
                       ohne Rahmen   mit Rahmen
time_signal?/2                 16          175
→ datierbar?/2 (#1068 E3)      16           16
→ filter_arc_kind/2             3            3
→ Chronik-Einträge              3            3   (auf 2 In-Game-Tagen)
```

Der Typ-Filter `Graph.datierbar?/2` (#1068 E3) nahm exakt die 159 Fakten wieder heraus, die der Rahmen durchliess: Sie tragen keinen Zeitausdruck und haben damit keine Position auf einem Tageszähler. Dazu kam: Ohne gesetzten Session-Anker öffnete ein belegter Rahmen ins Leere (jeder Fakt wurde `unknown` und fiel in `Render.timeline` wieder heraus), und mit Anker landeten alle zusätzlich durchgelassenen Fakten auf **demselben** Tag.

**Entfernt sind deshalb** (#1213): das Modul `Worker.Timeline.Vorlauf` samt Test, der Aufruf in der Glättungsstufe (`publiziere_zeitrahmen/3`), `Graph.time_signal?/2` und `Graph.rahmen_belegt?/1`, der Rahmen-Zweig in `Pipeline.Zeit.publiziere/3` samt der Log-Angabe `rahmen=belegt|-`, sowie `rahmen` im Session-Anker (`Repo.Artifacts.decode_rahmen/1`). Der Vorfilter ist wieder `time_signal?/1` (#958).

**Bestand bleibt lesbar:** Ereignis-Kind `SessionZeitrahmenSet`, sein Fold (`Materializer.Apply1`, eigener Fold-Key neben dem GM-Anker) und die Spalte `rahmen_json` an `session_anchors` bleiben, damit ein Replay alter Ereignisse dieselbe Row ergibt wie zuvor; neue Ereignisse entstehen nicht mehr. Der Fold-Test (`timeline/zeitrahmen_fold_test.exs`) liest die Spalte seitdem roh, weil es keinen Reader mehr gibt.

**Offen bleibt die Frage darunter:** wie Zeitangaben aus dem Gesprochenen überhaupt in den Zeitstrahl kommen. Sie gehört zu #1140 (als eigene, geschlossene Frage) und zum Chronik-Jack (#1211).

**Ordnung innerhalb eines Tages (#1092).** Der Tageszähler ist die primäre, aber nicht die einzige Achse. Bis #1092 trugen alle Chronik-Einträge desselben In-Game-Tages den identischen Sortierschlüssel `{0, day, ""}`; weil `Enum.sort_by/2` stabil ist, entschied darunter die Leseordnung einer Mnesia-`:set`-Tabelle, die niemand festgelegt hatte. Real gemessen an „Real Free Seattle" (2026-08-19): **543 von 544 Einträgen auf einem Tag, aufsteigende Nachbarpaare 266/543 = 0,49** — statistisch nicht von einer zufälligen Reihenfolge zu unterscheiden, obwohl die Spalte wie ein Zeitstrahl aussieht. Das ist der Normalfall und kein Ausreißer: ein Spielabend spielt an einem In-Game-Tag.

Der Zweitschlüssel ist `chronik_entries.source_pos` — die Position der **frühesten** Quelle des Eintrags im geglätteten Transkript, beim Schreiben persistiert (`Render.to_entry/2` ← `Pipeline.block_positions/1`), nicht am Read aufgelöst (sonst müsste jeder Chronik-Aufruf die Blöcke aller beteiligten Sessions laden). Sortierschlüssel ist damit `{0, day, session_number, source_pos}`. Bewusst **Erzählreihenfolge, nicht erzählte Zeit**: bei einer Rückblende fallen beide auseinander, deshalb bleibt `in_game_day` primär und die Position nur Tiebreak — die Aussage lautet „an diesem Tag, in dieser Erzählreihenfolge" statt wie bisher gar keiner. Alt-Einträge, manuelle Edits und Seeds tragen `nil` und sortieren ans Ende ihres Tages (`sort_pos/1` macht das zur Entscheidung statt zur Nebenwirkung von Elixirs Term-Ordnung). Nebeneffekt: die Reihenfolge ist damit **worker-unabhängig** — vorher war nirgends garantiert, dass zwei Worker derselben Kampagne dieselbe Chronik zeigen.

**Der Kapitelkopf zeigt ein Datum (#1092).** `Render.chapter_header/3` bekommt den Kampagnen-Kalender und formatiert über `Calendar.format/3` mit der **gröbsten** Präzision der beteiligten Einträge (der Kopf spannt über alle, er darf nicht genauer aussehen als sein ungenauester Bestandteil). Vorher gab er den rohen Epochen-Tageszähler aus; in Prod stand real `## Kapitel 1 — Tag 734372–759565` — das sind der 24.12.2011 und der 1.1.2081, also 69 Jahre als zwei siebenstellige Zahlen. Ohne Kalender bleibt es beim nackten Kopf: eine falsch verstandene Zahl ist schlechter als keine Angabe. Bestandsköpfe korrigieren sich beim nächsten Regenerate, nicht rückwirkend.

**Die Ankerpräzision begrenzt die Fakten (#1092).** `session_anchors` trägt eine `precision`-Spalte, abgeleitet beim Fold aus der Schreibweise der GM-Angabe (`Resolver.infer_precision/1`, seit #1092 public). `Resolver.resolve_from_anchor/5` nimmt sie als **Untergrenze**: ein Fakt kann nie genauer sein als der Anker, an dem er hängt. Vorher wurde aus dem Anker „2081" still der 1. Januar 2081, und jeder Präsens-Fakt der Session erschien taggenau auf einem Tag, den niemand genannt hatte. **`:unknown` ist dabei ausdrücklich KEINE Grenze** — Anker aus der Zeit vor der Migration tragen keine Präzision, und weil `:unknown` den gröbsten Rang hat, würde ein naives `coarser/2` jeden Fakt auf „unbestimmt" ziehen; aus fehlender Information würde eine Aussage. Ein Re-Save des Ankers zieht die Präzision nach.

**Review-Queue für undatierte/unsichere Fakten (#724 Slice F).** `Worker.Repo.campaign_review_facts/1` zeigt verifizierte Fakten, die der Zeitstrahl nicht platzieren kann (Flashback/Zukunft/unklare Erzählzeit ohne Datum/Offset — das #686-Sicherheitsventil). Der GM kann pro Fakt in der Kampagnen-Ansicht ein Datum setzen oder ihn dauerhaft ausblenden (Event `SessionFactDateSet`). Fold ist ein reiner LWW-Upsert in einer eigenen Overlay-Tabelle (`worker_session_fact_overrides`) statt eines Patches am `session_facts`-Blob — ein Read-Modify-Write wäre order-sensitiv gewesen UND hätte der damalige Set-Semantik-Re-Publish von `Verify.verify_session` (bis J4 #1207) die GM-Korrektur zermahlen lassen. **Niemals ein `:mnesia.delete`**: auch der Undo-Fall (leeres Datum) schreibt eine reguläre Row, sonst divergiert ein vertauschtes Set→Undo-Paar zwischen Workern (#698-Klasse). Der Read-Merge (`Worker.Repo.Artifacts.merge_override/3`) pinnt jeden Override zusätzlich an die **Extraktions-Generation** (`extraction_event_id` = das `event_id` der `SessionFactsExtracted`-Row, gegen die der GM den Fakt sieht) — Fakt-IDs sind rein positional (`"f<index>"`, nicht run-eindeutig), ohne diesen Anker würde ein Override nach einem Regenerate auf einen unbeteiligten neuen Fakt an derselben Position durchschlagen. Ein gesetztes Datum forciert `time_anchor => "absolute"` (der Resolver nimmt den Absolut-Branch sonst nicht, Review-Fakten haben oft `time_anchor == "unknown"`). Ein Override-Datum, das `Calendar.parse` nicht auflöst, bleibt bewusst in der Queue (`date_parse_error`-Flag, flag-not-drop) statt den Fakt fälschlich als erledigt auszubuchen. Der Zeitstrahl-Republish nach einer Korrektur ist rein deterministisch (`Pipeline.republish_timeline_for_session/1`, kein LLM) und läuft race-frei über denselben Author-Worker-Election-Mechanismus wie der reguläre `UtterancesTranscribed`-Trigger (`elected?/2`, #365) — kein neues Hub-Command nötig. Ehrliche Grenzen: ein Regenerate vergibt neue Positions-IDs und lässt bestehende Overrides orphanen (Verhalten konsistent zum Chronik-Edit); stirbt der Author-Worker zwischen Fold und Republish, heilt der nächste Trigger/Regenerate.

### LLM-Pipeline-Backfill für nachgereichte Sessions

`Worker.Recording.Pipeline` feuert nur auf `UtterancesTranscribed`-Events während einer **echten Aufnahme**. Für seeded oder nachträglich importierte Sessions muss man die Pipeline pro Session manuell triggern — seit Issue #121 als direkter Pipeline-Call ohne Hub-Event-Roundtrip:

```elixir
:rpc.call(:"worker_prod@#{hostname}", Worker.Recording.Pipeline, :run_for_session, [SESSION_ID])
```

**Pro Session warten bis fertig bevor die nächste getriggert wird** — sonst rennen N LLM-Calls gleichzeitig durch den Ollama-Backend (mit großem Modell ~1 Inferenz auf einmal sinnvoll). Completion-Signale (von schnell nach robust):

- `Worker.Recording.Pipeline`-GenServer-State (`:sys.get_state(…).running`) listet aktive `session_id`s — gone = done. Reicht für sequentielles Trigger-Skript (oder `Pipeline.busy?/0`, #775).
- `Worker.Repo.get_session_summary(session_id)` ≠ `nil` bestätigt dass die Extraktion+Render mindestens liefen.
- Korrektes Signal für volle Pipeline-Completion: `pipeline_status`-PubSub-Events watchen, auf die letzte Stufe `render_arc_progressions` terminal (`ended`/`failed`) warten — `render_epos` taugt dafür seit J6 (#1210) nicht mehr, nach ihm kommt die Durchsicht des Epos-Jack. Scheitert das Resümee, endet der Lauf früher; dann ist `Fortschritt` (`campaign_pipeline`, `aktiv: false`) das Signal.

Nur der **Owner-Worker** (`campaign.owner_discord_id == worker.admin_discord_id`) führt die Pipeline aus — bei Multi-Worker-Setups muss der Trigger den richtigen Worker erwischen. Das `--regenerate-llm`-Flag aus Issue #58 wird genau diesen Pattern abbilden.

### Cloud-LLM-Backends (Issue #27, ab Etappe 5b direkt vom Worker)

Seit Issue #162 (Etappe 5b) calls der Worker Cloud-LLM-APIs **direkt** — Hub kennt keine Cloud-Credentials mehr. Kein Proxy, kein Vault.

Setup pro Worker-Maschine: passende Env-Var in der Worker-Start-Umgebung (`.env` neben dem Worker oder direkt vor `mix run`). Dann in `/settings` Stage-Backend (Resümee/Epos, Stufe 4/5 — Stufe 2 ist seit J4 immer lokal) auf das gewünschte Backend + ein Modell aus dessen `models/0`. Wenn die Env-Var fehlt, scheitert die Pipeline-Stage mit `:no_key_configured` (Logger-Warning, kein silent Fallback auf Ollama). **Seit #784** hat auch die Modellwahl keinen Fallback mehr: ein Backend ohne gesetztes `model_stage{n}_<backend>` (pro-Backend-Key, keine Legacy-`model_stage{n}` mehr) scheitert fail-loud mit `{:no_model_configured, stage}` — statt still einen lokalen Ollama-Namen an die Cloud-API zu schicken. Der Local-Endpoint (`local_endpoint`) sowie `whisper_bin` / `ffmpeg_bin` haben ebenfalls keinen Default mehr; frische Worker setzen sie in `/settings` (Bestandsworker mit persistierten Legacy-Werten sehen beim Boot ein `Worker: stale Legacy-Setting …`-Warning und müssen ihre Modelle einmal pro Backend nachziehen). Zusätzliche Range-Sanity: `*_ms`-Keys werden im Settings-Save gegen ein 24-h-Ceiling geclamped (verhindert Tippfehler-Blockaden wie das reale `http_timeout_ms=1_200_000_000`, ~13 Tage, auf worker_prod).

Unterstützte Backends:
- **Anthropic** (`ANTHROPIC_API_KEY=sk-ant-...`) — `Worker.LLM.Anthropic.complete/2` ruft `https://api.anthropic.com/v1/messages` mit `x-api-key: $ANTHROPIC_API_KEY`. Modelle: `Worker.LLM.Anthropic.models/0`.
- **OpenAI** (`OPENAI_API_KEY=sk-proj-...`) — `Worker.LLM.OpenAI.complete/2` ruft `https://api.openai.com/v1/chat/completions` mit `Authorization: Bearer $OPENAI_API_KEY`. Modelle: `Worker.LLM.OpenAI.models/0`.
- **Google Gemini** (`GEMINI_API_KEY=...`) — `Worker.LLM.Google.complete/2` ruft `https://generativelanguage.googleapis.com/v1beta/models/<MODEL>:generateContent?key=$GEMINI_API_KEY` (Auth via Query-Param, nicht Header). Modelle: `Worker.LLM.Google.models/0` (gemini-2.5-pro / -flash / 2.0-flash / -flash-lite). Body-Shape unterscheidet sich (`contents/parts` statt `messages`).

**Gemeinsamer Code** (Issue #463): Retry-Loop, HTTP-Error-Mapping, `LLMCallBilled`-Spend-Event und Stage-→-Modell-Lookup leben in `Worker.LLM.CloudHelper`. Backend-spezifisch bleibt nur die Request-Shape, das Response-Parsing und die Auth-Mechanik. Neue Cloud-Backends spiegeln das Anthropic-Modul (~50 Zeilen) und reusen den Helper. **`stage_label`-Bedeutungsverschiebung (#783 Phase 2):** historische `LLMCallBilled`-Events mit `"stage" => "stage3"`/`"stage4"` (Chain-Ära, vor #786) bedeuteten Epos/Chronik — seit diesem Umbau bedeuten dieselben String-Labels Verify/Render. Für die Admin-Anzeige (rendert `r["stage"]` roh) irrelevant, für zeitraumübergreifende Spend-Auswertungen zeitstempel-bewusst lesen. Seit J4 (#1207) entsteht `"stage3"` gar nicht mehr (Stufe 3 entfallen, `Worker.LLM.stage_label/1`).

HTTP-Error-Mapping einheitlich für alle drei Backends: 401/403 → `:upstream_auth`, 429 → `:upstream_rate_limit`, 5xx → `{:upstream_error, status, msg}`, Netz/Timeout → `{:network_error, reason}`. Retry: 2× exponentielles Backoff (500ms / 1s) bei 429/5xx/Network, sofort hart bei :upstream_auth + 4xx ≠ 429 (Client-Fehler).

Folge-Issues (separate Tickets): `LLMCallBilled`-Event für Spend-Tracking (#177), Streaming (#176), Per-User-Spend-Caps (#178).

### Campaign-Pipeline-Trigger (Issue #104)

In der Campaign-LV gibt es zwei Buttons (sichtbar je nach Rolle):

- **`🔄 neu generieren`** pro Session (in der Resümee-Spalte): Owner, Spielleiter-mit-Membership oder Admin. Triggert direkt `Worker.Recording.Pipeline.run_for_session/1` im Owner-Worker via `Hub.Commands.request_session_regenerate/3` (Channel-Push, kein Event-Roundtrip — siehe Issue #121).
- **`🔄 Pipeline für alle Sessions neu starten`** im Campaign-Header: Spielleiter-mit-Membership oder Admin. Triggert `Worker.Recording.CampaignReplay` im Owner-Worker, der sequentiell alle Sessions durchschickt + via `pipeline_status` (kind: `"campaign_replay"`) live den Fortschritt liefert — seit #1122 als **zweite Zeile des Laufbands** (s.u.) statt als eigener Banner.
- **„noch N Iterationen“** pro Session (Resümee-Spalte, Bearbeitenmodus, Recht `:regenerate_session`, seit J4 #1207): Jack setzt auf seinem abgelegten Stand auf und fährt nur Verifikationen, ohne neue Glättung — s. „Stufe 2 ist Jack“.

**Ein Replay belegt die Maschine — das ist keine Einstellung, sondern eine Eigenschaft des Aufbaus.** Am 2026-08-21 gemessen: mit einem 16,5-GB-Modell auf einer 24-GB-Karte liegt die Belegung über den ganzen Lauf bei 91–92 %, dem Desktop bleiben dauerhaft unter 2,3 GB. Kommt in dieser Lage ein GPU-Ereignis dazwischen (#1065), verlieren die Grafik-Clients ihre GL-Kontexte und sterben — an jenem Abend traf es Chromium beim GPU-Reset und Firefox beim Modell-Reload, beide ohne Zutun des Nutzers. Am Rechner arbeiten und gleichzeitig einen Replay fahren geht damit nicht; wer es doch tut, verliert im Zweifel den Browser, nicht den Lauf. Der Lauf selbst übersteht es (ollama rechnet auf Compute-Queues und wird von ollama neu gestartet).

Lock im Worker — nur ein Campaign-Replay pro Worker gleichzeitig. Bei laufendem Replay sind die Knöpfe disabled. Stage-Failures werden geloggt (`Pipeline: failed for session=…`) aber der Replay macht trotzdem mit der nächsten Session weiter — sonst würde eine misslungene Stage 2 das ganze Backfill blockieren.

**Der Wächter misst Stille, nicht Gesamtdauer (Issue #1062).** Der Replay hat einen Avalanche-Schutz: bricht er ab, statt die nächste Session zu triggern, stapelt sich `Pipeline.running` nicht auf und Ollama läuft nicht in eine Queue-Lawine. Bis #1062 war das Kriterium „Session seit 30 min nicht fertig" — und damit **strukturell unterschritten**: eine echte Session braucht mit qwen3.8:27b 80–110 Minuten (gemessen 81 am 2026-08-17), der Replay schaffte also **immer** nur die erste Session. Für den Nutzer sah das wie Erfolg aus: Session 1 hatte frische Artefakte, die Oberfläche meldete keinen Fehler, `CampaignReplay.running` war danach `nil` wie nach einem sauberen Lauf, und dass die übrigen Sessions unangetastet blieben, merkte man erst beim Vergleich der Zeitstempel.

Jetzt setzt **jede `pipeline_status`-Meldung dieser Kampagne die Frist zurück** (`replay_stage_timeout_ms`, Default 3 h). Ein Lauf, der Fortschritt zeigt, läuft beliebig lange; abgebrochen wird nur, was wirklich hängt — genau die Frage, um die es dem Avalanche-Schutz ging. Drei Details, die daran hängen:

- **Gewartet wird gegen eine Frist, nicht gegen eine Dauer.** Naheliegend wäre, bei jeder Nachricht rekursiv mit der vollen Frist erneut einzutreten; dann setzt aber JEDE Nachricht die Uhr zurück — auch eine fremde Kampagne oder der eigene Replay-Banner, der über denselben Topic läuft. Der Schutz wäre still ausgehebelt (der Lauf bräche irgendwann trotzdem ab, nur viel später). Nur echter Fortschritt erneuert die Frist, alles andere wartet die Restzeit ab.
- **Gefiltert wird nach Kampagne, nicht nach Session.** Der `pipeline_stage`-Payload trägt `campaign_id` und `stage`, aber **keine** `session_id` (s. `Pipeline.notify_status/4`). Der Replay fährt sequentiell, eine Stufenmeldung dieser Kampagne gehört also zur laufenden Session. Ein paralleler Einzel-Regenerate derselben Kampagne verlängerte die Frist — echter Fortschritt am selben Modell, aber eine benannte Ungenauigkeit.
- **3 h, weil auch die Stille-Uhr über der längsten *einzelnen* Stufe liegen muss.** Der reale Auslöser war Stage 1.1 mit 244 Lückenblöcken à ~30 s, also rund 2 h ohne Stufenwechsel.

Der Abbruch ist außerdem **sichtbar**: eigene `/admin/errors`-Klasse `replay_stalled` (Stage `campaign_replay`) mit zuletzt gesehener Stufe, Position im Lauf und der Frist. Die frühere Meldung nannte pauschal „vermutlich Stage 3", während der Zeitverbrauch real aus Stage 1.1 kam; jetzt wird die Stufe mitgeführt statt geraten.

### Laufband: was die Pipeline gerade tut (Issue #1122)

Wer die Kampagne öffnete, konnte nicht erkennen, ob gerade gerechnet wird und
wie weit es ist — eine leere Resümee-Spalte sah aus wie eine, die in vier
Minuten gefüllt wird. Sichtbar war nur ein Spinner je Spalte und auf dem
Dashboard zwei Punkte; beides sagt „irgendetwas läuft", nicht „wo".

**Die Stufenfolge ist jetzt Daten** (`Shared.PipelineStufen`): Name, Titel,
Spalte, pflicht/best-effort und die zählbare Einheit, in Laufreihenfolge. Sie
liegt in `shared`, weil Hub und Worker dieselben Namen brauchen — zwei Listen
an zwei Orten laufen auseinander, ohne dass etwas rot wird (#1090-Klasse). Ein
Hub-Wächter hält sie gegen die echten Spaltennamen.

**Die Spalten stehen seit #1122 in Pipeline-Reihenfolge.** Geglättet und Fakten
haben die Plätze getauscht; von rechts nach links ist es jetzt Protokoll →
Geglättet → Fakten → Resümee → Epos/Chronik, dieselbe Richtung, in der die
Daten wandern. Vorher wäre der Fortschrittspunkt zwischen den beiden einmal
rückwärts gesprungen. Reine DOM-Umstellung: `@col_names` ist nur eine Whitelist
fürs Ein-/Ausklappen, und `PersistCols` merkt sich Namen statt Positionen.

**Der Lauf hat ein Gedächtnis** (`Worker.Recording.Pipeline.Fortschritt`,
eigener Prozess). Vorher waren die Stufen reine Ereignisse: `notify_status`
broadcastete und vergaß sofort; eine abgeschlossene Stufe hinterließ nichts,
und wer mitten im Lauf die Seite öffnete, sah bis zur nächsten Meldung gar
nichts. Der Prozess ist eigenständig, weil `pipeline.ex` dicht an der
600-Zeilen-Grenze steht, weil dort `run_for_session` als `handle_call` läuft
(hunderte Fortschritts-Casts hätten sich davorgelegt) — und weil er die
**Koordinator-Rolle** trägt, die verteilte Batches später brauchen.

**Erledigte Einheiten sind eine MENGE, kein Zähler.** Ein Zähler ist nicht
zusammenführbar: meldet Worker A „3 fertig" und Worker B „4 fertig", ist weder
3 noch 4 noch 7 ableitbar (#766-Konvergenz). Nach außen geht die Kardinalität,
damit die Nachricht klein bleibt. **„4 von 7" heißt „vier sind fertig", nicht
„bei Nummer vier"** — verteilt kann Chunk 5 vor Chunk 2 fertig werden. Zählbar
sind seit J4 (#1207) fünf Stufen: Gap-Fill (Lückenblöcke, zählt auf `smooth`),
Jacks Gedächtnis, Extraktion und Verifikation (je die Blöcke ihres eigenen
Lesegangs; die Verifikation zählt je Durchgang neu, das Band zeigt „Durchgang N“)
und Bogen-Progressionen (Bögen). Bis J4 waren es vier — Extraktion in Chunks,
„Prüfung“ (Stufe 3) in Fakten. Seit J5 (#1209) zählen dazu Überblick (gelesene
Fakten) und Durchsicht des Resümee-Jack (entschiedene Absätze, je Durchgang),
seit J6 (#1210) ebenso Überblick und Durchsicht des Epos-Jack. Das Schreiben
beider zeigt keine Zahl, weil die Absatzzahl vorher nicht feststeht; die Chronik
ist ein einzelner Aufruf und zeigt **keine** Zahl — `1/1` wäre eine Attrappe. Ebenso fehlt die Zahl, solange die Gesamtzahl unbekannt ist: „3/?"
ist keine Auskunft.

**Der Stufen-Abschluss ist autoritativ** und füllt auf; sonst bliebe die
Anzeige bei `6/7` stehen, wenn die letzte gedrosselte Meldung wegfällt
(Broadcasts sind auf 1 s gedrosselt, Stufenwechsel nie). Ein **Fehlschlag**
füllt bewusst nicht auf — er hat nicht alles geschafft. Das **Lauf-Ende** wird
abgeleitet (letzte Stufe abgeschlossen, oder eine Pflichtstufe gescheitert)
statt gemeldet: eine Ableitung kann nicht vergessen werden, wenn jemand später
einen weiteren Ausgang aus dem Lauf einbaut.

Gelesen wird der Stand über den member-gated Scope **`campaign_pipeline`** (in
`Worker.Repo.PipelineStand`, nicht in `snapshots.ex`: er liest einen Prozess
statt Mnesia, und die Datei steht auf ihrem Ratschen-Wert). Live kommen
Teilmeldungen als `kind: "pipeline_fortschritt"`; kennt die LiveView den Lauf
noch nicht, holt sie ihn EINMAL nach, statt bei jeder Meldung einen Snapshot zu
ziehen.

**Ehrliche Grenzen.** Der Zustand ist **RAM-only** — ein Worker-Neustart
verliert ihn, und ein Lauf, dessen Prozess stirbt, bliebe als „läuft" stehen.
Deshalb führt der Stand `still_seit_ms` mit und das Band schreibt ab 10 Minuten
ohne Regung „ohne Regung seit …", statt Fortschritt zu behaupten; genau diese
Verwechslung ließ am 2026-08-20 eine Replay-Anzeige einen längst toten Lauf als
aktiv zeigen. Die Stufen-Broadcasts tragen `session_id` und `run_id`
(`with_status/5` bekam die Session-ID vorher schon und warf sie weg), aber die
**Teilmeldungen** schlüsseln nur auf die `session_id` — der Koordinator kennt
die `run_id` bereits, was das Durchreichen durch vier Modulgrenzen erspart, bei
verteilten Arbeitern aber nachgezogen werden muss.

**Fund im Bestand (#1122):** `start_async/3` bricht einen laufenden Task mit
gleichem Namen ab. Alle Scope-Loads hießen `:reload_scope` — zwei kurz
hintereinander (Mount lädt Flags, dann Pipeline-Stand) schossen sich gegenseitig
ab, und der Verlierer setzte seine Assigns nie. Aufgefallen ist es erst, als
überhaupt zwei Loads zusammentrafen. Der Async-Name trägt jetzt den Scope.
Ebenfalls behoben: die Dashboard-Whitelist im Status-Stream kannte `smooth`
nicht — die längste Stufe ließ die Karte nie leuchten. Sie ist ersatzlos weg;
gefiltert wird beim **Lesen** gegen `Shared.PipelineStufen`, damit es nur eine
Stelle gibt, an der man eine Stufe vergessen kann.

**Jacks Stufen (J4, #1207).** Die Stufenfolge ist seitdem Glättung → Gedächtnis
→ Extraktion → Verifikation → Resümee → Chronik → Epos → Bögen; „Prüfung“
entfällt. Jack meldet seine Stufen selbst über den Rückruf `:melde_stufe`
(`Worker.Jack.Pipeline`), den `run_wahrheitsbild` aus den beiden Hälften von
`with_status/5` baut (`Pipeline.stufen_melder/3`); ohne ihn meldet Jack nichts
(Neuableitung, Messläufe, Tests). Die Extraktion behält den Namen `"extract"`,
weil `/admin/errors` und die Fehlerklassen daran hängen; ein Fehler vor den
Phasen und ein leerer Bestand erscheinen dort. Die Verifikation ist
**best-effort**: eine abgebrochene behält ihren Bestand, Resümee, Chronik und
Epos laufen weiter — als Pflichtstufe hielte `Fortschritt` den Lauf bei ihrem
Fehlschlag für beendet, und das Band verschwände, während die Pipeline
weiterrechnet. „noch N Iterationen“ meldet nur die Verifikation. `Fortschritt`
ignoriert Nachzügler aus überholten Durchgängen, und der Fehler-Flash nennt den
Stufentitel („Verifikation“) statt des internen Namens; Stufen, die es in
`Shared.PipelineStufen` nicht mehr gibt (etwa `verify` eines alten Workers),
behalten ihren Rohnamen.

### Statusendpunkt im Worker: HTTP über einen Unix-Domain-Socket (Issue #1218)

Am Monitor des Maintainers hängt eine Hardware-Anzeige (RGB-Band), die zeigen soll, was der Loretracker gerade tut. Bis #1218 gab es dafür genau einen Wert: `GET /health/recording` am Hub, ja oder nein zur Aufnahme (#703). Alles Weitere — Laufband, Sprecher — liegt im Worker und war nur per Erlang-RPC erreichbar. **Entscheidung des Maintainers (17.09.2026): „ich will kein RPC im Loretracker — eine ordentliche API", und als Weg dorthin ein Unix-Domain-Socket statt eines Ports.**

`GET /status` liefert JSON:

```json
{"aufnahme": true,
 "lauf": {"zustand": "laeuft", "stufe": "extract", "erledigt": 4, "gesamt": 7, "still_seit_ms": 0},
 "gruppen": [{"spalte": "fakten", "zustand": "laeuft"}, …],
 "teilnehmer": []}
```

- **Kein offener Port**, auch nicht auf 127.0.0.1: `Plug.Cowboy` bindet auf `ip: {:local, pfad}`. Zugriffskontrolle sind die Dateirechte (0600). Der Pfad kommt aus `LORE_STATUS_SOCKET`, sonst aus `XDG_RUNTIME_DIR` (`…/lore-tracker/status.sock`); ohne beides und bei `LORE_STATUS_SOCKET=aus` gibt es **kein Kind im Baum** (`Worker.Status.Endpunkt.kind/0` liefert `[]`).
- **Eine Socket-Datei überlebt ihren Prozess.** Nach einem harten Abbruch liegt sie noch da und `bind` scheitert. Der Start räumt eine solche Leiche weg — aber nur, wenn es wirklich eine Socket-Datei ist: Bei einer gewöhnlichen Datei bricht er ab, statt sie zu löschen (jemand hat dann den Pfad verwechselt).
- **Der Endpunkt fragt keinen GenServer, der blockieren kann.** Er liest `Fortschritt.alle/0` (eigener Prozess, antwortet sofort) und `Repo.any_active_recording?/0` (Mnesia) — dieselbe Zurückhaltung wie `BotGate.status/0`, das aus `worker_state` liest statt den Bot-Prozess zu rufen (#475). Eine Anzeige pollt im Sekundentakt; ein Leser, der hinter einem laufenden HTTP-Aufruf hängt, wird zum Blockierer.
- **`Worker.Status.Lage` ist pur** und trägt die ganze Ableitung: Gruppen aus `Shared.PipelineStufen` (Stufen ohne Spalte bilden `"boegen"`), Vorrang der Zustände (gescheiterte **Pflichtstufe** > läuft > gescheiterte **Zugabe** > fertig > offen), und die zwei Regeln aus #1122 — **Zahlen nur, wo es zählbare Einheiten und eine bekannte Gesamtzahl gibt** (kein erfundenes `1/1`, kein „3 von ?"), und **„läuft" ist nicht „regt sich"**: ab `Shared.PipelineStufen.still_ms/0` (10 min) heißt der Zustand `"still"`. Die Grenze wohnt seit #1218 in `shared`, weil Laufband und Endpunkt dieselbe brauchen; zwei Konstanten wären auseinandergelaufen, ohne dass etwas rot wird.
- **`teilnehmer` seit Schnitt 2:** je Person im Discord-Sprachkanal `id` (gesalzener Hash, acht Zeichen), `spricht` und `zustimmung`. **Die Discord-Kennung verlässt den Worker nie**; das Salz entsteht beim Start neu und lebt nur im Arbeitsspeicher — innerhalb eines Laufs stabil (die Anzeige soll eine Person an derselben Stelle zeigen), über einen Neustart hinweg nicht wiedererkennbar. Quelle ist `Worker.Status.Praesenz`, ein ETS-Zwischenspeicher, in den die Sprachsitzung im Präsenz-Takt schreibt (#988) — **gefragt wird der Sitzungsprozess nie**, er kann während einer Ansage blockieren. Ein Stand verfällt nach `Praesenz.frist_ms/0` (15 s): Stirbt die Sitzung, leert sich die Liste von selbst, statt Leute zu zeigen, die längst gegangen sind. Leere Liste heißt „keine Sprecherdaten" und ist etwas anderes als „niemand spricht" (Browser-Mikro liefert keine).
- **Ehrliche Grenze:** Der Endpunkt ist **lokal**. Wer den Status aus der Ferne will, braucht eine eigene Entscheidung, denn Anwesenheit und Sprechaktivität nach außen zu geben ist etwas anderes als eine Leuchte am eigenen Monitor.

### Wartezeiten sind Settings, nicht Modul-Attribute (Issue #1062)

Aus dem obigen Einzelfall wurde eine Regel: **jede Frist und jeder Takt des Workers ist in `/settings` einstellbar** (Block „Wartezeiten" am Seitenende, nach Bereichen gruppiert). Alle Defaults sind die bisher fest verdrahteten Werte — wer nichts ändert, ändert nichts; die **einzige** Ausnahme ist `replay_stage_timeout_ms` (30 min → 3 h, s.o.). Ein Wert im Modul-Attribut ist erst nach einem Deploy änderbar, und wer ihn braucht, sitzt gerade am Spieltisch.

Betroffen sind rund 30 Keys über Replay (bis J4 #1207 auch den Probelauf, dessen `probelauf_stage_timeout_ms` mit ihm entfallen ist), Hub-Publish, Cloud-LLM-HTTP, Sidecars, Materializer, Rohaudio-Recovery, Discord-Bot und Worker-Lebenszyklus. Alle enden auf `_ms` — daran hängt das 24-h-Clamping in `HubClient.Rpc.clamp_ms/2`, das Tippfehler wie das reale `http_timeout_ms=1_200_000_000` (~13 Tage) abfängt.

**Bewusst NICHT aufgenommen**, damit die Liste eine Bedeutung behält: **Protokoll-Konstanten** (`@frame_duration_ms 20` = Opus-Rahmenlänge in `FrameBuffer`/`AudioBridge` — ein anderer Wert zerlegt den Ton, statt ihn zu tunen), **hergeleitete Schwellen im Paketpfad** (`@min_gap_ms 100` trennt Jitter von echter Pause, aus einer gemessenen bimodalen Verteilung #1005; dazu läge der `Settings.get/2` dort im 50-Pakete-pro-Sekunde-Pfad, und jeder Lookup ist eine Mnesia-Transaktion) und **hub-seitige Werte** (der Hub ist seit #164 zustandslos und hat keinen Settings-Speicher).

Zwei Module bleiben dabei ausdrücklich **pur**: `Worker.Discord.Presence` und `Worker.Recording.AudioBuffer.Presence` lesen die Settings nur in ihren Accessoren bzw. Default-Argumenten — die Rechnung selbst bekommt den Wert als Parameter und ist ohne Mnesia testbar.

Die UI-Felder kommen aus **einer** Liste (`HubWeb.EinstellungenLive.Wartezeiten.@gruppen`), die zugleich die Integer-Normalisierung speist. Der bestehende Drift-Wächter `Worker.SettingsUiDriftTest` (#755) wurde dafür erweitert: er löst `settings[#{key}]` gegen diese Liste auf — ohne das wäre der datengetriebene Block für ihn unlesbar gewesen und hätte die Whitelist-Prüfung stillschweigend umgangen (ein Key außerhalb der Whitelist erzeugt ein **totes Eingabefeld** ohne jede Fehlermeldung).

### ~~LLM-Probelauf~~ (Issue #74) — mit J4 (#1207) entfernt

`/admin/probelauf` (nur `:admin`) und `Worker.Probelauf` seedeten eine eigene `probelauf-<uuid>`-Kampagne, schickten sie durch die Pipeline und maßen pro Schritt (`extract`/`verify`/`render`/`timeline`/`render_epos`) Dauer, Ausgang und den **Verify-Trichter** (`n_facts → n_grounded → n_verified`), dazu ein Extraktor-Modell-Sweep mit Heuristik-Empfehlung. Das Messobjekt gibt es seit J4 nicht mehr: die alte Extraktion und Stufe 3 sind weg, und ein Trichter aus Jacks Fakten wäre konstant (jede Aussage trägt ihre Belegprüfung). Entfernt sind Worker-Prozess, Channel-Handler, Admin-Seite samt Sweep-Formular und Heuristik, die Hub-Befehle, der Snapshot-Scope, der Idle-Grund im Updater und `probelauf_stage_timeout_ms`; `Hub.PipelineStatus` braucht keinen Sammel-Topic mehr (kampagnenlose Meldungen kamen nur vom Probelauf und werden verworfen). **Als Altbestand bleiben** die vier Probelauf-Event-Kinds, ihre Folds und Tabellen (nur noch beim Replay geschrieben, nie gelesen), der Seed-Mitschnitt für `mix lore.seed.coc_demo` (`apps/worker/priv/probelauf-eval/`) und die Filter für alte `probelauf-*`-Kampagnen in `campaigns_for`/`all_campaigns`.

### Der Worker sagt jetzt, wenn etwas schiefgeht (Issue #542)

Der Hub hat seit #238 strukturierte Telemetrie (`Hub.Telemetry`) — der
**Worker hatte keine einzige Stelle**, obwohl fünf der sechs in #542
benannten Signale Worker-Signale sind. Deshalb blieb unbemerkt, was OTP
ohnehin schon schreibt: der Self-Update-Zombie (#512) lief einmal 1h15m
unbeachtet, und der Watchdog-Vollzug bei jedem Update (#1048) fiel nur
auf, weil zufällig jemand in `coredumpctl` sah.

**`Worker.Telemetry`** sammelt Vorfälle über ein Fenster
(`telemetry_report_ms`, 60 s) und meldet sie als **eine** Zeile im
bestehenden `[telemetry] event=… key=value`-Format. Gezählt werden
`task_crash` (ab 1 laut), `unbekannter_event_kind` (ab 1), `pipeline_fehler`
(ab 5) und der `publish_stau` aus `worker_state` (laut, sobald er wächst).

**Drei Entscheidungen, die den Wert ausmachen:**

- **Der Zählruf loggt nichts.** Jeder Vorfall wird an seiner Entstehung
  bereits geschrieben (OTP-Bericht, `Logger.warning` im Materializer,
  Eintrag in `/admin/errors`). Eine zweite Zeile je Vorfall wäre
  Wiederholung — und bei einer Fehlerserie (ein Gap-Fill-Lauf hat hunderte
  Blöcke) würde sie genau das Log fluten, in dem der Vorfall gefunden
  werden soll. Der Mehrwert ist die **Häufung und die Schwelle**.
- **Ohne Vorfall bleibt es still.** Ein Takt-Report „alles null" wäre das
  Rauschen, durch das ein echtes Signal übersehen wird — dieselbe Lehre wie
  bei der Speicher-Schwelle (#1098).
- **Nur der ernste Catch-all-Zweig zählt.** Ein Ereignis-Typ, der nicht in
  `Shared.Events` steht, ist Wire-Drift und wird gezählt. Der Fall darüber
  („in `Shared.Events`, aber noch kein Fold") tritt im Mischbetrieb
  zwischen zwei Worker-Versionen regulär auf und ist genau deshalb leise
  gestellt; ihn mitzuzählen hiesse, nach jedem Rollout mit einem neuen
  Ereignis-Typ zu warnen und die Warnung damit wertlos zu machen.

**Task-Abstürze kommen über den Logger, nicht über Telemetrie**
(`Worker.Telemetry.Absturz`): `Task.Supervisor` sendet kein
Telemetrie-Ereignis, es gibt also nichts zum Anhängen. Gezählt wird der
Absturzbericht, den OTP ohnehin schreibt. Der Handler **fängt alles ab** —
wirft ein `:logger`-Handler, entfernt der Logger ihn dauerhaft und still,
die Zählung wäre dann aus, ohne dass es jemandem auffällt. In der
Testumgebung hängt er sich nicht ein (dort stürzen Prozesse absichtlich ab).

**Ein Befund aus dem Test, nicht aus dem Entwurf:** der erste Takt nach dem
Start hat keinen Vergleichspunkt für den Rückstand. „Vorher unbekannt" ist
nicht „vorher null" — ohne diese Unterscheidung meldete **jeder**
Worker-Neustart einen Anstieg von 0 auf den bestehenden Rückstand, also
einen Fehlalarm genau im unruhigsten Moment.

**Wie der vorherige Lauf geendet hat, erzählt der Nachfolger.** Ein Worker,
der stirbt, meldet nichts mehr — deshalb schreibt `halt_node/1` den
Zeitpunkt seines Anlaufs nach `worker_state`, **solange Mnesia noch
schreibbar ist**, und `Worker.Telemetry.melde_vorherigen_abgang/0` wertet
ihn beim nächsten Start aus (in `Worker.Application.start/2`, nach dem
Mnesia-Bootstrap und vor den Children). Drei Fälle: kein vorheriger Lauf
(still), **Abgang ohne Ankündigung** (`halt_node/1` nie erreicht — Absturz,
OOM, hart abgeschossen; laut), und **angekündigter Abgang**, dessen Dauer
bis zum Neustart über der Backstop-Frist plus Puffer liegt — dann kam der
Halt nicht durch **und der Backstop hat nicht gegriffen** (laut). Das ist
Signal 4, und es erfasst mehr als geplant: jeden unsauberen Abgang, nicht
nur den beim Self-Update.

Der Weg dorthin war ein Fund am Journal vom 17.09.: zwischen dem
angekündigten Halt und dem Watchdog-Zugriff steht **keine einzige**
`halt_with_marker`-Zeile — obwohl der #776-Nachtrag genau dafür je eine
Markierung unmittelbar vor jedem `hard_halt` gesetzt hat. Nicht nur der
Halt hängt also, sondern auch der 15-Sekunden-Backstop, der ihn abfangen
soll, kommt nicht dazu. Warum, ist offen (in #1048 vermerkt).

**Ehrliche Grenzen.** Die Zähler leben im Arbeitsspeicher; ein Neustart
setzt sie zurück (der Rückstand nicht, der liegt seit #475 in
`worker_state`). Der Abgangs-Vergleich läuft über die **Wanduhr** — die
einzige, die einen Neustart überdauert; eine verstellte Uhr verfälscht die
Zahl, für „hing der Halt eine Minute" reicht das. Und gezählt wird, was OTP
als Bericht formuliert: ein Prozess, der ohne Crash-Report endet, erscheint
nicht.

Auf der Hub-Seite ist eine Asymmetrie geschlossen: der **Wrong-Worker-Drop**
(#772) feuert jetzt ebenfalls `[:hub, :audio, :chunk_dropped]` (Grund
`:wrong_worker`, ohne `bytes` — der NACK trägt die Chunk-Grösse nicht). Er
war bis dahin nur für den betroffenen Sender sichtbar (NACK → Streak →
Flash) und fehlte in jeder nachträglichen Auswertung.

### Ein Wächter, der nie anschlägt, ist unbewiesen (#1163, #1053, #542)

Dieses Projekt baut viele Warnschwellen, und **drei davon konnten den Fall,
für den sie gebaut wurden, per Konstruktion nicht erfassen**. Alle drei sahen
im Betrieb beruhigend aus: keine Meldung, also alles in Ordnung.

| Wächter | Gedacht für | Warum er blind war |
|---|---|---|
| **#1163** Speicherwarnung ab 85 % | OOM-Kill vorhersehen | 2.180 Zeilen, 0 Warnungen, 18 Kills — der Sprung auf 100 % war schneller als das 30-Sekunden-Messintervall |
| **#1053** Flush-Warnung ab 5 s | prüfen, ob die 60-s-Frist reicht | bei 5 s hat der Supervisor den Prozess längst gekillt (OTP-Default `shutdown: 5000`) |
| **#542** Absturz-Zähler | Task-Abstürze zählen | erkannte `{:proc_lib, :crash}`; OTP schickt `{Task.Supervisor, :terminating}` |

Das Muster ist immer dasselbe: **die Schwelle liegt jenseits der Grenze, an
der das Beobachtete aufhört zu existieren.** Bei #1163 ist der Prozess beim
Erreichen der Schwelle bereits tot, bei #1053 ebenso, bei #542 kam das
Ereignis in einer Form an, die der Wächter nicht kannte.

**Beim Bau eines Wächters gehören deshalb zwei Fragen dazu, bevor er zählt:**

1. **Kann der zu meldende Fall die Schwelle überhaupt erreichen?** Wenn der
   Vorgang bei genau dem Wert abbricht, ab dem gewarnt wird, ist die Warnung
   Dekoration. Faustregel: Die Warnschwelle gehört deutlich **unter** die
   Abbruchgrenze, damit ein langsamer Vorgang auffällt, *bevor* er
   abgeschnitten wird.
2. **Hat er einmal nachweislich angeschlagen?** Ein Wächter, der nie
   ausgelöst hat, ist kein Beleg für Ruhe — er ist unbewiesen. Am billigsten
   ist der Nachweis bei der Inbetriebnahme: den Fall einmal künstlich
   herbeiführen und zusehen, ob die Zeile erscheint. In #542 hat genau das
   den Defekt gefunden — ein per RPC provozierter Task-Absturz auf der
   Teststage, nachdem die Tests grün waren.

**Warum die Tests das nicht fangen:** Bei #542 prüfte der Test dieselbe
angenommene Berichtsform, die auch der Code erwartete. Beides stammte aus
derselben Vermutung, also konnte kein Test sie widerlegen — die #1149-Lehre
(„ein Test-Doppel bildet Verhalten nach, nie eine vermutete innere Form"),
hier auf einen Wächter angewandt. Wo ein Wächter auf **fremde** Formen
reagiert (OTP-Berichte, Kernel-Zeilen, Fremd-API-Felder), ist die einzige
verlässliche Quelle das laufende System, nicht die Annahme darüber.


### LiveView-Gotchas (gesammelt beim Bau von /admin/probelauf)

- **`fetch_live_flash` muss im `:browser`-Pipeline sein**, sonst crasht jeder LiveView der `put_flash(socket, ...)` im mount/load_data ruft mit `ArgumentError "flash not fetched"`. Andere LiveViews funktionieren oft „zufällig" weil sie put_flash nur im Fehlerpfad nutzen — neuer LiveView ohne den Plug fällt auf die Nase sobald der reload-Pfad einen Flash schreibt.
- **HEEx `@assigns` ≠ Modul-Attribute**: `@stages` im Template referenziert immer `socket.assigns.stages` — Modul-`@stages` muss explizit als `assign(:stages, @stages)` in mount durchgereicht werden. Sonst `KeyError :stages` bei render.
- **`Worker.Repo.serialize/1` braucht `nil`-Klausel** wenn Snapshot-Felder optional sind (z.B. `running == nil` wenn nichts läuft). Sonst FunctionClauseError beim Snapshot.
- **Modal-Pattern: `<.lt_modal on_close="...">` benutzen, NIEMALS `onclick="event.stopPropagation()"` (Issue #352)**: Phoenix-LiveView registriert seine Click-Listener delegated auf document-Level. Wenn man im Modal-Body ein `onclick="event.stopPropagation()"` setzt um Backdrop-Klick-Schließen-Bubbling zu unterdrücken, killt das **alle** `phx-click`/`phx-change`/`phx-submit`-Events innerhalb des Containers — Buttons im Modal scheinen tot, kein Crash, kein Log. Der korrekte Pattern ist die `HubWeb.UIComponents.lt_modal/1`-Komponente: backdrop = `phx-click`, content = `phx-click-away`, KEIN JS-stopPropagation. Iron-Law-Regel #6 scant nach dem Anti-Pattern.

### Modell-Inkompatibilitäten + Pipeline-Robustheit (Issue #75/#786; für Stufe 2 seit J4 #1207 abgelöst)

**Seit J4 gilt der größte Teil dieses Abschnitts nicht mehr für Stufe 2.** Jack spricht Ollama über `/v1/chat/completions` mit Werkzeugaufrufen (`Worker.Agent.Modell.Ollama`) — dort gibt es keinen JSON-Schema-Modus, keine Chunks, keinen `num_predict`-Deckel und keine Rettung abgeschnittener Ausgaben mehr; `facts_json_schema/0`, `extract_num_predict_cap`, `extract_chunk_tokens`, `ctx_stage2` und `Parsing.salvage_truncated_facts/1` sind entfernt. Die Klassen `all_chunks_failed` und `truncated_salvaged` bleiben für Alteinträge lesbar; `extraction_empty` entsteht weiter, wenn Jacks Bestand keine gültige Aussage enthält. An ihre Stelle trat: Jack fasst seinen Verlauf ab `ctx_jack` − Reserve selbst zusammen; ein `ctx_jack` unter dem Mindestfenster bricht vor dem Lauf ab (`ctx_jack_ungueltig`); endet eine Antwort ohne Werkzeugaufruf, hakt die Laufzeit bis zu dreimal nach (`Worker.Jack.Phase.nachhaken/1`). `Parsing.parse_facts_json/2` behält seine defensiven Fallbacks (`strip_and_note/1`: think-strip, Code-Fence-strip, JSON-Extract), bekommt von Jack aber mit `Jason.encode!` kodiertes JSON.

**Historie — die alte Extraktion bis J4 (#763/#1115).** Sie lief im strict JSON-Schema-Mode (Ollama-GBNF, `facts_json_schema/0` — invalides JSON war token-seitig unmöglich, `<think>`-Blocks wurden strukturell eliminiert); für Cloud-Backends/ältere Modelle griffen die defensiven Parser-Fallbacks. Lieferte ein Chunk kein verwertbares JSON oder degenerierte er, griffen `extract_num_predict_cap` (#763-Deckel) + Halbierungs-Retry; eine leere Extraktion meldete `failed` mit Klasse `extraction_empty` statt stillem `ended`.

**Der #763-Deckel schützt aber nicht gegen die Kontextdecke (#1115).** `ctx_stage2` muss Prompt **und Denkphase und Ausgabe** fassen — und die Denkphase ist der größte Posten: bei `think: "low"` real gemessen ~8.700 Token gegen ~7.900 Prompt-Token, also **mehr als der Prompt selbst**, und sie wird nirgends eingeplant. Läuft die Ausgabe dann lang, reißt die Decke mitten in ein Fakt-Objekt (`done_reason: "length"`), `Jason.decode` scheitert, und bis #1115 fielen damit auch die **bereits fertig geschriebenen** Fakten weg — im Realfall (Free Seattle S1, 2026-08-20, qwen3.8:27b) 38 Stück, nachdem der Lauf in eine Wiederholungsschleife geraten war (112 Fakten, davon 38 verschieden).

Zwei Annahmen sind dabei widerlegt worden, beide an Messdaten: `num_predict` wirkt **pro Phase**, nicht auf den Lauf (der gescheiterte Chunk erzeugte 8.700 + 7.969 Token, ohne dass der 12.000er-Deckel griff), und ein Stopp am Deckel schneidet **genauso** mitten ins JSON — der Deckel ist also kein sanfterer Abbruch, nur ein früherer. Ebenfalls widerlegt: `prompt_eval_count` ist bei aktivem `think` **nicht** die Prompt-Größe, sondern Prompt + Denk-Text (die zweite Phase bekommt beides als Kontext). Wer daraus die Bytes-pro-Token-Heuristik nachrechnet, hält `Parsing.estimate_tokens/1` (`div(byte_size, 3)`) fälschlich für doppelt zu optimistisch — gemessen sind es ~2,9–3,0 Bytes/Token, der Schätzer stimmt.

Der Hebel war deshalb **Rettung statt Vermeidung** (mit J4 entfernt — Jack gibt `Jason.encode!`-JSON hinein): `Parsing.salvage_truncated_facts/1` (pure) holt aus einem abgeschnittenen `{"facts":[…` die vollständigen Objekte heraus und verwirft das angebrochene letzte — ein halber Fakt ist schlimmer als keiner. Der Weg dorthin ist der `{:salvaged, facts}`-Ausgang von `parse_facts_json/2`, bewusst **nicht** als `{:ok, …}` getarnt: eine Rettung ist ein Symptom und wird als eigene Klasse `truncated_salvaged` in `/admin/errors` gemeldet, statt als vollständige Extraktion durchzugehen. Ein geretteter Chunk gilt als **Erfolg** — der Halbierungs-Retry entfällt dort, weil ein zweiter Lauf über denselben Chunk nur dieselbe Wand ein zweites Mal träfe. Flankierend warnt `guard_generation_headroom/4`, wenn der Deckel größer ist als der nach dem Prompt verbleibende Platz (strukturelle Fehlkonfiguration); die Denkphase selbst ist vorher **nicht** bekannt, eine Warnung darauf wäre geraten und würde bei jedem Lauf feuern. **Ehrliche Grenze:** die Fakten *hinter* dem Abriss sind weg, und die eigentliche Ursache der Schleife bleibt offen — `repeat_penalty` steht in allen Stages auf `1.0`, also **aus**. Bei großen Modellen + langem Prompt kann ein Call am HTTP-Timeout scheitern — `http_timeout_ms` (Default 20 min, per Worker tunbar) gilt für Resümee, Epos und die Registries; Jacks `/v1`-Client hat eine eigene Frist (`Worker.Agent.Modell.Ollama`, Default 600 000 ms).

Empfohlener Sanity-Check pro Worker-Setup vor dem ersten Backfill:

```elixir
# Modell antwortet überhaupt im JSON-Mode? (:summary = Jacks Modell über den nativen
# Ollama-Weg der Registries — Jacks eigener /v1-Weg ist damit NICHT geprüft)
:rpc.call(node, Worker.LLM, :complete, [:summary, "Antworte mit {\"ok\":true}", [format: "json"]])
```

### Zeitstempel-Anzeige: UTC speichern, lokal anzeigen (Issue #1014)

**Gespeichert und serverseitig gerendert wird ausnahmslos UTC.** Der Hub kennt
keine Zeitzone und bekommt auch keine — kein `connect_params`, keine
`tz`-Dependency, kein Zonen-Assign pro LiveView. Das Umschreiben in die
Geräte-Zone macht allein der Browser. Praktische Folge: bei einer Runde über
mehrere Zeitzonen sieht jeder Teilnehmer dieselbe Session-Zeit in seiner
eigenen Ortszeit, ohne irgendetwas einzustellen.

**Für jede Zeitstempel-Anzeige `<.local_time>` nutzen** (`HubWeb.UIComponents`,
in `:html` + `:live_view` importiert — überall verfügbar):

```heex
<.local_time iso={u["timestamp"]} />                        <%!-- HH:MM:SS --%>
<.local_time iso={r["ts"]} format={:datetime} />            <%!-- Datum + HH:MM --%>
<.local_time iso={err["occurred_at"]} format={:datetime_sec} />
```

Nimmt ISO-String oder `DateTime`; unparsebare Werte werden unverändert
durchgereicht (flag-not-drop), `nil` ergibt den Platzhalter.

**Das `UTC`-Kürzel im server-gerenderten Text ist kein Schmuck.** Es trägt zwei
Lasten zugleich: ohne JavaScript (und im Sekundenbruchteil davor) steht dort
eine *korrekt beschriftete* UTC-Zeit statt einer stillen Falschaussage — und
für `assets/js/local_time.js` ist genau dieses Kürzel der Marker
„noch nicht formatiert", woraus Idempotenz ohne Buchhaltung folgt. Das
`datetime`-Attribut behält immer den maschinenlesbaren UTC-Wert.

Umgeschrieben wird per **MutationObserver**, bewusst nicht per LiveView-Hook:
`phx-hook` verlangt eine eindeutige DOM-`id` pro Element, Zeitstempel stehen
aber in Schleifen (jede Utterance eine Zeile) — ein Duplikat bricht LiveView.
`characterData` im Observer ist Pflicht, weil morphdom bei einem Diff oft nur
den Textknoten ersetzt; ohne das spränge die Anzeige beim nächsten Re-Render
zurück auf UTC.

Ein Quelltext-Wächter (`local_time_guard_test.exs`) verbietet
`Calendar.strftime` im `hub_web`-Layer außerhalb von `ui_components.ex` — genau
die Drift zu mehreren Privat-Formatierern war der Ursprungsdefekt (vier
Formatierer, zwei davon unbeschriftetes UTC). **Ehrliche Grenze:** rohes
`DateTime.to_iso8601/1` im Template fängt der Wächter nicht (zu viele legitime
Nicht-Anzeige-Verwendungen).

Betrifft **nicht** den In-Game-Kalender (#724): dessen Chronik-Daten sind
erzählte Zeit auf einem Tageszähler, keine Wanduhr — dort gibt es keine
Zeitzone und soll auch keine geben.

### Chronik-Anzeige (Issue #385)

Chronik-Einträge werden in der UI als gerendertes Markdown angezeigt. Der Edit-Form hat zwei kleine Inputs (`in_game_date`, `label` — bleiben strukturiert für Sortierung + Refs) plus eine große Markdown-Textarea (`markdown_body`).

**Storage:** additives Mnesia-Schema — `chronik_entries` hat seit #385 eine 8. Spalte `markdown_body` (analog zur `source_refs`-Migration aus #114). Alte Einträge haben `nil`, Lazy-Migration beim ersten Edit füllt das Feld. `summary` bleibt als Backward-Compat-Spalte unverändert (wird vom Edit-Save **nicht** überschrieben — Plaintext-Vertrag der Spalte bleibt).

**Rendering:** **seit #604 nur noch EIN Render-Pfad** — `render_md_safe/1` in `HubWeb.CampaignLive.Components` (`apps/hub/lib/hub_web/live/campaign_live/components.ex`, seit #434 dort, nicht mehr im LiveView-Modul). Resümee, Epos **und** Chronik laufen alle darüber.

- `render_md_safe/1`: Defense-in-Depth via Earmark `escape: true` + `HtmlSanitizeEx.basic_html/1`. Erste Schicht neutralisiert literales HTML schon vor dem Sanitizer (`<script>` → `&lt;script&gt;`), zweite Schicht ist die Standard-XSS-Politur (strippt `<iframe>`, `<style>`, `on*`-Handler, `javascript:`-URLs).

Der frühere `render_md/1` (`escape: false`, kein Sanitizer) wurde mit #604 **entfernt**: Resümee + Epos waren GM-editierbar, liefen aber noch über `render_md/1` → Stored-XSS (ein GM konnte `<script>` injizieren, das allen Mitgliedern + reviewenden Admins ausgeliefert wurde). Die unsichere Variante ist bewusst gelöscht, damit sie nicht versehentlich wieder verdrahtet wird (Regressionstest in `render_md_safe_test.exs` asserted ihre Abwesenheit). **Für jeden Markdown-Anzeige-Pfad `render_md_safe/1` nutzen.**

### Stage 1 (ASR) — Whisper-Prompt ist AUS (Issue #1000)

**`whisper_use_prompt` ist per Default `false` — der `--prompt` wird nirgends mehr übergeben.** Grund ist eine A/B-Messung an echtem Session-Audio (2026-08-11): der Prompt kann die Dekodierung einer ganzen Spur in eine **Wiederholungsschleife** kippen, die den echten Inhalt verdrängt — gemessen 63 Zeilen, davon **61× derselbe Satz**, gegenüber 40 Zeilen mit 13 verschiedenen ohne Prompt. Verloren gingen dabei nachweislich echte Spielinhalte (Karten-Beschreibungen, Dialog). Der Effekt ist **audio-abhängig**: auf einer zweiten Spur desselben Mitschnitts trat er nicht auf (dort war der Prompt sogar leicht nützlich — feinere Segmentierung). Aber wenn er eintritt, ist die Spur **still** verloren: es gibt kein Fehlersignal, das Transkript sieht bloß kurz aus.

Damit ist die frühere Annahme widerlegt, der Batch-Pfad sei wegen längerer Segmente unbedenklich (für den Single-Source-Pfad war dasselbe Phänomen schon mit #304 erkannt und der Prompt dort abgeschaltet). Beide Prompt-Quellen hängen jetzt an dem EINEN Schalter — Vokabular (`whisper_initial_prompt` bzw. per-Kampagne `vocab_hint`) UND rollierender Kontext aus `PromptBuilder`. **Die Settings zu leeren reicht nicht**: `PromptBuilder.context_part/1` (letzte 10 Utterances) hängt an keinem Setting.

Wer den Vokabular-Nutzen („Initiative" statt „Demonstrative", „W20" statt „wie 20") bewusst gegen das Schleifen-Risiko abwägen will, setzt `whisper_use_prompt` auf `true` — das ist eine informierte Einzelfall-Entscheidung, kein Default. `opts[:no_prompt]` (Single-Source, #304) bleibt als engerer Schalter davon unabhängig wirksam.

Die Argumentliste baut `Worker.Recording.Transcribe.build_whisper_args/2` — bewusst `def` statt `defp`, damit Tests und Vorher/Nachher-Vergleiche exakt die Produktions-Argumente fahren statt eines Nachbaus.

**Nicht die Ursache** (systematisch ausgeschlossen, nicht vermutet): Flash Attention (in whisper.cpp 1.9.1 neu default-an, liefert bei echter Sprache Wort für Wort identische Zeilen), ROCm/GPU (läuft), `--max-len`/`--split-on-word` (einzeln getestet, unschädlich). **Ehrliche Grenze**: ob der Defekt eine Regression von whisper.cpp 1.8.3 → 1.9.1 ist, lässt sich nicht mehr belegen — das alte Paket (`whisper.cpp-hip`) ist deinstalliert und aus dem AUR verschwunden.

### Stage 1 (ASR) — Per-Token-Confidence (Issues #376/#381)

Whisper-CLI läuft seit #376 mit `-ojf` (Full-JSON) statt `-oj`. Pro Segment wird aus `tokens[].p` ein Confidence-Aggregat im `UtteranceAppended`-Payload publisht. Special-Tokens (ID ≥ 50257 = `[_BEG_]`, `[_TT_*]`, EOT) werden vor der Aggregation rausgefiltert, weil sie p≈1.0 haben und den Mean verzerren würden.

**Aggregat-Felder** (seit #381):

- `mean_p` — arithmetisches Mittel aller Token-p (für Diagnostik).
- `min_p` — niedrigste Token-p im Segment (für Diagnostik). **Vorsicht Längen-Bias**: das Minimum über N Tokens sinkt statistisch mit N, lange Utts haben fast immer ein niedriges min_p auch bei sauberer Transkription. NICHT als Flag-Signal für lange Sätze nutzen.
- `low_token_fraction` — Anteil der Tokens mit `p < threshold`. Längen-normalisiert, primäres Flag-Signal des Hub-UI. Threshold per Worker konfigurierbar via `Worker.Settings.put(:confidence_low_token_threshold, 0.5)` (Default 0.5).
- `token_count` — N (nach Special-Token-Filter). Marker `0` = Platzhalter aus `to_confidence_map/1` (Seed/Manual; bis J4 auch der Probelauf), Hub-UI skipt diese.

**Eingefrorenes Aggregat:** der `:confidence_low_token_threshold`-Lookup passiert in `aggregate_token_confidence/1` zur **Transkriptionszeit**, das Resultat ist persistiert. Späteres Drehen des Settings wirkt nur auf neue Utterances — alte Aggregate behalten den damaligen Threshold. Für Rück-Effekt: Pipeline neu laufen lassen.

**Zwei-dimensionales Tuning** (Issue #381):

- Per-Token-Schwelle (Worker, Default 0.5): "Was zählt als wackeliges Token"
- Utterance-Fraction-Schwelle (Hub, `@low_token_fraction_threshold = 0.2`): "Wie viele wackelige Tokens braucht es, um zu flaggen"

Interaktion: tieferer Per-Token-Cut → mehr Tokens fallen rein → höhere Fractions → mehr Flags. Höherer Fraction-Cut → strenger flaggen. Beim Tunen beide Knöpfe im Blick haben, ggf. an einem festhalten und am anderen drehen.

**Kurzes-Ende-Caveat (#381):** bei sehr kleinem `token_count` (n<8) ist `low_token_fraction` grob (z.B. N=2 → nur 0/0.5/1.0 möglich) und über-sensitiv für Clip-Rand-Tokens. Hub-Tooltip warnt bei n<8 explizit. Adressierbar später via `n >= N_min`-Guard im Primary-Gate, sobald Real-Data zeigt wie oft das auftritt.

**Wichtig — confidence ist Routing-Signal, kein Rejection-Signal:** der `filter_hallucinations`-Filter ist bewusst NICHT confidence-aware. Whisper-Halluzinationen auf Stille (`"Untertitel von Amara.org"`, Repetition-Loops) werden confident generiert — ein min_p-Drop fängt die nicht. Wo min_p wirklich niedrig ist, sind meist seltene-aber-korrekte Eigennamen oder Code-Switching — also genau die Tokens, die für Stage 3 erhalten bleiben müssen. Ein Drop dort produziert Deletions → WER hoch, nicht runter. Confidence soll später zum **Targeting** dienen (low-fraction-Spans an einen Glossar-/Refinement-Pass weiterreichen statt sie still zu verwerfen).

Seed-Pfade (bis J4 auch der Probelauf), die confidence als Float schreiben, werden über `Worker.Recording.Transcribe.to_confidence_map/1` auf das Map-Format normalisiert (`low_token_fraction: 0.0, token_count: 0`), damit später kein `confidence["min_p"]` an einem Float-Altwert crasht. Catch-all loggt + nil bei unbekannten Typen.

### Multi-Source-Goldstandard (Issue #377)

End-to-End-Eval für den Multi-Source-Pfad (AudioBuffer → Transcribe → `UtterancesTranscribed`). Goethe Faust I (Librivox CC0) als Audio-Quelle; bewusste Lücken: literarisches Lese-Register, In-Distribution-Namen → WER als untere Schranke, Entscheidungen am Delta + Bucket-Ranking.

Fixture-Setup (einmalig pro Maschine): `bash apps/worker/test/fixtures/stt/setup.sh` lädt Librivox-MP3s, schneidet Per-Turn-WAVs, baut Per-Sprecher-Multitrack-Spuren in drei Varianten:

- `clean` — Stille (anullsrc) + sequentielle Turns via `adelay`/`apad`, dann `amix=normalize=0` (kein 1/N-Pegel-Confound)
- `realistic` — clean + Inter-Mic-Bleed der anderen Sprecher bei -25 dB + Pink-Noise-Raumton -50 dB lowpass 4 kHz
- `overlap` — wie clean, aber 2 Turns starten früher → echte Simultanrede

Master-Clock-Timeline + Sprecher-Mapping leben in `apps/worker/test/fixtures/stt/faust/sessions/gartenszene.json`. Werte in `setup.sh` müssen synchron bleiben.

**ExUnit-Korrektheits-Smoke** (kein WER-Gate): `mix test --only stt_bench`. Asserts auf Routing (worker-internal smoke), Timeline-Drift < 5 s, Output > 0. WER wird ausgegeben, nicht asserted.

**WER-Regression-Gate**: `mix lore.eval.multisource --session gartenszene --variant clean --max-rel-degradation 0.20` vergleicht aktuellen `global_wer` gegen `apps/worker/test/fixtures/stt/baselines.json`. Exit 1 bei >20% relativer Verschlechterung. Baseline schreiben: `--output-baseline test/fixtures/stt/baselines.json`. Vor jedem Lauf werden `whisper_lang=de`, `whisper_initial_prompt=""`, `whisper_max_len=0` gepinnt (deterministisch in beide Richtungen).

Aggregation: **Micro-Average** (Σ Edits / Σ Referenzwörter, KEIN Macro-Mittel). Bucket-WER via **Backtrace-Attribution** auf der Referenz-Seite — Insertions zwischen ref_i und ref_{i+1} werden ref_{i+1} zugeordnet. Konvention konsistent in `Worker.MultiSourceEval.Wer`.

Routing-Test ist explizit als **Worker-internal Smoke** etikettiert. Hub-side End-to-End-Routing (`Hub.Commands.forward_audio_chunk` → `pick_leader`) ist Folge-Issue. Realistic-Variant misst Cross-Talk-Robustheit als WER-Delta clean→realistic (Content-Kontamination, nicht Routing-Härte).

### Discord-Bot-Voice-Capture (Epic #985, Slice 1)

Alternative zum Browser-Mic-Pfad: ein Discord-Bot (Nostrum + DAVE) tritt einem Voice-Channel bei und speist die Aufnahme in denselben `AudioBuffer.append/5`-Pfad ein (`mic_mode: :per_player`). Machbarkeit bewiesen durch den #941-Spike (Gateway-Join + DAVE-Decrypt + SSRC→User-Mapping funktionieren); die Integration in dieses Repo lief als **eine** durchgängige PR über sechs Stages.

**Kampagnen-Config (Stage A):** GM hinterlegt Guild-ID + Voice-Channel-ID pro Kampagne (`CampaignDiscordConfigSet`, eigene Mnesia-Tabelle `worker_campaign_discord_configs`, Muster `CampaignCalendarSet`). Reader normalisiert `""` UND fehlende Row auf `nil` — „nicht konfiguriert" hat genau EINE Repräsentation. Eigener schmaler Live-Refresh-Scope `campaign_discord_config` (NICHT `campaign_meta` — dessen Snapshot liefert nur die `worker_campaigns`-Row, kein `discord_config`-Key).

**Bot-Token (Stage B):** Deployment-Eigenschaft des Workers (nicht pro Kampagne) — `Worker.Discord.BotToken`, Settings-first/ENV-Fallback wie `Worker.LLM.ApiKey`. Nie im Snapshot durchgereicht, nur der Status.

**Nostrum-Dependency + Boot (Stage C):** `{:nostrum, github: "Kraigie/nostrum"}` (DAVE-Receive-Decrypt existiert nur auf nostrum-main, nicht im letzten Hex-Release) — der reale Pin lebt im committeten `mix.lock`. **Kein `config :nostrum, :token`** (aktiviert Nostrums Alt-Auto-Start-Pfad, kollidiert mit der eigenen Supervision). `{Nostrum.Bot, bot_options}` startet **nicht** mehr als statischer Boot-Child, sondern seit **#1076** unter `Worker.Discord.GatewaySupervisor` (eigener `DynamicSupervisor`), gesteuert von `Worker.Discord.BotGate` — s. den eigenen Abschnitt unten.

**Prozess-Lifecycle (Stage D):** `Worker.Discord.Registry` + `Worker.Discord.BotSupervisor` (`DynamicSupervisor`) — das ERSTE dynamische Prozess-Pattern in `apps/worker` (alle anderen Recording-Prozesse sind Singleton-GenServer). Per-Kampagne `Worker.Discord.VoiceSession` (`restart: :transient`). Ein abnormaler Exit publisht ein `PipelineErrorLogged` (Stage `"discord_voice"`, sichtbar in `/admin/errors`) — ein Init-Fehler VOR Prozessstart (z.B. Token erst nach dem letzten Boot gesetzt) erreicht diesen Pfad NICHT, landet nur im Log (empirisch verifiziert, `DynamicSupervisor.start_child` fängt das sauber ab). **Seit #987** trägt der Registry-Wert die besitzende Kampagne + den belegten Voice-Channel (`VoiceSession.via/2`/`owner/0`, nicht nur die Guild-ID) — zwei Kampagnen auf derselben Guild konnten sich vorher sonst gegenseitig die Session stehlen/killen (echter Live-Test-Fund: Kampagne B sah „Guild belegt" und tat nichts, `Recorder` merkte sich trotzdem eine `discord_guild_id` für B, ein späterer Stop von B hätte As aktive Session gekillt). Ein Konflikt wird jetzt LAUT (Logger.error + `PipelineErrorLogged`, nennt die belegende Kampagne UND den belegten Channel) statt stillschweigend übernommen; `stop_voice_session/2` terminiert nur die eigene Session. **Ehrliche Grenze bleibt bestehen** (kein Bug, echtes Discord-Protokoll-Limit): Nostrums Voice-API ist selbst guild-skaliert, ein Bot-Account kann pro Guild nur in einem Voice-Channel gleichzeitig sein — zwei Kampagnen auf derselben Guild können nie beide gleichzeitig bedient werden, nur der Konflikt ist jetzt sichtbar statt destruktiv.

**Hook-Punkte + Aufnahme-Modus-Wahl (Stage E, seit #987 kein Auto-Join mehr):** der Discord-Bot-Join passiert NICHT mehr automatisch beim Session-Start, sondern über eine explizite, EINMALIGE Session-Wahl — sobald eine Session offen ist und noch niemand gejoint hat, zeigt der Hub 3 Buttons (🤖 Discord / 🎙 Single / 🎙👥 Multi). Discord schließt Browser-Mikro (Single+Multi) für die GANZE Session und ALLE Teilnehmer aus, und umgekehrt (`SessionCaptureModeSet`-Event, eigene Mnesia-Tabelle `worker_session_capture_modes`, Muster `CampaignDiscordConfigSet` nur session- statt campaign-geschlüsselt; `Worker.Recording.Recorder.choose_capture_mode/3` prüft den aktuellen Zustand VOR dem Publish). Schlägt der Discord-Bot-Join fehl (kein Token/Config/Nostrum.Bot, oder Guild-Konflikt), wird KEIN Modus gesetzt — die Buttons bleiben für einen erneuten Versuch offen, statt den GM ohne funktionierenden Aufnahme-Pfad einzusperren. Best-effort wie zuvor: ein Fehler blockiert nie den Kern-Recording-Start.

**Slash-Commands: `/lore start|stop|status` (Issue #1033).** Die Aufnahme lässt sich im Discord-Server steuern, ohne den Browser zu öffnen. Vor allem der **Stop** brauchte bisher zwingend die Web-UI — blieb sie zu, lief die Sitzung endlos weiter und pausierte nebenbei die GPU-Hintergrundjobs.

**Der Namensraum war ein Fund, keine Wahl.** `/lore` ist bei Discord **seit Mai 2026 registriert**: Commit 6f55273 (M10b) meldete `/lore record start|stop` + `/lore status` an, Issue #33 warf den Bot einen Tag später komplett raus — **ohne die Commands abzumelden**. Registrierte Application-Commands leben auf Discords Servern, nicht im Repo; sie überdauern jedes Code-Entfernen. Der Eintrag hing drei Monate verwaist im Server-Picker und quittierte einen Klick mit „Die Anwendung reagiert nicht". Daraus folgen zwei Entscheidungen: der Namensraum ist `/lore` (er gehört uns ohnehin und steht im Muscle Memory), und registriert wird über **`bulk_overwrite_guild_commands/2`**, nicht `create_guild_command/3` — der Overwrite setzt den registrierten Satz *gleich* dem deklarierten, räumt die Leiche damit beim ersten Start mit ab und macht neue Altlasten strukturell unmöglich. Die Zwischenebene `record` ist weg (sie trägt keine Information, solange es nichts anderes zu starten gibt).

**Registriert wird in JEDER Guild, in der der Bot sitzt** (`Worker.Discord.CommandRegistrar`, ausgelöst per `:GUILD_AVAILABLE`/`:GUILD_CREATE` — auf `:READY` sind die Guilds noch „unavailable"), nicht nur in konfigurierten. Naheliegend wäre das Gegenteil, hätte aber eine stille Falle: wer Discord für eine Kampagne frisch einrichtet, hätte den Command bis zum nächsten Worker-Neustart nicht, ohne Hinweis worauf es liegt. Ob eine Kampagne dahinterhängt, entscheidet sich deshalb zur **Laufzeit**; ist keine konfiguriert, sagt die Antwort genau das. Guild-scoped (sofort aktiv) statt global (bis zu 1 h Propagation). Scheitert die Registrierung, ist das von außen **nicht** erkennbar — der Command taucht schlicht nie auf; deshalb eigene `/admin/errors`-Klasse `command_registration_failed` (Stage `discord_commands`), gemeldet **pro betroffener Kampagne** (ein Fehler ohne `campaign_id` hätte dort keine Zuordnung und wäre selbst wieder unsichtbar). Häufigste erwartbare Ursache: fehlender OAuth-Scope `applications.commands` → Re-Invite.

**Auswahl statt Tippen, und Einrichtung nebenbei (#1081).** Die `kampagne`-Option ist `autocomplete: true` — Discord fragt bei jedem Tastendruck nach Vorschlägen (Interaction **Typ 4**, Antwort **Typ 8**), die Liste kommt live aus Mnesia. Damit ist die alte Sorge gegen `choices` gegenstandslos: eine frisch angelegte Kampagne steht sofort in der Liste, ohne dass irgendetwas neu registriert werden müsste. Der `value` einer Auswahl ist die **campaign_id**, nicht der Name (Namen ändern sich und sind nicht eindeutig); getippter Freitext bleibt erlaubt und wird weiterhin unscharf aufgelöst. **Fehlt die Typ-4-Klausel im Consumer, zeigt der Client dauerhaft „Lade Optionen"** — ein stiller Ausfall, den nur der Tippende sieht.

Angeboten werden die Kampagnen, in denen der Aufrufer **Mitglied** ist (#1082) — **auch die, die an keinen Server gebunden sind**, kenntlich am Zusatz „· hier einrichten". Denn beim Start wird die Bindung gleich mit erledigt: `Worker.Discord.AutoConfig.decide/3` (pur) entscheidet, `CommandInteraction` schreibt das bestehende `CampaignDiscordConfigSet`. Guild kommt aus der Interaction, der Sprachkanal ist der, **in dem der Aufrufer gerade sitzt** (`voice_states` der Guild über `NostrumSafe.voice_states/1` — dieselbe öffentliche Quelle, die #988 für die Anfangs-Präsenz nutzt). Damit entfällt der bisherige Weg über Entwicklermodus, zwei Rechtsklicks und die Weboberfläche; die Runde kann per Befehl anfangen, ohne den Hub je geöffnet zu haben.

**Drei Dinge passieren dabei ausdrücklich nicht:** eine Kampagne, die schon an einem **anderen** Server hängt, wird nie still umgehängt (das würde die Aufnahme in der anderen Runde abklemmen, ohne dass es dort jemand merkt — es braucht einen bewussten Schritt im Hub); sitzt der Aufrufer in keinem Sprachkanal, wird keiner geraten, sondern gesagt, was zu tun ist; und die Einrichtung wird **benannt** („Diesen Server als Aufnahme-Ort … eingetragen"), weil eine stillschweigende Konfiguration eine Überraschung wäre — gewollt war Aufnehmen, nicht Einrichten. Ein Kanalwechsel **innerhalb desselben Servers** gilt dagegen als Umzug der Runde und wird ohne Rückfrage übernommen.

**Vorrang bei der Auflösung ohne Angabe:** die Kandidatenliste enthält seit der Autokonfiguration zwei Quellen — die Kampagnen dieser Guild (auch fremde, damit ein Nicht-Mitglied die wahre Auskunft „du bist kein Mitglied" bekommt statt „hier ist nichts konfiguriert") und die eigenen. Ohne Angabe gewinnt deshalb die **hier eingerichtete** Kampagne; sonst wäre `/lore start` für jeden mehrdeutig, der in mehr als einer Runde spielt. Erst wenn hier keine oder mehrere eingerichtet sind, wird nachgefragt.

**Guild → Kampagne ist 1:N** (#987). Neue Leserichtung `Worker.Repo.campaigns_for_guild/1` in einem eigenen Modul `Worker.Repo.DiscordConfig` (`Worker.Repo.Artifacts` riss damit die 1000-Zeilen-Grenze des God-Module-Checks; der Schnitt ist inhaltlich — die Config ist kein generiertes Artefakt). Bei genau einer Kampagne wird die Option `kampagne` ignoriert (eine Fehleingabe soll den Spielabend nicht aufhalten), bei mehreren nennt die Antwort die zur Wahl stehenden Namen. Die Option ist bewusst ein **freier String ohne Choices**: Choices müssten zur Registrierungszeit feststehen und wären ab der nächsten Kampagnen-Anlage stale, ohne dass es jemand merkt.

**Autorisierung sitzt in `Worker.Discord.CommandInteraction`, nicht im Recorder.** Der Web-Weg ist doppelt geschützt (`HubWeb.Permissions` + `Recorder.start_for_owner/3`), aber ein Slash-Command kommt am Hub **vorbei**, und `Recorder.stop_for_campaign/1` hat gar keine eigene Schranke — sie war im Web-Pfad nie nötig. Ohne die Prüfung hier könnte jeder Server-Teilnehmer eine fremde Aufnahme beenden. Geprüft wird dieselbe Schranke wie beim Start (per-Campaign-Rolle `:spielleiter`), bewusst ohne Admin-Sonderweg. `status` ist ausgenommen: wer im Sprachkanal sitzt, darf wissen, ob aufgezeichnet wird — das ist die Transparenz-Seite der Einwilligung, keine Bequemlichkeit.

**Antwort-Disziplin: aufgeschoben (Typ 5), nicht sofort.** `ConsentInteraction` antwortet sofort, weil ein Klick nichts Langsames auslöst; hier ist es umgekehrt (`stop` hat 60 s Budget, #1011). Discord verwirft eine Interaction nach 3 s — also erst „denkt nach…", dann die Arbeit, dann `edit_response/2`. Sofort zu antworten hieße „Aufnahme beendet" zu schreiben, bevor feststeht, ob sie beendet werden konnte. Alle Antworten sind ephemer. **Ein Recorder-Timeout bekommt eine eigene, wahre Aussage** („der Abschluss dauert länger, das Material geht nicht verloren") statt des generischen Fehlertexts — der Recorder arbeitet den Stop vollständig ab, nur die Antwort geht ins Leere, und Panik am Spielabend wäre die falsche Reaktion. `/lore start` setzt den Discord-Modus auch dann, wenn die Sitzung schon läuft (häufigster Fall: im Browser gestartet, Modus noch nicht gewählt).

**Gegen einen echten Discord-Server verifiziert** (2026-08-18, PR-Test-Worker gegen die Live-Guild): `guild_commands/2` liefert danach genau `[{"lore", ["start", "stop", "status"]}]` — die Mai-Leiche ist weg, ohne dass jemand etwas löschen musste, und der Scope `applications.commands` ist damit belegt (sonst 403).

**Zusammenspiel mit #1076:** die Registrierung hängt an `:GUILD_AVAILABLE`, nicht am Boot-Zeitpunkt — startet der Bot wegen eines Netzfehlers erst im Backoff-Retry (`Worker.Discord.BotGate`), registriert er eben dann auch die Commands. Aus dem früheren Totalblocker („kein Gateway, kein Command, bis zum Neustart") wird damit eine Verzögerung, die sich von allein heilt.

**Ehrliche Grenzen:** ohne Gateway-Verbindung kommt kein Command an — der Zustand steht in `/settings` unter **Gateway-Verbindung** (#1076). `VoiceSession.capture_stats/2` (die „N von M werden aufgezeichnet"-Zeile im Status) fragt einen Prozess, der während einer TTS-Ansage blockieren kann; bleibt die Antwort aus, fehlt die Zeile, statt eine Zahl zu erfinden. Und: **zwei Worker mit demselben Bot-Token** (z.B. `worker_prod` plus ein PR-Test-Stack) halten zwei Gateway-Verbindungen; Discord schickt eine Interaction an genau eine davon, also kann ein `/lore`-Befehl bei einem Worker landen, der den Handler nicht hat. Das ist keine Eigenheit dieses Features (Consent-Klicks teilen sie), aber hier fällt sie zuerst auf.

**Zeitkorrektur + Audio-Bridging (Stage F):** Discord sendet Pakete pro Sprecher nur während gesprochen wird — naive Konkatenation lässt die Pro-Sprecher-Spuren gegeneinander driften (genau das Problem, das der #941-Spike NICHT gelöst hatte). `Worker.Discord.FrameBuffer` nutzt Ankunftszeit (nicht RTP-Timestamp — der ist pro SSRC nicht sprecherübergreifend vergleichbar) als gemeinsame Referenz. `Worker.Discord.OggOpusMuxer` (eigener, gegen echte ffmpeg-Ogg-Pages CRC-verifizierter Ogg-Opus-Muxer) + `Worker.Discord.AudioBridge` (Decode → Stille auf PCM-Ebene einfügen, NICHT als Opus-Paket-Trick — eine Granule-Lücke im Container wird von ffmpeg nachweislich nicht automatisch mit Stille aufgefüllt → Re-Encode über das bestehende `Worker.MultiSourceEval.AudioBuilder.wav_to_webm_b64/2`, #377) bauen daraus den finalen WebM-Blob. **Seit #987 gegen einen echten Discord-Server PR-getestet, End-to-End erfolgreich** (Bot joint → nimmt auf → verlässt den Kanal → Clip → Whisper-Transkript → Utterance) — dabei fiel ein echter Bug auf: `splice_silence/2`s festes `binary-size(@bytes_per_frame)`-Pattern-Match nahm an, JEDES dekodierte PCM-Segment habe exakt 960 Samples (nur gegen synthetische ffmpeg-Test-Pakete verifiziert) — echte, live dave_decrypt'te Discord-Pakete halten das nicht durchgängig ein und crashten den Clip-Bau. `take_frame/1` nimmt jetzt best-effort was tatsächlich da ist.

**Prozess-Lifecycle-Nachtrag (#987): `trap_exit` fehlte.** `DynamicSupervisor.terminate_child/2` sendet ein reguläres `exit(pid, :shutdown)`-Signal — ein GenServer OHNE `Process.flag(:trap_exit, true)` wird davon HART gekillt, `terminate/2` läuft dann NIE (per `Process.monitor` empirisch verifiziert: der Prozess stirbt mit `reason: :shutdown`, aber kein `terminate/2`-Zweig feuert). Das erklärte, warum der Bot den Voice-Channel nach dem Stop nie verließ, obwohl `terminate/2` bereits korrekt `Voice.leave_channel/1` aufrief — der Code wurde schlicht nie erreicht. Fix: `Process.flag(:trap_exit, true)` in `init/1` (einzige Verlinkung ist der `DynamicSupervisor` selbst, keine Nebenwirkungen auf andere Signale).

**Consent pro Sprecher, Klick statt Stimme (#1005 — löst #1002 ab).** Der erste Live-Lauf von #1002 hat zwei Dinge widerlegt, die dort noch stimmten:

1. **Der Audio-Pfad war kaputt, nicht die ASR.** `FrameBuffer.segment_ssrc/1` rechnete `max(arrival_ms - prev_end, 0)` mit `prev_end = arrival + 20 ms`. Discord sendet alle 20 ms; der gemessene Abstand ist `20 ± Jitter`. Damit wurde **jeder positive Jitter zu eingefügter Stille**, jeder negative auf 0 geklemmt — ein systematischer Bias, der zusammenhängende Rede alle 20 ms zerschnitt. Gemessene Folge: Whisper lieferte Bruchstücke („Das wäre jetzt. auch mit zu. Aufnahme."), `mean_volume -40 dB`, VAD fand keine Sprachsegmente, Session hatte 0 Utterances. Das betraf **jeden** Discord-Mitschnitt. Fix: `gap_silence/1` (pure) — Lücken unter `@min_gap_ms` sind Jitter und erzeugen keine Stille, darüber echte Pausen, quantisiert auf 20-ms-Vielfache. Die Schwelle ist **hergeleitet**: die Abstandsverteilung ist bimodal, weil Discord in Pausen gar keine Pakete sendet (~20 ms innerhalb einer Passage vs. ≥150 ms bei echten Pausen). Der Session-Start-Offset des ersten Frames bleibt ungeschwellt (sprecherübergreifende Ausrichtung, keine Jitter-Frage).
2. **Gesprochene Zustimmung trägt nicht.** Akustik ist **nicht identitätsgebunden**: sagt A den Satz und B hat Lautsprecher statt Kopfhörer, landet A's Stimme in B's Spur — die Erkennung machte daraus B's Einwilligung. Das ist eine *unterstellte* Einwilligung und rein akustisch nicht ausschließbar. Dazu wurde der Satz im Live-Lauf gesagt und nicht erkannt. Deshalb ist der Weg jetzt ein **Discord-Button** (`interaction.user.id` ist von Discord authentifiziert); `ConsentPhrase`/`ConsentCheck` bleiben für einen späteren Sprach-**Auslöser** (Satz → Nachfrage → Klick bestätigt), werden aber derzeit nicht aufgerufen. Die Ansage nennt konsequent nur den Knopf — eine Bitte um etwas, das nichts auslöst, wäre schlimmer als keine.

**Kein Zeitfenster mehr, sondern eine Zeitachse pro Sprecher.** Das globale 45-s-Fenster ist weg (es galt für alle → kurze Sessions endeten leer; und Late-Joiner konnten prinzipiell nie zustimmen). `Worker.Discord.ConsentState` (pure) rechnet auf der **Übergangs-Historie**: die gedeckte Menge ist ein Intervall `[grant, revoke)`, bei Grant→Revoke→Re-Grant eine Intervall-Menge (ein einzelner `since_ms` verlöre das erste Intervall). Der Flush filtert pro Sprecher (`keepable_frames/2`) — **die Einwilligung wirkt nur nach vorn:** wer in Minute 12 zustimmt, dessen Audio aus 0–12 wird verworfen, nicht nachträglich freigegeben. Ein Widerruf schneidet ab seinem Zeitpunkt ab, lässt den gedeckten Teil aber stehen. Grenzsemantik: Grant inklusiv, Widerruf exklusiv. **Eine Uhr, nicht zwei:** der Klick-Zeitstempel ist die lokale monotone Ankunftszeit beim Worker, nicht die Discord-Serverzeit (ein Vergleich über Uhrengrenzen wäre bei Skew genau an der Kante falsch). Der Hot-Path (`handle_cast({:packet, …})`, 50 Casts/s/Sprecher) hat **keine** Zustandsweiche mehr — divergierte sie, landeten Frames eines Zugestimmten im falschen Eimer.

**Identität am Paket, nicht am Flush** (#988 gebaut, #1005 nutzt es): die `ssrc_map` liegt im `VoiceWSState` des Events. Eine Auflösung erst beim Flush war nach einem Voice-Reconnect nicht bloß unvollständig, sondern **falsch** — neue SSRC-Vergabe hätte Audio unter fremder Einwilligung gespeichert. Frames tragen die aufgelöste `did`; ohne Identität werden sie verworfen und gezählt. **Der SCHREIBpfad tat es bis #1052 trotzdem weiter**: `keepable/2` nutzte die mitgeführte Identität nur für den Einwilligungs-Filter, danach gruppierte der Clip-Bau wieder nach SSRC und `handle_clip/4` löste gegen eine **beim Speichern frisch geholte** Tabelle auf — also nach dem Fenster, das gerade weggeschrieben wurde. War die Voice-Verbindung in diesem Moment tot, war die Tabelle leer und das ganze Fenster verloren (bis zu eine Minute, alle Sprecher), mit einer Logzeile und als einziger Fehlerpfad des Flushes **ohne** Eintrag in `/admin/errors`; `unresolved_ssrc_frames` feuerte am 13.08. real zweimal. Seit #1052 leitet `Flush.identitaeten_aus_frames/2` die Zuordnung aus den Frames selbst ab, und das Modul fragt Nostrum gar nicht mehr. Trägt ein SSRC im selben Fenster **mehrere** Identitäten (Neuvergabe nach Reconnect), wird nicht geraten, sondern verworfen und als eigene Klasse `ambiguous_ssrc` gemeldet — Audio unter fremder Identität hiesse Audio unter fremder Einwilligung. `flush_identitaet_test.exs` bewacht die Herkunft (gegengeprüft).

**Widerruf (Art. 7 Abs. 3 DSGVO) ist Teil desselben Wurfs**, nicht später: sobald Zustimmung ein Klick ist, muss der Widerruf genauso einfach sein. Event `AudioConsentRevoked`, Tabelle `worker_audio_consent_status` (`discord_id, verdict, version, event_id, ts`) hält **beide** Verdikte. Auflösung per **LWW über `event_id`** — nicht „granted gewinnt" und **nicht terminal**: ein terminales `:granted` machte den Widerruf unrepräsentierbar, und eine alte Zustimmung überlebte je nach Zustellreihenfolge jeden Widerruf (#766-Klasse: Delete↔Wiederkehr). `Worker.Repo.audio_consent_status/1` ist Read-both/Write-new — die neue Tabelle hat Vorrang, `worker_audio_consents` bleibt Legacy-Lesequelle. Daraus folgt eine **bewusste Umkehr der üblichen Degradation**: eine Alt-Zustimmung ohne `event_id` verliert gegen jeden Widerruf (bei Einwilligung ist fail-closed richtig). `ConsentGate.allow?/2,3` ist die einzige Lesestelle. Ein persistierter Widerruf schlägt auch ein frisches Sprach-`:granted`; umgekehrt hebt ein gesprochenes `:declined` eine persistierte Zustimmung **nicht** auf (Akustik darf keine Einwilligung zurücknehmen).

**Der Button wird beim Join in den Voice-Kanal gepostet** (Discord-Text-in-Voice → kein zusätzliches Config-Feld, keine Schema-Erweiterung). `ConsentButton` ist pure: `payload/2`, `custom_id/2`, `parse_custom_id/1`, `verdict_for_click/3`. Die `custom_id` trägt Aktion, Wortlaut-Version **und** Session — Discord-Nachrichten bleiben liegen, ein Klick auf die Nachricht von letzter Woche würde sonst eine Zustimmung für die heutige Aufnahme erzeugen. Der `components`-Block ist eine handgebaute Map: Nostrums Component-Struct serialisiert alle 18 Felder inkl. `null`, und `:components` ist in der `Api.Message.create/2`-Doku nicht gelistet (Passthrough, im Nostrum-Repo ungetestet). `ConsentInteraction` hält die Reihenfolge: Registry-Kontext (kein `GenServer.call` — eine Interaction verfällt nach 3 s und die Session blockiert beim TTS) → pure Prüfung inkl. Kanal → **antworten** → Session informieren → persistieren (im Consumer-Task, nicht im GenServer).

**Ehrliche Grenzen (#1005):** Text-in-Voice ist **nicht verifiziert** — klappt der Post nicht, steht `consent_button_unavailable` in `/admin/errors` und wer noch nicht zugestimmt hat, kann es in dieser Sitzung nicht (Aufnahme läuft für die Gedeckten weiter). Ein Worker-Neustart verliert die Session-Historie (RAM-only); persistierte Zustimmungen sind davon nicht betroffen. Der Widerruf regelt die Zukunft und den ungeflushten Puffer — **bereits geflushtes Material bleibt liegen** (Art. 7 Abs. 3 berührt die bisherige Rechtmäßigkeit nicht); ein Lösch-Pfad ist eigenes Thema. (Die dritte #1005-Grenze — Ansagen gebaut, aber unverdrahtet — ist seit #1013 geschlossen, s.u.)

**Beitritts-Ansagen verdrahtet (#1013).** Die drei #1005-Texte (`text_for_join/1`, `text_for_pending/1`, `text_for_granted/1`) werden jetzt gesprochen. Arbeitsteilung in drei Modulen: **`AnnounceQueue`** (pure — WAS gesagt werden darf: Begrüßungs-Dedup, Erinnerungs-Deckel, FIFO+`push_front`), **`Announcer`** (WANN/WIE — Debounce, TTS-Task, `Voice.play`-Auswertung, Drain; kein eigener Prozess: die Funktionen nehmen den Session-State und geben ihn zurück, die Timer-Nachrichten landen weiter bei der `VoiceSession`, deren `handle_info`-Klauseln delegieren), **`Announcement`** (pure Texte + piper). Entscheidungen, alle benannt: **Namen kommen aus dem `member`-Objekt des `VOICE_STATE_UPDATE`** (Server-Nick vor `global_name` vor Login-Name — kein HTTP-Call, kein privilegierter Intent; Discord garantiert das Feld nicht → Namens-Cache behält den letzten bekannten, Fallback Hub-`display_name`, sonst namenlose Fassung). **Begrüßung nur beim ERSTEN Beitritt pro Person und Session** (Reconnect = Leave+Join im Minutentakt — ohne Dedup eine Begrüßungsschleife; wer beim Bot-Join schon da war, gilt als begrüßt, die #989-Ansage spricht den Raum). **Pending-Bitte nur bei Bedarf** (jemand ohne gültigen Consent anwesend — geprüft gegen Session-Historie UND persistierten Consent), **debounced 10 s zur Sammelform** („A, B und C haben … noch nicht zugestimmt"), **Deckel 2 Erinnerungen pro Person** (ein fremder Bot kann nie zustimmen — sonst Nag-Loop); beim Feuern wird Anwesenheit + Consent RE-geprüft (niemand wird erinnert, der weg ist oder längst zugestimmt hat — der real gemeldete Ärger). **Granted-Bestätigung nach dem Klick** („X hat der Aufnahme zugestimmt"). **`Voice.play/4`-Rückgabe wird ausgewertet** — die busy-Ablehnung (Fehler-STRING, Substring-Match mit benanntem Risiko) legt das Item an den Queue-Kopf zurück statt es still zu verlieren (der in #1005 benannte Silent-Failure-Generator ist damit zu); TTS läuft im supervisten Task (piper braucht Sekunden, der Session-Prozess nimmt 50 Casts/s/Sprecher). Die Queue läuft erst ab `listening?` — die #989-Erst-Ansage behält ihre eigene Kette und ihren Vorrang. Beim God-Module-Split fiel zusätzlich **`NostrumSafe`** ab (best-effort-Kapselung aller Voice-Aufrufe: `ready?`/`playing?`/`ssrc_map`/`leave_channel`/`me_did`/`play_url` — ein Nostrum-Fehler degradiert zu neutralem Rückgabewert statt Session-Crash). Die beiden Quelltext-Wächter (State-Felder, Timer) scannen seitdem VoiceSession UND Announcer (Delegation = gleiche Crash-Loop-Invariante; Gegenprobe im Test). Ehrliche Grenzen: ob die Ansagen im echten Kanal hörbar und richtig getaktet sind, prüft erst #1019 (Live-Verifikation); die busy-Erkennung hängt an Nostrums Fehler-Wortlaut (Wortlaut-Änderung ⇒ Item wird verworfen statt wiederholt — sichtbar im Log, nicht still).

**Historie (#1002, von #1005 überholt).** #1002 führte die Einwilligung überhaupt ein: gesprochener Satz, ausgewertet in einem globalen 45-Sekunden-**Fenster** nach dem Bot-Join (Vorbild war die Mikro-Setup-Prüfung #400, wo man ein Filmzitat spricht). Beide Bausteine des Ansatzes sind mit #1005 ersetzt — das Fenster durch die Zeitachse pro Sprecher, der Sprechakt durch den Klick —, weil der erste Live-Lauf zeigte, dass das Fenster kurze Sessions leert und Late-Joiner ausschließt und dass akustische Zustimmung nicht identitätsgebunden ist. Die Bausteine der Sprach-Auswertung (`ConsentPhrase.evaluate/1` mit Negations-Veto über Wortstämme, `ConsentCheck`, `Transcribe.transcribe_clip/1`) sind erhalten und getestet, aber nicht verdrahtet; sie sind die Grundlage für einen späteren Sprach-**Auslöser** (Satz → Nachfrage → Klick bestätigt). **Der Fund, der bleibt:** `HubWeb.CampaignLive.Mic.phrase_match?/2` ist ein Bag-of-Words-Match mit 60 %-Schwelle — bei Soll „ich stimme der Aufnahme zu" liefert „ich stimme der Aufnahme **nicht** zu" **100 % Match**. Für einen Mikro-Test ist diese Toleranz richtig, für eine Einwilligung fatal; ein Test baut die tolerante Logik nach und pinnt den Unterschied gegen späteres Zusammenlegen.

**Warum eine EIGENE Match-Logik** (der zentrale Fund): `HubWeb.CampaignLive.Mic.phrase_match?/2` ist ein Bag-of-Words-Match mit 60 %-Schwelle (MapSet, Reihenfolge egal, Zusatzwörter irrelevant) — bei Soll „ich stimme der Aufnahme zu" liefert „ich stimme der Aufnahme **nicht** zu" damit **100 % Match**, eine Ablehnung würde als Zustimmung zählen. Für den Mikro-Test ist die Toleranz richtig, für Einwilligung fatal. `ConsentPhrase` prüft deshalb **erst** ein Negations-Veto (über Wort**stämme**, nicht exakte Wörter — eine exakte Liste ließ prompt „keinesfalls" durch), **dann** den Zustimmungs-Match, und liefert `:granted | :declined | :unclear`. Nur `:granted` erlaubt Speichern; die Übervorsicht ist gewollt (falsches `:granted` = Aufzeichnung gegen den Willen, § 201 StGB; falsches `:unclear` = ein zweiter Versuch). Ein Test baut die tolerante Logik nach und pinnt den Unterschied gegen späteres Zusammenlegen.

**Durchsetzung + Speicher:** `Worker.Discord.ConsentGate.allow?/2` (pure, eigenes Modul — die `VoiceSession` ist ohne echten Nostrum-Bot kaum testbar) entscheidet an genau EINER Stelle in `handle_clip`, ODER-verknüpft aus (1) dem Urteil dieses Fensters — es zählt sofort, weil das `AudioConsentRecorded`-Event den Weg über den Hub noch nicht zurückgelegt hat und eine kurze Session sonst fälschlich verwerfen würde — und (2) dem persistierten Consent (`worker_audio_consents`, gekeyed auf `discord_id`, Max-Version-Lattice #824) — **nur wenn dessen Version zum aktuellen Wortlaut passt** (`ConsentGate.version/0` — bis #1032 lag die Konstante in `Worker.Recording.ConsentPhrase`, das Modul gibt es nicht mehr; verglichen über `Materializer.version_rank/1`): ändert sich, worin eingewilligt wird, zählt eine ältere Zustimmung nicht mehr und es wird neu gefragt. Ohne diese Prüfung wäre die Versionierung Dekoration (geschrieben, nie ausgewertet) — ein Test pinnt zusätzlich das `v<n>`-Format, weil `version_rank/1` sonst still 0 liefert und die Prüfung lautlos aushebelt. **Derselbe Speicher wie der Browser-Mikro-Pfad**: wer dort zugestimmt hat, muss im Voice-Kanal nichts sagen, und ab dem zweiten Spielabend wird niemand mehr gefragt. Fehlt die Zustimmung, wird die Spur verworfen und das **sichtbar** gemacht (`/admin/errors`, Stage `discord_consent`, Klasse `consent_missing`) — eine fehlende Spur ist für den GM wichtige Information, kein stiller Verlust. **Seit #1046 nennt diese Meldung auch den richtigen Weg**: sie riet sechs Wochen lang dazu, der Sprecher möge „den in der Ansage genannten Satz sprechen“ — ein Weg, der mit #1005 ausgesetzt wurde. Wer ihr folgte, verlor die nächste Spur ebenfalls, und las das ausgerechnet dann, wenn schon eine verworfen war. `consent_texte_test.exs` bewacht seitdem alle Einwilligungs-Texte gegen diesen Rückfall (gegengeprüft). Die Aufnahme der anderen läuft weiter (Alternative wäre, dass eine AFK-Person den Spielabend blockiert).

**Prod-Crash-Loop beim ersten Live-Lauf (Hotfix, Lehre):** `begin_listening/1` schrieb `%{state | consent_timer: ref}`, aber `init/1` legte das Feld nie an — Map-Update-Syntax wirft bei fehlendem Key ein `KeyError`, der GenServer starb, `restart: :transient` startete ihn neu, `init` jointe erneut und spielte die Ansage: **die Ansage lief im Voice-Kanal endlos in Schleife.** Die Tests konnten das nicht fangen, weil sie die pure Logik prüfen und die `VoiceSession` ohne echten Nostrum-Bot nicht startbar ist. Fix: der State-Aufbau ist jetzt die pure Funktion `VoiceSession.initial_state/3`, und ein Test liest den Quelltext, sammelt alle per `%{state | …}` geschriebenen Keys und vergleicht sie gegen die angelegten — er fängt damit auch künftige Felder, nicht nur `consent_timer` (Gegenprobe: ohne den Fix wird er rot und nennt das Feld). **Regel für dynamisch aufgebaute GenServer-States: jedes Feld, das eine Klausel per Map-Update schreibt, MUSS im initialen Aufbau stehen.**
**Live-Präsenz im Hub (#988).** Neben den Aufnahme-Buttons zeigt die CampaignLive die Teilnehmer des Voice-Channels als Avatar-Leiste: **farbig** = Einwilligung liegt vor, die Spur wird gespeichert, und **pulsierend**, solange die Person spricht; **grau + roter Balken** = keine Einwilligung, die Spur wird verworfen. Die Anzeige liest denselben `ConsentGate.allow?/2`-Zustand, nach dem auch `handle_clip` handelt — sie verspricht also keinen Ausschluss, den es nicht gibt. Der Tooltip trägt die Aussage zusätzlich in Worten (Farbe allein ist kein zugängliches Signal).

Zwei Signal-Quellen, beide **öffentliche** Nostrum-API (kein Zugriff auf `connected_clients` o.ä. Interna, die beim nächsten Dependency-Update still brechen): Anwesenheit über das dokumentierte `:VOICE_STATE_UPDATE`-Consumer-Event plus das `voice_states`-Feld der Guild-Struct als Anfangsbestand beim Join (`:VOICE_STATE_UPDATE` kommt nur für Änderungen — ohne den Snapshot bliebe die Leiste leer, bis jemand den Kanal wechselt). Sprechen aus dem Paketstrom: **es gibt kein brauchbares Sprech-Event** — `VOICE_SPEAKING_UPDATE` meldet laut Nostrum-Doku ausschließlich den Bot selbst. Stattdessen sendet Discord pro Sprecher nur *während* gesprochen wird (dieselbe Eigenschaft, auf der die #985-Zeitkorrektur aufbaut), und Nostrums Doku benennt die SSRC→User-Zuordnung ausdrücklich als vorgesehenen Weg dafür. Ein Paket heißt also „spricht jetzt", mit 400 ms Nachlauf gegen Flackern zwischen Silben. **Gedrosselt auf 5 Hz** (`Worker.Discord.Presence.tick_ms/0`): Nostrum beziffert den Strom auf „about 50 events per second per speaking user", ein Broadcast je Paket würde die LiveViews fluten. Die Zustandsberechnung liegt pur in `Worker.Discord.Presence` (ohne Nostrum/GenServer testbar, Muster `ConsentGate`).

**Einwilligung macht zum Mitspieler (#988).** Wer im Voice-Kanal einwilligt und noch kein Mitglied ist, wird als `:spieler` aufgenommen (`Worker.Discord.AutoMember`): `UserUpserted` trägt Name + Avatar ein (von der Discord-API geholt — die Person war womöglich nie im Hub eingeloggt), `AdminMemberAdded` legt die Member-Row an. Beide Folds bewahren `avatar_url`/`joined_at`, die Reihenfolge ist deshalb egal (#879-Klasse). Produktentscheidung: wer im Voice-Channel sitzt, wurde ohnehin auf den Discord-Server eingeladen — will der GM ihn nicht dabeihaben, entfernt er ihn nachträglich, statt jeden Spielabend einen Bestätigungs-Schritt zu blockieren. Damit entfällt im UI ein eigener „Gast"-Zustand. Idempotent (ein Spielleiter wird **nicht** auf `:spieler` zurückgestuft) und best-effort: scheitert der Discord-Profil-Abruf, bleibt die Discord-ID als Anzeigename — ein Mitglied ohne schönen Namen ist besser als ein verlorener Teilnehmer (der Name korrigiert sich beim ersten Hub-Login). `added_by` trägt den Spielleiter; die tatsächliche Herkunft steht im zeitgleichen `AudioConsentRecorded`-Event.

**Historisch (#1002-Grenzen, von #1005 aufgehoben — nicht mehr gültig):** dieser Absatz nannte drei Lücken, die es nicht mehr gibt: „Widerruf wirkt nicht", „Late-Joiner werden nicht gefragt", „wer im Fenster schweigt, verliert seine Spur". #1005 hat alle drei geschlossen (persistierter Widerruf mit LWW-Konvergenz, Klick statt Sprechakt, Fenster ersetzt durch die Zeitachse pro Sprecher — s.o.). Der Absatz stand nach dem #1005-Merge noch da und behauptete das Gegenteil des gebauten Zustands; er ist bewusst als Historie erhalten statt gelöscht, weil er sonst in einer späteren Session als „ungelöst" wieder auftaucht.

**Sprachansagen (Issue #1032): der Bot spricht nur, wenn es etwas zu klären gibt.** Die Eröffnung hängt die Einwilligungs-Bitte nicht mehr unbedingt an, sondern nennt die Offenen beim Namen (oder schweigt dazu, wenn alle zugestimmt haben); die Beitritts-Ansage spricht den Betroffenen direkt an und nennt den Weg („Du musst der Verarbeitung im Chat zustimmen"); die Erinnerung kommt 60 s nach dem letzten Beitritt, maximal 3× und nennt nur noch Namen — jeder Beitritt setzt Timer UND Zähler zurück. Rund 24 statt 65 s Redezeit in einer typischen Sitzung. Der seit #1005 stillgelegte gesprochene Zustimmungs-Pfad (`ConsentPhrase`/`ConsentCheck`) ist **entfernt**; die Consent-Version wohnt jetzt in `Worker.Discord.ConsentGate.version/0`, weil das Gate sie durchsetzt. **Cue-Tabelle, Timer-Semantik, Ablauf-Diagramm und Redezeit-Vergleich: `docs/Discord-Ansagen-Flow.md`.**

**Pause hält auch den Bot an (Issue #1058).** Bis dahin lief die Aufzeichnung
während der Pause weiter: der Browser-Mikro-Pfad endet an der Quelle, der Bot
hängt dagegen am **Kanal**, nicht am Aufnahme-Zustand — er blieb sitzen,
pufferte und schrieb jede Minute weg, während die Oberfläche „pausiert" zeigte.
Im Mitschnitt landete damit genau das, wofür der Knopf gedacht ist: das
Gespräch über Arbeit, Privates, den nächsten Termin. Die Einwilligung deckt die
**Spielsitzung**; ob sie das Pausengespräch deckt, ist mindestens fragwürdig.

Der Zustand lebt in der Sitzungszeile (`RecordingStateChanged`-Fold) — **der
Recorder kennt ihn nicht**, es gibt also niemanden, der ihn an die Voice-Sitzung
reichen könnte. Sie hört deshalb selbst mit (`Worker.Materializer.topic()`,
Muster `Pipeline.Dirty`) und filtert auf die eigene `session_id`. Vier
Entscheidungen dabei:

- **Verworfen wird am PAKET**, nicht am Wegschreiben. Gepuffert und später
  weggeworfen läge das Pausengespräch minutenlang im Speicher, und ein Absturz
  oder ein Flush dazwischen schriebe es weg.
- **Beim Anhalten wird das laufende Fenster noch geflusht** — alles bis dahin ist
  gedeckte Aufnahme und im Puffer nur verlierbar. Erst danach greift die Sperre.
- **Beim Fortsetzen beginnt ein frisches Fenster** (`window_start_ms` auf jetzt).
  Ohne das trüge der erste Clip die ganze Pause als führende Stille, weil
  `FrameBuffer.rebase/2` von `window_start_ms` an auffüllt.
- **Die `{:applied, _}`-Auffangklausel ist Pflicht**: das Abo liefert jedes
  angewendete Ereignis, und der Catch-all schreibt eine `Logger.warning` — ohne
  sie flutete jeder Mitschnitt das Log. Beide Klauseln stehen VOR dem Catch-all
  (#1009-Lehre), ein Test pinnt die Reihenfolge.

**Der Bot bleibt im Kanal und sagt beides an** (Tom, 18.09.): „Die Aufnahme ist
angehalten." / „Die Aufnahme läuft wieder." Verlassen und Neubetreten liefe
erneut durch die als fragil bekannte Empfangskette (#1050); und wer im
Sprachkanal sitzt, sieht die Weboberfläche nicht — ohne Ansage wäre für die
Runde nicht unterscheidbar, ob aufgezeichnet wird. Dieselbe Begründung wie bei
der Beitritts-Ansage, und derselbe Maßstab: ein Satz, der den Zustand sagt,
nicht die Bedienung. Der folgende Absatz beschreibt den Stand davor.

**Gesprochene Consent-Ansage beim Join (#989).** Der Bot betrat den Kanal bis dahin lautlos — außer dem GM wusste niemand, dass aufgezeichnet wird (der Browser-Mic-Pfad hat mit `AudioConsentRecorded` ein Äquivalent, der Discord-Pfad hatte keins). Jetzt sagt er beim Beitreten hörbar an: „Der Lorspai hat den Kanal betreten und nimmt die Sitzung für die Kampagne **X** auf." (**„Lorspai" ist kein Tippfehler**, sondern phonetische Schreibweise für die TTS — Live-Fund: „LoreSpy" wurde deutsch als „Schpei" gesprochen, weil `sp-` am Wortanfang im Deutschen zu „schp" wird, in der Wortmitte nicht. Lautschrift wäre sauberer, geht aber nicht: piper interpretiert espeak-`[[…]]`-Phoneme nicht, sondern liest sie vor.) Seit #1002 folgt die Bitte um Einwilligung im selben Atemzug (Wortlaut aus `ConsentPhrase.canonical_phrase/0`, s.o.). **Der Kampagnenname macht die Ansage dynamisch** — deshalb Laufzeit-TTS statt einer vorgenerierten Datei im Repo, und deshalb ist **piper** (lokales neuronales TTS) die dritte externe Binary des Workers neben `whisper-cli`/`ffmpeg` (`piper_bin` + `piper_model` als `:no_default`-Settings, #784-Muster; beide leer = keine Ansage). Erzeugt wird **einmal pro Text**, nicht pro Join (`Worker.Discord.Announcement`, Cache-Key = Hash über den fertigen Ansagetext, Datei unter `<mnesia_dir>/tts/` — dieselbe per-Worker-Ableitung wie `audio_dir` seit #948; Kampagne umbenannt → neuer Hash → neue Datei). **`self_mute` ist jetzt `false`** (vorher `true`, „Bot sendet nie eigene Audio") — ein gemuteter Client kann nicht sprechen; bewusst dauerhaft nicht-gemutet statt nach der Ansage zurückzuschalten (ein zweiter `join_channel/4` auf einer laufenden Verbindung wäre ein Risiko für den als fragil bekannten Empfangspfad). Reihenfolge: join → settle → **Ansage → warten bis fertig → dann `start_listen_async`** (Einwilligung vor Aufzeichnung; die eigene Ansage kann so nicht im Mitschnitt landen), Poll-Kette statt blockierendem Warten, hart gedeckelt (`@announce_max_ms` 30 s — wird die Voice-Verbindung nie bereit oder `playing?` nie false, wird lieber ohne Ansage aufgezeichnet als gar nicht). Der GM kann sie **nicht abschalten** (Consent ist kein Feature-Schalter). Der GM-getippte Kampagnenname geht in einen Subprocess-Aufruf: er wird normalisiert + auf 80 Zeichen gedeckelt, und erreicht piper **über eine Datei auf stdin, nie über die Kommandozeile** (piper nimmt Text nur auf stdin, `System.cmd/3` kann kein stdin füttern → `sh -c '… < textfile'`; Shell-Injection über Kampagnennamen ist im Test mit fünf Angriffs-Varianten + Canary-Datei gepinnt).

**Vier Live-Befunde nach dem ersten echten Spielabend (#1011 + #1009 + #1008 + #1007, eine PR).**

**#1011 — der Kern: die Stop-Reihenfolge war vertauscht.** `Recorder.handle_call({:stop, …})` finalisierte den `AudioBuffer` **vor** dem Stoppen des Bots. Weil der einzige Schreibpfad des Bots `flush_frames/1` aus `VoiceSession.terminate/2` ist, kam Discord-Audio damit **garantiert** nach dem Finalize an (`files=0` → kein Transcribe-Task → keine Pipeline). Dass überhaupt Transkripte entstanden, lag allein am Late-Append-Notpfad #949, der die beendete Session wieder aufmacht — im Prod-Log dreimal in Folge belegt. Ein Notfallnetz als Regelpfad. Fix ist der Tausch der beiden Zeilen: `terminate_child/2` ist synchron, die `append`-Casts der Session liegen bei seiner Rückkehr schon in der AudioBuffer-Mailbox, `finalize` wird erst danach gesendet und landet dahinter (dass `terminate/2` überhaupt läuft, hängt am `trap_exit` aus #987). Ein Quelltext-Wächter pinnt die Reihenfolge (`recorder_stop_order_test.exs`, gegenbewiesen). **Das Stop-Timeout-Budget hängt daran:** `stop_for_campaign/1` ist ein `GenServer.call`, und der Flush läuft synchron darin — solange er läuft, ist der Recorder für JEDEN anderen Call blockiert (ein `start_for_owner/3` einer zweiten Kampagne stünde dahinter und liefe selbst ins Timeout). Die früheren 10 s waren nie mit ffmpeg-Arbeit im Blick gewählt; sie sind jetzt 60 s. Der eigentliche Grund, warum das reicht, ist #1009 (Flush-Menge auf ein Fenster begrenzt statt auf die ganze Sitzung) — bewiesen ausreichend ist es nicht, deshalb **loggt jeder Flush seine Dauer** und warnt ab 5 s (`VoiceErrors.log_flush_duration/3`). Ein Timeout wäre übrigens nicht der Verlust des Mitschnitts: der Recorder arbeitet den Stop vollständig ab, nur die Antwort geht ins Leere — es entstünde ein Crash-Report, der wie ein Datenverlust aussieht, obwohl das Audio heil ist.

**Nachtrag #1053 (17.09.2026): die 60 s galten nie — und die Warnung darüber konnte nie feuern.** Die Frist oben ist die Wartezeit des **Aufrufers**. Das tatsächliche Budget setzt der Supervisor, und die `child_spec` der `VoiceSession` trug keinen `shutdown:`-Eintrag — es galt der OTP-Vorgabewert von **5000 ms**, danach harter Kill mitten im Flush. Verloren ging dabei bis zu ein volles Fenster **aller** Sprecher, am Ende jeder Aufnahme, sichtbar nur als fehlende Minute im Protokoll. Die im selben PR gebaute Frühwarnung (`log_flush_duration/3`, ab `discord_flush_slow_ms` = 5 s) hing an derselben Annahme: Bei 5 s war der Prozess bereits tot, die Zeile also unschreibbar. Beide Hälften des Fixes waren damit wirkungslos, und das fiel sechs Wochen lang niemandem auf, weil ein stummer Wächter wie Ruhe aussieht (s. „Ein Wächter, der nie anschlägt, ist unbewiesen"). Seit #1053 setzt die `child_spec` `shutdown: discord_flush_shutdown_ms` (Default **30 s**) — grosszügig gegen den gemessenen Normalfall (ein Sprecher ~0,45 s je 60-s-Fenster, fünf Sprecher gut 2 s) und klein genug, dass der AudioBuffer-Finalize im 60-s-Budget des Aufrufers noch Platz hat. Die Warnschwelle liegt damit erstmals **unter** der Kill-Frist; `voice_session_shutdown_test.exs` hält genau diese Ordnung fest (gegengeprüft: ohne `shutdown:` wird er rot).

**#1009 — die ganze Sitzung lag im RAM eines GenServers.** `state.frames` wuchs bis zum Stop; ein `kill -9`, ein OOM oder ein Stromausfall kostete den kompletten Abend. Jetzt wird periodisch geflusht (`:flush_tick`, `discord_flush_interval_ms`, Default 60 s). Getragen wird das von zwei bestehenden Mechanismen, statt einen Zwischenspeicher zu erfinden: der Clip jedes Fensters trägt einen frischen EBML-Header → `AudioBuffer.write_chunk/6` rotiert auf ein eigenes Segment (#469), und `ChunkManifest` (#757) gibt jedem Segment seinen eigenen Zeitanker. **Die Zeitbasis ist fenster-relativ** (`FrameBuffer.rebase/2`) — und das ist keine Bequemlichkeit: „Sekunde 0 des Clips IST der Fensterbeginn" ist genau die Zusage, auf der der Zeitanker sitzt (s. #1060 unten); eine pro Sprecher über die Fenstergrenze „lückenlos weitergeführte" Spur begänne früher und wäre damit aktiv falsch, nicht bloß unnötig. Der Fensterschnitt ist pure (`FrameBuffer.split_window/2`, Grenze exklusiv, damit ein Frame auf der Kante in genau einem Fenster landet). Nebenwirkung: die #469-Rotationswarnung erscheint jetzt einmal pro Fenster und Sprecher (kosmetisch, aber Log-Rauschen). **Die damalige ehrliche Grenze — Anker = Fenster-Ende, ein früh verstummender Sprecher landet um bis zu eine Fensterlänge zu spät — ist mit #1060 aufgehoben** (s. dort); der Absatz stand hier zwei Wochen als „gedeckelt, nicht behoben".

**#1008 — „Aufnahme lief, kein Transkript" war ein stiller Totalverlust.** Ursache dieses Vorfalls war #1011; das Symptom-Ticket ist damit erledigt, aber „behoben" ist keine Zusicherung, dass der als fragil bekannte Empfangspfad nie auf andere Weise nichts liefert. Deshalb wird der Ausgang jeder Aufnahme jetzt aktiv bewertet, statt auf den nächsten Zufallsfund zu warten — drei vorher nur geloggte Ausfälle sind jetzt Fehlerklassen in `/admin/errors` (Stage `discord_voice`): `no_frames_captured` (kein einziges Paket empfangen — typisch serverseitig stummgeschalteter Bot), `unresolved_ssrc_frames` (Audio kam an, aber kein Paket war zuordenbar — typisch nach Voice-Reconnect) und `clip_build_failed` (ffmpeg/Decode). Bewusst nur **eindeutige** Totalausfälle: der Teilausfall bleibt eine Log-Warnung, weil einzelne unauflösbare Frames normal sind (~200 ms zu Sprechbeginn) und jede Schwelle darüber erfunden wäre. Die Klassifikation ist pure (`VoiceSession.capture_outcome/2`). Nachgezogen: die Discord-Fehlerklassen hatten in `/admin/errors` **nie** ein `type_label` und standen als roher Code in der Liste.

**#1007 — die Avatar-Leiste blieb nach dem Stop stehen.** Die Präsenz-Liste ist ephemer und wird nur *gesetzt*, solange der Worker sendet; nach dem Stop hörte er auf und der letzte Stand blieb im Assign — die Leiste behauptete weiter „diese Leute sitzen im Kanal und werden aufgezeichnet". Das Gate hängt jetzt an der aktiven Session und sitzt in der Komponente selbst, nicht im Aufrufer (robuster als das Leeren des Assigns: es gilt auch für einen frisch gemounteten Betrachter, bei verlorener Abschlussmeldung, und es verhindert das Aufblitzen der alten Avatare beim Start der nächsten Session). In der **Pause** bleibt die Leiste sichtbar — der Bot bleibt im Kanal.

**Der Zeitanker zeigt vorwärts (#1060).** Ein Sidecar-Eintrag (`ChunkManifest`, #757) sagt „bei diesem Byte-Stand war es diese Uhrzeit" — offen bleibt, ob die Uhrzeit den **Anfang** oder das **Ende** des Stücks meint. Für den Browser-Mic ist es das Ende (der Wall-Clock ist die Ankunft der Chunk, alle ~500 ms eine), für den Discord-Bot war dieselbe Lesart **doppelt falsch**: pro Flush-Fenster entsteht EIN Clip je Sprecher, der beim **letzten Wort dieses Sprechers** endet (nicht am Fensterende — `rebase/2` füllt nur führende Stille auf), und geschrieben wird er hinter Mux + zwei ffmpeg-Läufen **je Sprecher, nacheinander**. Folge: wer früh im Fenster verstummte, rutschte um den Rest des Fensters nach hinten — und weil der Versatz pro Sprecher anders ausfiel, zerstörte das Verankern genau die sprecherübergreifende Ausrichtung, die `FrameBuffer` innerhalb des Fensters herstellt (Antwort vor Frage; dieselbe Symptomklasse wie Real Seattle S1 auf dem Browser-Pfad, dort mit #757 behoben). Jetzt trägt jede Manifest-Zeile ihre **Anker-Richtung** (`"a":"s"` = Start; fehlend = Ende, jeder Bestands-Sidecar behält damit seine Bedeutung), `AudioBuffer.append/6` nimmt `wall_clock_ms` + `anchor` entgegen (ohne Angabe unverändert), und der Flush-Pfad gibt den **Fensterbeginn** mit (`Worker.Discord.Flush.window_start_wall_ms/1`, pure — die Wall-Clock des Sessionbeginns wird einmal in `initial_state/4` neben der monotonen Basis erhoben). Nebeneffekt: beim Vorwärts-Anker kürzt sich `decoded_ms` (Whispers Längen**schätzung**, `max(segment.end_ms)`) aus der Rechnung heraus — der Zeitstempel ist exakt Fensterbeginn + Whisper-Offset. Damit ist die Fensterlänge (#1009) keine Genauigkeits-Achse mehr, nur noch Absturz-Verlust vs. Dateizahl. Ein Quelltext-Wächter (`voice_session_anchor_test.exs`) hält die beiden Optionen am Aufruf fest — ohne sie wäre alles wieder falsch, ohne dass ein Test rot wird. **Ehrliche Grenze:** die Ausrichtung ist so gut wie die Ankunftszeit der Pakete beim Worker (`FrameBuffer`-Achse) — Netz-Jitter unter 100 ms bleibt unsichtbar, und ein Frame, der lange nach seinem Fenster eintrifft, wird im nächsten Fenster verrechnet.

**Gateway-Verbindung ist ein Zustand, kein Boot-Ereignis (#1076).** Der Bot startete nach einem Boot ohne DNS **nie mehr**. `Worker.Application.discord_bot_child/0` nahm `Nostrum.Bot` nur auf, wenn `BotToken.usable?/0` beim Boot `true` lieferte — und das ist ein HTTPS-Call, der bei Netzfehlern fail-closed war. Real am 2026-08-18: der Worker startete Sekunden vor dem DNS (vier `:nxdomain`-Fehlversuche des HubClients, erste Verbindung vier Sekunden später). Der HubClient verträgt das, weil er reconnected; die Discord-Vorprüfung kannte keinen zweiten Anlauf. Folge: kein Bot-Child, kein Gateway, bis zum nächsten Neustart — und **unsichtbar**, weil `/settings` den Token weiter als gesetzt zeigte und `/admin/errors` leer blieb (der Fehler liegt VOR dem `VoiceSession`-Prozessstart, die #985-Stage-D-Grenze). Sichtbar wurde er erst als `:discord_unavailable` beim Aufnahme-Start.

Drei Änderungen, die zusammen den Zustand tragen:

- **`BotToken.check/0`** ersetzt das kollabierte Boolean durch `:ok | :no_token | :rejected | {:network_error, _}`. Nur **401/403** sind `:rejected` (Dauerzustand, kein Retry); **429 und 5xx sind ausdrücklich keine Ablehnung** — sie so zu behandeln hieße, wegen einer Discord-Störung dauerhaft aufzugeben. Die Abbildung liegt pur in `BotToken.classify/1` (ohne Netz testbar), `usable?/0` bleibt als Boolean-Fassade für die Ja-Nein-Aufrufer.
- **`Worker.Discord.BotGate`** (GenServer) hält den Zustand: `:ok` → Bot starten, `{:network_error, _}` → Backoff-Retry (5 s bis gedeckelt 5 min, unbegrenzt — wie der HubClient-Reconnect), `:rejected`/`:no_token` → Leerlauf mit **lokalem** Token-Poll (Settings/ENV, kein HTTP; erst eine Änderung löst eine neue API-Prüfung aus, ein abgelehnter Token erzeugt also keinen Verkehr). Damit erledigt sich nebenbei die frühere Nebenwirkung *„Token-Änderung in /settings wirkt erst nach Worker-Neustart"*. Stirbt der Bot, sieht das Gate den `:DOWN` und fängt von vorn an.
- **`Nostrum.Bot` hängt unter `Worker.Discord.GatewaySupervisor`** (eigener `DynamicSupervisor`, Kind mit `restart: :temporary`) statt als statischer Top-Level-Child. Das war der ursprüngliche Grund für die Vorprüfung: ein Fehlstart propagierte nach oben und riss den ganzen Worker-Boot mit (#985, empirisch gefunden). Dort liefert er jetzt `{:error, reason}` an den Aufrufer. `:temporary` ist Absicht — mit `:permanent` gäbe es zwei konkurrierende Wiederbelebungs-Mechanismen, die sich die Backoff-Rechnung verderben. Der `BotSupervisor` daneben bleibt für die per-Kampagne-`VoiceSession`s: zwei Lebenszyklen, zwei Supervisor.

**Sichtbarkeit:** `BotGate.status/0` liest aus `worker_state` und ruft **nie** den GenServer (der Snapshot-Pfad darf nicht hinter einem laufenden 5-Sekunden-HTTP-Call warten, Muster `pending_publish_count` #475). Der Zustand reist als `discord_gateway` im Settings-Snapshot und steht in `/settings` **neben** dem Token-Status — beides zu verwechseln war die Ursache dafür, dass der Ausfall tagelang unbemerkt blieb. `"connected"` wird **nur** aus der `:READY`-Klausel des Consumers gesetzt: ein gestarteter Bot-Prozess ist noch keine Gateway-Session, und genau diese Verwechslung hätte den Vorfall verschleiert. Ehrliche Grenzen: kein periodischer Gültigkeits-Ping gegen ein laufendes Gateway (ein serverseitig widerrufener Token fällt erst auf, wenn der Bot deswegen stirbt); der Zustand liegt in `worker_state` und kann nach einem harten Absturz kurz als Altwert stehen, bis `init/1` ihn überschreibt.

**Der Empfang wird nach JEDEM Handshake neu scharfgeschaltet (Issue #1050).** Nostrum öffnet den Empfangs-Socket bei jedem Voice-Handshake neu und **passiv** (`Audio.open_udp/0` mit `{:active, false}`, im `:ready`-Zweig von `voice/event.ex`); scharf schaltet ihn allein `Voice.start_listen_async/1`. Der lief bis #1050 **genau einmal** — in `begin_listening/1` beim ersten Beitritt, Rückgabewert verworfen. Nach einem Reconnect (Discord-Wartung, Netz-Schluckauf, ein Moderator verschiebt den Bot) lag damit ein neuer, tauber Socket da: **kein einziges Paket mehr, für den Rest des Abends, ohne Log, ohne Eintrag, ohne Zeichen in der Oberfläche.** Der Bot saß weiter im Kanal, die Anzeige meldete weiter „Discord nimmt auf".

Seit #1050 hat der Consumer eine `:VOICE_READY`-Klausel (Nostrum dispatcht das Ereignis unmittelbar nach jedem Handshake, mit `guild_id`) und die Session einen Zweig, der neu scharfschaltet — mit drei Entscheidungen, die daran hängen:

- **Vor dem ersten Zuhören passiert nichts** (`handle_cast(:voice_ready, %{listening?: false})` ist ein No-op). Die reguläre Kette ist Ansage → `begin_listening/1`; hier schon scharfzuschalten kehrte die #989-Reihenfolge um und zeichnete auf, **bevor** die Einwilligungs-Ansage gelaufen ist.
- **Der Rückgabewert wird ausgewertet**, statt verworfen zu werden — das Verschlucken *war* der Defekt. `NostrumSafe.start_listen/1` ist deshalb die eine Kapselung dort, die den Fehler **weiterreicht**, statt ihn wie ihre Nachbarn zu einem neutralen Wert zu machen. Der erwartbare Fehlschlag (`{:error, "Must be connected…"}`) heißt „der Handshake war noch nicht ganz fertig" und wird im Abstand `discord_listen_retry_ms` (500 ms) bis zu dreimal wiederholt; bleibt er, ist es die Fehlerklasse `listen_rearm_failed` in `/admin/errors`. Die **Anzahl** der Anläufe ist bewusst keine Einstellung (#1062: die Liste soll eine Bedeutung behalten), der **Abstand** schon.
- **Das eigene Austritts-Ereignis wird nicht mehr verworfen.** Wird der Bot aus dem Kanal geworfen, verschoben oder der Kanal gelöscht, meldet Discord genau das — die Session prüfte „bin ich das selbst?" und tat dann bewusst nichts. Jetzt endet die Aufnahme **definiert**: Fehlerklasse `voice_channel_lost`, Puffer sichern (über `shutdown_sequence/1`), Stopp mit `:normal` — `restart: :transient` startet dann nicht neu, und ein Neustart wäre auch falsch, weil der Bot gerade nicht in den Kanal darf. Die `listening?`-Bedingung schützt dabei den Beitritt selbst, dessen Zwischenzustände sonst als Abriss gälten.

**Ehrliche Grenzen von #1050:** Dass Discord nach dem erneuten Scharfschalten real wieder Pakete liefert, ist **nicht am echten Server geprüft** — die automatisierten Tests decken die Verdrahtung und den Wiederholungs-Pfad ab, nicht die Wirkung; der Reconnect tritt in Prod nicht von allein auf (in 14 Tagen Produktionsprotokoll waren alle 39 Abbrüche das eigene Verlassen am Sitzungsende). Der Austritts-Zweig ist aus demselben Grund nur über einen Quelltext-Wächter abgesichert: er hängt an `NostrumSafe.me_did/0`, das ohne laufenden Bot `nil` liefert. Und das bereits gepufferte Fenster bleibt beim Abriss erhalten, die Zuordnung der Sprecher darin aber nur so weit, wie die `ssrc_map` zum Zeitpunkt des Empfangs trug.

**Ehrliche Grenzen:** kein aktiver Liveness-Check (nur Prozess-Crashes werden erkannt); eine Discord-Gateway-Session kann pro Guild nur einem Voice-Channel gleichzeitig beitreten (s.o., seit #987 laut statt destruktiv); `VoiceSession` ist RAM-only (Worker-Neustart verliert die Session ohne Re-Attach — seit #1009 ist der Audio-Verlust dabei auf ein Flush-Fenster begrenzt, die Session selbst wird weiterhin nicht wieder angeheftet). **Zur Ansage (#989):** scheitert sie (piper nicht eingerichtet, Binary/Modell kaputt), läuft die **Aufnahme weiter** und der Fehler ist sichtbar (`/admin/errors`, Klassen `tts_failed`/`announce_play_failed`/`piper_not_configured`, Stage `discord_ansage`) — dann zeichnet der Bot aber **ohne hörbares Signal** auf, das Consent-Ziel ist in diesem Fall verfehlt, nur eben sichtbar statt lautlos (bewusste Abwägung: Aufnahme am Spielabend abzubrechen, weil TTS fehlt, wäre schlechter). Für deutsche weibliche Stimmen gibt es bei piper nur `low`-Qualität (kein `medium`).

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
mix lore.seed.romeo --as-admin <discord-id> --display-name "<name>"
mix lore.seed.romeo --as-admin <discord-id> --mode protocol-only  # Resümee/Epos/Chronik leer (für LLM-Lasttests)
```

Refuses `MIX_ENV=prod`. Berührt nur die Kampagne `romeo-julia-demo` — kollidiert nicht mit echten Daten. Use Cases: Klick-Demos, LLM-Lasttests (vgl. #69 + `--mode protocol-only`), Onboarding einer fremden Claude-Code-Instanz (mit `--as-admin <eigene-discord-id>` ist der Caller sofort Owner+Admin der Romeo-Demo).

## Demo-Daten seeden (Die drei Musketiere — D&D, Issue #423)

Reproduzierbare D&D-Tisch-Kampagne, lose nach Alexandre Dumas, „Les trois mousquetaires" (1844, gemeinfrei seit 1940). 4 Sessions à 25-40k Wörter (≈ 100k Wörter total). **Nur Protokoll** — keine Resümees/Epos/Chronik in den Seeds, damit das LLM die als Stage 2-4 generiert (LLM-Eval-Fokus).

PCs: D'Artagnan (Rogue/Swashbuckler), Athos (Fighter/Champion), Porthos (Barbarian/Berserker), Aramis (Cleric/War). Alle NPCs (Tréville, Königin Anne, Cardinal Richelieu, Milady de Winter, Rochefort, Constance Bonacieux, Buckingham, Lord de Winter, Henker von Lille etc.) werden vom SL gespielt. Discord-IDs reserviert im `20000000000000000`-Range (Romeo nutzt `10000000000000000`, also kollisionsfrei).

```bash
mix lore.seed.musketiere                              # gegen http://127.0.0.1:4000
mix lore.seed.musketiere --hub http://127.0.0.1:4005  # PR-Test-Hub
mix lore.seed.musketiere --reset                      # erst CampaignDeleted, dann re-seed
mix lore.seed.musketiere --as-admin <discord-id>      # Caller als Owner+Admin
```

Refuses `MIX_ENV=prod`. Berührt nur `drei-musketiere-demo`. JSONL-Files unter `apps/hub/priv/seeds/musketiere/`, regeneriert via `elixir apps/hub/priv/seeds/musketiere/generator.exs` (deterministisch — fester `:rand`-Seed pro Session).

Use Cases primär: LLM-Stage-2/3/4-Eval (anderes Genre als Romeo — Mantel-und-Degen-Banter + OOC-Wechsel + Würfelproben statt Schlegel-Verse), Pipeline-Lasttest mit langen Sessions. Die Quelle (Dumas 1844) ist analog zur Schlegel-Übersetzung (1797) firmly Public Domain — Plot-Beats und Charakter-Namen aus dem Roman, Dialoge eigenständige deutsche D&D-Tisch-Kompositionen.

PCs: Edgin (Bard), Holga (Barbarin), Simon (Sorcerer), Doric (Druidin), Xenk (Paladin), Kira (Rogue, ab S3). Discord-IDs reserviert im `20000000000000000`-Range (Romeo nutzt `10000000000000000`, also kollisionsfrei).

```bash
mix lore.seed.ehre                              # gegen http://127.0.0.1:4000
mix lore.seed.ehre --hub http://127.0.0.1:4005  # PR-Test-Hub
mix lore.seed.ehre --reset                      # erst CampaignDeleted, dann re-seed
mix lore.seed.ehre --as-admin <discord-id>      # Caller als Owner+Admin
```

Refuses `MIX_ENV=prod`. Berührt nur `ehre-unter-dieben-demo`. JSONL-Files unter `apps/hub/priv/seeds/ehre/`, regeneriert via `elixir apps/hub/priv/seeds/ehre/generator.exs` (deterministisch — fester `:rand`-Seed pro Session).

Use Cases primär: LLM-Stage-2/3/4-Eval (anderes Genre als Romeo — D&D-Tisch-Banter + OOC-Wechsel + Würfelproben statt Schlegel-Verse), Pipeline-Lasttest mit langen Sessions, Tabula-Wiederbelebung als Plot-Strang den die Chronik konsistent abbilden muss.

## Demo-Daten seeden (Vox Machina — Critical Role, Issue #106)

Reproduzierbare D&D-Tisch-Kampagne, frei nach Critical Role Campaign 1 (Kraghammer-Bogen). 3 Sessions (Ep 1 Arrival at Kraghammer, Ep 2 Into the Mines, Ep 3 The Corruption Below). Campaign-ID `vox-machina-demo`, 7 Dummy-Spieler (Travis/Laura/Marisha/Taliesin/Liam/Ashley/Sam) + DM-Zeilen unter der `--as-admin`-Discord-ID.

```bash
mix lore.seed.vox_machina                             # gegen http://127.0.0.1:4000
mix lore.seed.vox_machina --hub http://127.0.0.1:4001 # PR-Test-Hub
mix lore.seed.vox_machina --reset                     # erst CampaignDeleted, dann re-seed
mix lore.seed.vox_machina --mode protocol-only        # ohne LLM-Output-Events (für Pipeline-Lasttests)
mix lore.seed.vox_machina --as-admin <discord-id> --display-name "<name>"
```

Refuses `MIX_ENV=prod` (Prod-Pfad: `scripts/seed_vox_machina_prod.exs` via RPC-Bridge, analog zum Romeo-Prod-Import). Berührt nur `vox-machina-demo`. JSONL-Files unter `apps/hub/priv/seeds/vox-machina/` (statisch committed, kein Generator-Script wie bei Musketiere/Ehre).

## Fidelity-Testset seeden (Ein Skandal in Böhmen — CoC/Gaslight, Issue #644)

**Treue-Testset, kein Klick-Demo.** Arthur Conan Doyle, „A Scandal in Bohemia" (1891, gemeinfrei), gespielt als Call-of-Cthulhu / BRP / Gaslight (mythos-frei, viktorianisches London 1888). Das Buch wird **abgebildet, nicht dazugedichtet** — Würfelausgänge an den Buch-Plot gekoppelt. Cast = Quell-Cast: Holmes + Watson (PCs), ein SL spricht alle NPCs (König von Böhmen / Wilhelm von Ormstein, Irene Adler, Godfrey Norton, Kutscher).

```bash
mix lore.seed.skandal                              # gegen http://127.0.0.1:4000
mix lore.seed.skandal --hub http://localhost:4001  # Teststage-Hub
mix lore.seed.skandal --reset                      # erst CampaignDeleted, dann re-seed
mix lore.seed.skandal --as-admin <discord-id>      # Caller als Owner+Admin
```

Refuses `MIX_ENV=prod`. Berührt nur `skandal-boehmen-demo`. JSONL-Files + Generator + Ground-Truth (`reference-summary.md`, `fact-key.json`) unter `apps/hub/priv/seeds/skandal-boehmen/`, regeneriert via `elixir apps/hub/priv/seeds/skandal-boehmen/generator.exs`.

Zweck: **reproduzierbares Stage-2-Treue-Testset** mit bekannter Referenz (automatisch ausgewertet wird es seit J4 nicht mehr — s. den nächsten Abschnitt). Testet zugleich (1) Regel-Noise-Filterung — die Proben (BRP-Skill-Checks) sind **diegetisch** an den Handlungspunkten platziert, nicht zufällig gestreut, und ein treues Resümee muss sie wegfiltern; (2) **Figur-aus-Kontext-Attribution** — der eine SL-Sprecher spricht alle NPCs, die Figur lebt nur im Text (kein Figur-Feld pro Utterance), das Resümee muss „der König sagt X / Irene sagt Y" korrekt zuordnen; (3) Faktentreue gegen `fact-key.json` (required_facts / attribution_facts / decoys / rule_noise_markers). Umfang bewusst **buchtreu statt 4-h-aufgebläht** (Doyle-Vorlage ~8,5k Wörter).

### ~~Treue-Scoring `mix lore.eval.summary`~~ (#647) und ~~Handlungsbogen-Eval `mix lore.eval.threads`~~ (#830/#837) — mit J4 (#1207) entfernt

Beide Befehle materialisierten das Fixture in eine frische Worker-Mnesia (`EvalBootstrap`) und trieben die **alte** Extraktion (`Stages.extract_facts`, samt Map-Reduce) und das Verify-Gate gegen den Fact-Key: `eval.summary` scorte das Resümee (`entity_recall`, `noise_leak`, optional ein nicht gegateter LLM-Judge), `eval.threads` die rohen Strang-Labels (`thread_recall`, `fragmentation`, `false_merge`, `false_resolve`); gegatet wurde gegen eine lokal erzeugte, nicht eingecheckte `baselines.json`. Mit Jack gibt es beides nicht mehr, und den Vergleich gegen die Fable-Referenz ersetzten sie ohnehin nicht. Entfernt sind die Tasks, `EvalBootstrap`, `SummaryEval`, `ThreadEval`, ihre Tests und die Baseline-Einträge in `.gitignore`, dazu `mix lore.bench_llm_stage2`. Die Ground-Truth-Dateien des Fixtures (`reference-summary.md`, `fact-key.json`) bleiben.

**Was stattdessen misst — und was nicht.** Einen automatischen Ersatz gibt es **nicht**. Verglichen wird von Hand gegen den Fable-Referenzlauf (`mix lore.jack.referenz`, Folgedurchgänge bis zur Sättigung in `Worker.Jack.Referenz.Folge`); Jacks eigene Messläufe fährt `mix lore.jack.lauf` (`Worker.Jack.Messlauf`, liest keine Einstellungen und bleibt dadurch vergleichbar). Eine Regression der Extraktion rötet damit keinen Merge und fällt erst beim nächsten Vergleich auf. Zwei Erfahrungen aus den entfernten Evals gelten unabhängig davon weiter: `qwen2.5:7b` labelte Stränge unbrauchbar (Total-Abstinenz oder Parroting eines Beispiel-Labels, #831), und nicht-deterministische Zahlen röten keinen Merge (#557/#656).
