# Issue-Audit 2026-05-24

Stichtag-Audit aller offenen Codeberg-Issues mit Verdict (`done` / `partial` / `not-started`).

Auf master HEAD `37600a5` (PR #172 — dieses Audit-Doc).

**Staleness-Hinweis**: Beim Erstellen lief das Audit lokal gegen Master `624ee4f`, war aber **hinter Origin** (Origin-Master war zum Zeitpunkt der Audit-Erstellung bereits auf `4701a7b` mit der ganzen Etappen-4c/5a/5b/5c/4b-Welle). Der Audit hat das nicht gesehen, weil ich bei Session-Start nicht `git fetch origin master` gemacht habe — genau die Falle aus der CLAUDE.md-Goldenen-Regel. Folge: #160 war im Audit als „not-started" markiert, war tatsächlich aber bereits gemerged (`5e1b68d`) — nachträglich retro-closed.

**Lesson learned für die nächste Refinement-Runde**: vor dem Audit `git fetch origin master` + `git merge --ff-only origin/master`, sonst sind alle „not-started"-Verdicts unzuverlässig.

## Refinement-Session-Update 2026-05-24 (post-PR-#173)

Nach dem initialen Audit ging eine Refinement-Session über alle 36 offenen Issues. Kurzfassung der Änderungen seitdem:

### Zusätzlich geschlossen (in derselben Session)

| Issue | Titel | Grund |
|---|---|---|
| #27 | LLM-Backends erweitern: Cloud-Anbieter | Phase 1a Anthropic (`b2c8f81`) gemerged + Architektur seit #162/#164 radikal anders. Ersetzt durch 5 fokussierte Sub-Issues (siehe unten). |
| #52 | Userverwaltung (Parent) | 1/3 done (52A #55 `dc6b276`), restliche Info lebt in den Sub-Issues #56 + #57. Parent inhaltslos. |
| #93 | Performance-Baseline Whisper-Stage | Volldublette von #94 (beide „#69 Teil 3"). |

### Neue Issues (aus #27-Split)

| Issue | Titel | Scope |
|---|---|---|
| #174 | Worker.LLM.OpenAI-Backend | Direkt-Calls mit `OPENAI_API_KEY`-Env-Var, analog Anthropic-Pattern. |
| #175 | Worker.LLM.Google-Backend (Gemini) | Direkt-Calls mit `GEMINI_API_KEY`-Env-Var. |
| #176 | LLM-Streaming für Stage-3/4 | SSE-Streaming für Anthropic/OpenAI, Live-Token-Display im LV. |
| #177 | LLMCallBilled-Event + Spend-Dashboard | `/admin/spend`-View, Per-Call-Spend-Events. |
| #178 | Per-User-Spend-Caps pro Monat | Cap-Check vor jedem Cloud-Call, hängt an #177. |

### Drift-Fixes per Body-Edit

Bodies aktualisiert für post-#140 (per-Campaign-Rolle), post-#154 (`Hub.EventLog` weg), post-#162 (Cloud-Keys weg), post-#164 (Hub DB-frei), post-#33 (Discord-Bot weg):

- **#10** — Title-Change + Scope-Trim („Scroll-Sync zwischen Spalten via IntersectionObserver"), Teil A absorbiert in #114.
- **#17** — Mini-Fix `#10 Teil B` → `#10`.
- **#18** — Discord-Bot-Klärungsfrage raus (post-#33), DeepL-Key auf Env-Var-Pattern, `blocked`-Label entfernt.
- **#19** — Top-Prio-Header (seit #33-Done einziger Recording-Pfad), `:owner` → per-Campaign-`:spielleiter`.
- **#38** — Phase-3-Manifest als statisches JSON (kein Hub-DB mehr), #33 + #25 als done markiert.
- **#47** — Stand-Tabelle der Public-Repo-Files, CONTRIBUTING.md via #83 ausgebaut.
- **#57** — Komplettes Re-Design auf per-Campaign-`:spielleiter`-Logik (Ownership-Transfer-Konzept obsolet).
- **#66** — Stand-2026-05-24-Header, Verweise auf #136/#74/#88/#58 done, Fokus auf Coverage + CI.
- **#68** — Cloud-LLM-Fehler-Hinweis auf Env-Var statt Settings-Tab.
- **#69** — Sub-Issue-Liste aktualisiert (#102 dup → #101, #93 dup → #94).
- **#85** — Title-Update („Public-Repo-Übergang: Security-Hardening-Audit"), Checkliste post-#160/#152/#154/#162/#164 aktualisiert (JWT statt WorkerTokens, EventBridge statt EventLog, Env-Var-Keys, etc.).
- **#88** — Phase 2a done markiert (`9ed1e39`), 2b/2c-Scope herausgearbeitet.
- **#89** — Blocker #27 → #174/#175, Anthropic schon nutzbar.
- **#97** — Archiv-Postgres-Mention raus, Worker-lokales Archiv-Mnesia.
- **#99** — Postgres-Größe-Mention raus (Hub DB-frei).
- **#101** — Blocker #93 → #94.
- **#114** — Scope erweitert um Teil A aus #10 (Source-Refs für Stage 3/4 + UI-rückwärts).
- **#144** — `@owner?` raus, Postgres-Consent raus.
- **#56** — Zeile-Refs raus, `~~#52~~`-Closed-Note.

### Offen jetzt: 38 Issues

Per-Bucket-Zähler (post-Refinement):

- **Recent/UI**: #169, #170 (#171 wurde von Tom selbst während der Session geschlossen).
- **Cloud-LLM (neu aus #27)**: #174, #175, #176, #177, #178.
- **Infra (legacy)**: #31, #38, #46, #47, #68, #85, #144.
- **Performance-Suite**: #69 (Parent) + #91/#92/#94/#95/#99/#101.
- **Backup/Retention**: #96, #97.
- **Userverwaltung-Sub**: #56, #57.
- **LLM**: #88, #89, #113, #114.
- **Policy/UX**: #10, #17, #18, #19, #50, #64, #66, #67, #166.

Volldubletten + Drift-Bugs aus dem ursprünglichen Set sind durch — die offenen Tickets sind jetzt alle entweder klar formuliert oder durch konkrete Drift-Fixes auf den aktuellen Architektur-Stand gebracht.

---

## Original-Audit (für die Historie)

## Done — Issue offen, aber bereits in master gemerged (12)

Tracker-Hygiene: durch fehlendes `Closes #N` im Commit-Message nicht auto-geschlossen.

| Issue | Titel | Merge-Commit |
|---|---|---|
| #104 | Pipeline-Trigger in der Campaign-UI | `da721e8` |
| #116 | Hub-UI Button-Set vereinheitlichen | `b5dac88` |
| #121 | Pipeline-Trigger lokal im Worker (RegenerateRequested raus + Crash-Schutz) | `c03d4be` |
| #123 | UUIDv7 + Worker-First-Apply (universal) | `2a027a6` |
| #125 | Hub.Release.migrate/0 + Auto-Migrate beim Release-Start | `7fe311d` |
| #127 | Etappe 3a: Per-Campaign Event-Stores lokal im Worker | `0cbc0de` |
| #129 | Etappe 3b: Hub-Routing pro Campaign-Subscription | `385af17` |
| #131 | Etappe 3c: Gossip-Pull-Protokoll (Worker-zu-Worker via Hub-Broker) | `26d4e38` |
| #133 | Etappe 3d: LWW + Tombstones für State-Konflikt-Resolution | `fd5a6c9` |
| #136 | Test-Audit: bestehende fixen + Etappen-2/3-Coverage aufbauen | `6bc9eee` |
| #141 | Etappe 4a: Global-Events-Pull-Sync (worker_events_global) | `b147724` |
| #146 | Spielleiter-Permissions Worker-resilient (CampaignLive + Reader-Iteration + Commands-Fallback) | `80587d0` |
| #160 | Etappe 5a: worker_tokens raus, JWT (RFC 7519) statt DB-Lookup | `5e1b68d` (post-audit nachgetragen) |

## Partial — Teilarbeit done, Rest offen (8)

| Issue | Titel | Done | Offen |
|---|---|---|---|
| #27 | Cloud-LLM-Backends | Phase 1a Anthropic via Hub-Proxy (`b2c8f81`) | OpenAI/Google-Backends, Streaming, Per-User-Spend-Caps |
| #50 | Settings-UI: Modell-Combobox | Datalist-Hint-Stopgap (`828daec`) | Custom-Combobox-Widget, dynamische Filter-Liste |
| #52 | Userverwaltung (Parent) | 52A Member-Remove-UI (`dc6b276`) | 52B (#56), 52C (#57) |
| #66 | Test-Suite + CI-Integration | Test-Audit (`d637f6e`), `.woodpecker.yml` mit test-Step | Coverage-Ziele >70%, strukturierte Fixtures/Helpers, CI-Aktivierung (siehe #31) |
| #69 | Performance-Baseline (Parent) | Probelauf Phase 1+2a (#74, #88-2a) | Sub-Issues #91-#95, #99, #101 (#102 dup) |
| #88 | LLM-Probelauf Phase 2 | Phase 2a Single-Stage-Sweep + Resultat-Tabelle (`9ed1e39`) | Phase 2b/2c — Auto-Apply bei gemessenem bestem Modell |
| #113 | LLM-Pipeline Phase 3: Modell-Vergleich | Faithfulness-Sidecar (#11 Phase 2, `be65b97`) | Evaluations-Framework + Modell-Vergleichs-UI |
| #166 | Test-Setup Pain-Point-Audit | — (Audit-Issue, kein Code) | Entscheidung „umsetzen?" steht aus |

## Not-Started (30)

### Recent/UI (3)
- **#169** — Protokoll-Spalte: Sessions zuklappbar, Default nur letzte offen + scrollt auf letzten Eintrag
- **#170** — Lore-Spy Button-Set: inkrementelle Migration, Dashboard zuerst
- **#171** — Pair-Less PR-Test-Setup: `mix lore.seed.fixture` schreibt Worker-Mnesia + JWT direkt

### Infra (7)
- **#31** — Auto-Deploy via Woodpecker (Auth + Aktivierung) — laut `CLAUDE.md` aktiv blockiert durch OAuth-permission gap
- **#38** — Worker Auto-Update für Self-Hosted-Spielleiter
- **#46** — Feature-Requests aus der App: User → Codeberg-Issue
- **#47** — Public-Repo-Übergang vorbereiten
- **#68** — Error-Logging + Troubleshooting-Sichtbarkeit für Self-Hosted
- **#85** — Hardening (Security-Audit vor Public-Repo-Übergang)
- **#144** — Admin-Debug-Endpoint für LiveView-State-Impersonation

### Performance-Sub (8 — alle blockieren #69 + Aggregator #101/#102)
- **#91** — LLM-Stages
- **#92** — Reader + Materializer Scaling
- **#93** — Whisper-Stage
- **#94** — Whisper Stage-1 Mess-Baseline mit PD-Audio
- **#95** — UI-Last-Test: Schlegel-Volltext im Browser
- **#99** — BEAM-Footprint + DB-Groesse messen
- **#101** — docs/Performance.md aggregieren (Aggregator)
- **#102** — docs/Performance.md aggregieren — **Volldublette von #101**, sollte geschlossen werden

### Backup/Retention (2)
- **#96** — Verschlüsselte + Cloud-Backups für Self-Hosted-Worker
- **#97** — EventLog-Retention/Pruning + Kampagne archivieren

### Userverwaltung-Sub (2)
- **#56** — 52B: Multi-Campaign-Add im `/admin/users`
- **#57** — 52C: User-Delete mit Cascade + Name-Confirm-Dialog

### LLM (2)
- **#89** — LLM-Probelauf Phase 3 — Cloud-Backends einbeziehen (Anthropic/OpenAI)
- **#114** — LLM-Pipeline Phase 4: Strukturierter Quellbezug (`utterance_ids` in Stage 2)

### Policy/UX (6)
- **#10** — Kontextbasiertes Mitbewegen
- **#17** — GUI für mobile Endgeräte optimieren
- **#18** — Internationalisierung
- **#19** — Single Source Aufnahme (hängt an #33 — done)
- **#64** — Datenschutz: Consent-Flow für Audio-Aufnahme
- **#67** — Accessibility: WCAG 2.1 AA Compliance für Hub-UI

## Cluster + Reihenfolge-Vorschläge

- **Public-Launch-Gate**: #47 → braucht #85 (Hardening), #67 (WCAG), #64 (Consent), #68 (Error-Logging) als Vorarbeit; #46 (Feedback-Modal) ist nice-to-have für Public-Repo.
- **Performance-Suite**: #91-#95 + #99 → Aggregator #101 (dann #102 schließen).
- **LLM-Roadmap**: #114 (Stage-2 source-refs) entsperrt #10 Teil A (Kontextbasiertes Mitbewegen); #113 + #89 brauchen Phase-2b/2c aus #88.
- **Etappen-Serie (Architektur)**: 3a-3d, 4a, 4b (#152), 4c.1-4c.4 (#154), 5a (#160), 5b (#162), 5c (#164) **alle gemerged** seit Hub-v1.0.0. Der Hub ist seit Etappe 5c vollständig DB-frei. Nächster offener Etappenschritt nach 5c: nicht spezifiziert (keine Issue für eine „Etappe 6").
- **Userverwaltung**: 52A done, 52B (#56) + 52C (#57) als Paar machen, dann Parent #52 schließen.

## Folge-Aktionen

1. 12 falsch-offene Issues schließen (siehe Done-Tabelle)
2. #102 als Dublette von #101 schließen
3. Dieser Audit als `docs/issue-audit-2026-05-24.md` committed
