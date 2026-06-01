# Issue-Audit 2026-06-01

Stichtag-Relevanz-Triage aller offenen Codeberg-Issues mit Verdict
(`still-relevant` / `partial` / `resolved` / `obsolete`).

Auf master HEAD `1257d4d` (PR #408 — #350 Seed-source_refs). Vor dem Audit
`git fetch origin master` gemacht (Lesson learned aus dem 2026-05-24-Audit, das
hinter Origin lag) — Branch == Remote-master verifiziert.

Ablöse für `docs/issue-audit-2026-05-24.md` (eine Woche + viele Merges alt,
deckte die #356+/#391-Welle nicht). Methode: drei parallele Explore-Agents,
je Cluster, Issue-Body vs. aktueller Code.

## Kernergebnis

**Nur #393 war stale** (durch #403 erledigt, am 2026-06-01 geschlossen). Alle
übrigen offenen Issues sind **weiterhin relevant** — keine versehentlichen
Miterledigungen durch die jüngste Merge-Welle (#350/#385/#387/#389/#391/#392/#403).
Zwei Issues sind **partial** (Realität über den ursprünglichen Text gewandert,
Bodies am 2026-06-01 nachgeschärft).

## Seit dem letzten Audit geschlossen / gemergt

Auswahl der seit 2026-05-24 gemergten Issues (nicht erschöpfend): #350
(Seed-source_refs), #385 (Chronik-Markdown), #387 (Sidebar-Nav), #389
(Stage-Prompt-Cleanup), #391 (Mic-Setup-Popup), #392 (Mic-Streamer-Liveness,
PR #406), #403 (PR-Test-Prozess-Naming + Sidecar-Cleanup).

- **#393** (PR-Test-Sidecar-Cleanup) → **geschlossen**: `mix lore.pr_test_down`
  killt seit #403 die getaggten Sidecars (`lore-issue-<N>-port-<PORT>-sidecar-…`)
  per argv0-Match. Beim #350-Teardown verifiziert (0 Reste).

## Verdict-Tabelle (offene Issues)

### Mic/Seed-Follow-ups (frisch aus #391/#392/#403/#350)

| Issue | Verdict | Stand |
|---|---|---|
| #394 Live/Confirmed-Utterance-Duplikate n. SessionEnded | still-relevant | Kein Post-Roll-Dedup; Materializer schreibt live+confirmed unabhängig (`materializer.ex` UtteranceAppended). #392 brachte kein Dedup. |
| #395 VU-Bar Farbverlauf bei Clipping | still-relevant | `vu_bar` ist flat `bg-primary` (`ui_components.ex`). |
| #396 Multi-Tab Mic Tab-Election | still-relevant | Kein Duplikat-Check beim `mic_join`. |
| #397 Mic-Auto-Resume nach Device-Pull | still-relevant | `record_mic.js` fängt `device_gone`, kein Auto-Retry/deviceId-Reconnect. |
| #398 mic_silence_dismiss über Reload persistieren | still-relevant | Dismiss nur JS-Memory (`lastVoiceAt`), kein localStorage. |
| #399 Server-side Stille-Watchdog (Browser-Crash-Fallback) | still-relevant | Watchdog ist rein client-side. |
| #400 Test-Phrase-Recognition statt Lautstärke | still-relevant | Voice-Test prüft nur dBFS-Schwelle (`record_mic.js runVoiceLoop`). |
| #401 PubSub-Topic pro Campaign | still-relevant | Broadcast/Subscribe weiter auf globalem `"pipeline_status"`. |

### Features / Infra

| Issue | Verdict | Stand |
|---|---|---|
| #17 Mobile-GUI | still-relevant | `column_sync.js` hat nur Mobile-Stub (<768px → return). |
| #18 i18n | still-relevant | Keine Gettext-Toolchain committed. |
| #31 Auto-Deploy Woodpecker | still-relevant | `.woodpecker.yml` da, aber CI inaktiv (OAuth-Gap) → manueller gigalixir-Push. |
| #38 Worker Auto-Update | still-relevant (blocked) | Kein Release-Binary-Distrib. |
| #46 Feature-Requests → Codeberg | still-relevant (blocked) | Nicht umgesetzt. |
| #47 Public-Repo-Übergang | still-relevant | Gate-Issues (#67 u.a.) offen. |
| #66 Test-Suite + CI | **partial** | 64 Test-Dateien existieren (Suite gebaut); offen nur CI-Aktivierung, hängt an #31. Body nachgeschärft. |
| #67 Accessibility WCAG 2.1 AA | still-relevant | 0 `aria`-Treffer im Hub-Code. |
| #97 EventLog-Retention/Pruning | still-relevant | Kein Pruning-Mechanismus im Worker. |
| #176 LLM-Streaming Stage-3/4 | still-relevant | `stream: false` in den LLM-Backends. |
| #293 Jobs auf Member-Worker verteilen (Gossip) | still-relevant (blocked) | Kein Gossip im Job-Scheduling. |
| #356 Scroll-Sync-Visualisierung verbessern | **partial** | Basis-Sync (#10) live; SVG-Bänder/Stufen/Hover/Color-Coding offen. Body nachgeschärft. |
| #367 Worker-Selbsthosting-Onboarding | still-relevant | Kein Release-Binary/Setup-Wizard/Doku. |

### Security-Audit-Cluster (v0.3.0 — Public Launch)

Alle Audit-Tasks (Review, kein Feature). Verdict durchweg `still-relevant`; einige
Teil-Mitigationen existieren, aber der jeweilige systematische Audit ist nicht gelaufen.

| Issue | Verdict | Stand |
|---|---|---|
| #358 Auth + Sessions | still-relevant | Kein Brute-Force-/Rate-Schutz auf Login/Pairing. |
| #359 Permission-System (post-#140) | still-relevant | `can?/3` greift; Admin-`all_users`-Snapshot ohne Campaign-Filter (by design, aber Audit offen). |
| #360 Worker-Pairing + Channel/JWT | partial | JWT via `LORE_JWT_SECRET`, kein Token in Logs; Audit-Logs für Pairing/Disconnect fehlen. |
| #361 Input-Validation | partial | Pairing-Validation da; keine flächige Sanitization/XSS-Politur jenseits #385-Markdown. |
| #362 Dependency-CVEs | still-relevant | Kein `mix_audit`/`hex.audit` im Build. |
| #363 Secrets + Logs | partial | Secrets nur via Env; `Logger.warning inspect(reason)` potenziell leaky. |
| #364 Rate-Limiting + DOS | still-relevant | Kein App-Level-Rate-Limiting (kein PlugAttack/Hammer). |

### Multi-Worker-Korrektheit (Bugs)

| Issue | Verdict | Stand |
|---|---|---|
| #365 Pipeline-Race bei mehreren Member-Workern | partial / still-relevant | Pipeline triggert auf `UtterancesTranscribed` + `running`-MapSet, aber kein Worker-übergreifender Lock — 2+ Member-Worker können parallel starten. |
| #366 Snapshot-Reads treffen falschen Worker | partial / still-relevant | `Hub.Reader` sortiert Worker nach `applied_seq`, kein Campaign-/Member-Affinitäts-Routing für `/admin/*`+`/settings`. |

## Cluster-Empfehlungen für die nächste Runde

1. **Mic-Polish-Sprint** (#395/#398/#400 klein, #394 konkreter Bug): inkrementell,
   baut direkt auf #391/#392 auf.
2. **Multi-Worker-Korrektheit** (#365 + #366): real reproduzierbar sobald
   Multi-Worker-Setups echt werden; architektur-nah, vor Public Launch sinnvoll.
3. **Security-Audit-Block** (#358–#364): Public-Launch-Gate (v0.3.0). Investigation-
   lastig; eignet sich für eine dedizierte Härtungs-Runde. Einstieg: #362
   (`mix_audit` einbauen = schnellste konkrete Maßnahme) + #364 (Rate-Limiting).
4. **CI scharf schalten** (#31 → #66): entblockt Test-Gate + Auto-Deploy auf einen
   Schlag.

## Lesson-Learned-Übernahme

Wie 2026-05-24 empfohlen: vor dem Audit `git fetch origin master` gemacht, damit
keine „not-started"-Fehlverdicts durch stale lokalen master entstehen. Bei der
nächsten Refinement-Runde dieses Doc aktualisieren oder durch ein neueres
Stichtag-Doc ersetzen.
