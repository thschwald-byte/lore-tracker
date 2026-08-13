# Issue-Audit 2026-08-13

Löst `docs/issue-audit-2026-07-22.md` ab. Stichtag: nach der **Discord-Voice-Serie**
(#985 → #987 → #989 → #1002 → #1005 → #1007/#1008/#1009/#1011, alle gemerged + auf
Prod verifiziert), den **#911-Cuts 1–3** (Lesen|Bearbeiten-Modus #915, editierbare
Fakten-Spalte #916, ANY-Klemme raus #917) samt Slices 1–3 (#958/#965/#976), **#953**
(Fakt→Bogen N:M) und dem **kompletten I7-Fold-Audit** (#816/#824/#894/#896).
**45 offene Issues, 7 offene Milestones.** Jedes Issue wurde inkl. **aller Kommentare**
gelesen und gegen den heutigen master (`5569ffe`) code-verifiziert — Verdikte unten
nennen die Prüfstelle.

**Neue Prio-Linse dieses Audits: Sonntag 2026-08-16 ist die nächste echte
Rollenspielrunde.** Der Abschnitt „Bis Sonntag" unten ist die konkrete Empfehlung.

## Bis Sonntag (16.08.) — was idealerweise fertig ist

Annahme: die Runde nimmt über den Discord-Bot auf (der frisch gehärtete Pfad).
Reihenfolge nach Schutzwirkung für den Abend:

Alle fünf Posten leben seit dem Nachtrag im Milestone **„Spielabend 2026-08-16"**.

| # | Was | Warum vor Sonntag | Aufwand |
|---|---|---|---|
| #1019 | **Discord-Live-Kurztest des #1016-Stands** (Bot join → 2 min sprechen → Stop → Transkript prüfen, `Flush … dauer=`-Zeile + `files≥1` ohne Late-Append im Log) | Der einzige unverifizierte Teil der Stop-/Flush-Umbauten. 30 min, verhindert eine Sonntags-Überraschung. | XS |
| #1013 | **Beitritts-Ansagen verdrahten** (Namen + Wiedergabe-Queue + Nur-bei-Bedarf + Deckel) | Late-Joiner am Sonntag erfahren sonst nur per Zufall (Scroll zur Button-Nachricht), dass ihre Spur ohne Klick verworfen wird. Die `Voice.play/4`-Queue schließt zugleich den bekannten Silent-Failure-Generator. | M (1–2 Tage) |
| #1020 | **WS-Reconnect-Instrumentierung** (Disconnect-Grund + Uptime + Reconnect-Zähler im HubClient; Browser-`phx:error`-Mitschnitt — aus #927 herausgelöst) | Reißt am Sonntag wieder die WebSocket, gibt es diesmal Evidenz statt Rätselraten. Der Fix selbst (#927) kommt nach der Messung (#557). | S |
| #979 | **Code-Teil**: WAV-Validierung vor whisper + ehrliche Klassen (`wav_decode_failed`, `source_webm_missing`) | Schützt Re-Transkription/Regenerate des Sonntags-Materials vor stillem Spur-Verlust mit irreführender VAD-Meldung. (Ops-Teil ist auf cachyos gegenstandslos — s. #979 unten.) | S |
| #978 | **Optional:** Prompt-Fix Ich-Form-Attribution | Verbessert das Sonntags-Recap direkt (Multiplayer!). Ehrliche Grenze: sauber messbar erst mit #913 — vor Sonntag nur mit Regressions-Check (`eval.summary`/`eval.threads` ohne Verschlechterung) + Stichprobe vertretbar. | S–M |

**Nach** Sonntag zahlt die Runde doppelt ein: die Session ist Real-Material für den
#687-Abnahmetest (Nachlese auf echtem Tisch-Deutsch) und — je nach Einwilligungen der
Gruppe — ein zweiter #978-Beleg.

## Nachtrag (gleicher Tag): Spielabend-Milestone + Konsistenz-Runde

Auf Toms Ansage („Mini-Milestone für die Dinge bis Sonntag? Alle Issues im richtigen
Milestone? Alle mit richtigen Labels?") wurde der Bis-Sonntag-Block operationalisiert:

- **Neuer Milestone „Spielabend 2026-08-16"** (due So 16.08.) mit 5 Issues:
  **#1019** (neu — Discord-Live-Verifikation des #1011/#1009-Stands, der Kurztest aus
  der Tabelle unten als trackbares Issue) · **#1020** (neu — WS-Reconnect-
  Instrumentierung, als Mess-Vorstufe aus #927 herausgelöst; #927 selbst bleibt als
  Ursachen-/Fix-Arbeit in v0.6.0) · **#1013** (Ansagen) · **#979** (WAV-Validierung)
  · **#978** (der bewusst OPTIONALE Posten, s. Entscheidungspunkt 4). Was Sonntag
  nicht fertig ist, wandert in seinen Ursprungs-Milestone zurück.
- **Entscheidungspunkt 2 umgesetzt:** #891 → v1.0.0 (die Milestone-Beschreibung
  verspricht ihn dort ohnehin), #947 → v1.1.0. v0.6.0 enthält damit nur noch #927 —
  ehrlich schaffbar bis 01.09.
- **Label-Konsistenz über alle 48 offenen Issues geprüft:** #18 `blocked` entfernt
  (Blocker #17 ist seit 22.07. zu — stale) · #641 `infra` ergänzt · #856/#857/#858
  `blocked` ergänzt (harte Sequenz hinter Fakten-Modell-Entscheid → #856 → #857).
  Jedes Issue hat ≥1 Label und einen Milestone. **Bewusst NICHT „gefixt":** 12 Issues
  tragen nur Domain-Labels ohne `feature`/`bug` (#445, #524, #541, #543, #575, #625,
  #634, #641, #858, #930, #933, #1017, #1019) — sie sind ehrlich keins von beidem
  (Refactoring, Doku, Dep-Pflege, Methodik, Verifikation); ein erzwungenes
  Primär-Label wäre Rauschen, die Filterbarkeits-Anforderung ist über die
  Domain-Labels erfüllt.

## Durchgeführte Refinement-Aktionen (2026-08-13)

- **Milestone-Hygiene (3 Issues hingen milestone-los und fielen aus jeder Filterung):**
  **#911 → v0.3.2** (es IST die Wahrheitsbild-Qualitätsarbeit; Slices 1–3 sind gelandet,
  4–7 offen) · **#913 → v0.7.0** (Eval-Set = Mess-Tooling; seit 07.08. **entsperrt**,
  alle Sprecher-Einwilligungen liegen vor) · **#776 → v1.0.0** (Self-Update-Qualität =
  Launch-Thema, Schwester von #38).
- **#776 Analyse-Kommentar mit neuer Evidenz (heute erhoben):** Self-Update 12.08.
  16:10 endete WIEDER in Watchdog-ABRT — und die #959-Diagnostik lief mit und
  lieferte **null** Marker-Zeilen. Der Hänger liegt damit VOR beiden
  `hard_halt`-Aufrufstellen; Verdacht auf `Logger.warning`/journald-Backpressure im
  Marker selbst (Details + nächster Schritt im Kommentar: Marker via `:erlang.display/1`).
- **#851 Stand-Kommentar:** der Epic-Kern ist im Code geliefert (Belege unten);
  Schließ-Empfehlung als Entscheidungspunkt.
- **#641 Evidenz-Kommentar:** 12.08. wurden **zwei aufeinanderfolgende
  master-Push-Deploys** gekillt (Pipelines 814 + 816, alle Steps `exit 0`/Canceled) —
  Prod hing zwei PRs hinterher, Recovery nur per Maintainer-Klick.
- **#979 Stand-Kommentar:** Ops-Hälfte auf cachyos gegenstandslos (per RPC verifiziert:
  `audio_dir` = persistenter #948-Default, nicht /tmp); Rest-Scope = Code-Teil;
  `.48` bei nächster Gelegenheit prüfen.
- **Neues Issue #1017 (v0.3.5):** earmark→MDEx-Migration als eigener Security-Slice
  aus #625 herausgelöst (earmark ist RETIRED; einzige Stelle der
  XSS-Defense-in-Depth-Kette `render_md_safe/1`) + Querverweis-Kommentar an #625.

## Milestone-Bewertung

| Milestone | Stand | Verdikt |
|---|---|---|
| **v0.3.2 — Wahrheitsbild** (nach Nachtrag 6 offen: +#911, −#978→Spielabend; due **10.06. — 2 Monate überfällig**) | Beschreibung („pipeline testen und ggf. umstellen") ist längst Geschichte; der Milestone enthält heute real: Nordstern (#687), Qualitäts-Epic (#911), Feldvervollständigung (#841), Attribution-Bug (#978), Projektionen (#850, #892) und ein weitgehend geliefertes Epic (#851). | **Maintainer-Aktion nötig** (nur UI): Beschreibung neu fassen („Wahrheitsbasis-Qualität unter den Null-Aufwand-Axiomen + erste Projektionen") + due realistisch (Vorschlag: 2026-10-01, parallel zu v0.7.0 — die beiden verzahnen sich über #841→#856). #851 schließen (s. Entscheidungspunkte) macht den Rest ehrlich. |
| **Spielabend 2026-08-16** (5 offen, due So 16.08. — Nachtrag) | #1019 (Live-Verifikation), #1013, #1020 (Instrumentierung), #979, #978 (optional). | Nach Sonntag leeren: Erledigtes zu, Rest zurück in die Ursprungs-Milestones. |
| **v0.6.0 — Aufnahme härten** (nach Nachtrag: 1 offen, due 01.09.) | Kern-Härtung ist passiert (#936/#938/#949 + Discord-Serie); #1013/#979 → Spielabend, #891 → v1.0.0, #947 → v1.1.0 (beide durch den Discord-Pfad strategisch relativiert, beide bis 01.09. unrealistisch). Bleibt: #927 (Ursache → Fix nach der #1020-Messung). | Ehrlich schaffbar bis 01.09. |
| **v0.7.0 — Model Tooling** (8→9 mit #913, due 01.10.) | Kohärent; Reihenfolge intern klar (#869 → #874 → #856 → #857 → #858; #852 danach; #859 Backlog). **Cross-Milestone-Abhängigkeit:** #856 wartet auf den Fakten-Modell-v2-Entscheid, dessen Kern #841 in v0.3.2 liegt. #913 ist das fehlende realistische Messinstrument für beide Milestones. | Unverändert lassen; beim Angehen #841 zuerst ziehen. |
| **v0.3.5 — Security-Followups** (2→3 mit #1017, due 01.12.) | #524 + #634 unverändert gültig (hub_token weiter Klartext at-rest, verifiziert `hub_client.ex:654`; keine Rotation-SOP). | Als kompakter Block vor v1.0.0; #1017 passt dazu (XSS-Kette). |
| **v1.0.0 — Public Launch** (10→11 mit #776, due 05.12.) | Kohärent. #766-Epic: I7 **komplett** (C/C2/D/D-Variante + #401 + I1a alle zu) — Rest ist F3/F4 + Gates G2–G4. #641 hat wachsende Evidenz (Kill-Serie jetzt auch auf master-Pushes). **Inkonsistenz:** die Milestone-Beschreibung nennt #891 als v1.0.0-Inhalt, das Issue hängt aber in v0.6.0. | Lassen; #641 bleibt Vorzieh-Kandidat; #891-Inkonsistenz als Entscheidungspunkt. |
| **v1.1.0 — Post-Launch** (8 offen) | Alle gültig (Code-verifiziert: kein Reconnect-Filter in `handle_diff`, kein AsyncLiveView, Rolle weiter sync geladen). #575 trägt Toms Einwand („Rolle kann pro Worker unterschiedlich sein") — beim Angehen zuerst das Design klären. | Parkplatz funktioniert. |
| **v1.2.0 — Polish** (3 offen) | #840 hat jetzt einen sauber dokumentierten Fehlversuch (Zwei-Call-Split: Thread-Dichte geheilt, Beziehungs-Qualität ungenügend; Branch verworfen) — genau richtig geparkt. #933 hängt am Ausgang von #927. | Unverändert. |

## Per-Issue-Bewertung

Legende: ✅ = gültig, unverändert · 🔧 = gültig, Scope präzisiert · ✂ = weitgehend
erledigt · Code-Spalte = heutige Prüfstelle.

### v0.3.2 — Wahrheitsbild

| # | Titel (kurz) | Verdikt | Code-Verifikation + Reihenfolge |
|---|---|---|---|
| #911 | Epic Ernte statt Pflege | ✅ **jetzt v0.3.2** | Slices 1–3 gelandet (#958/#965/#976 gemerged); offen: 4 Parroting-Fix, 5 Bogen-Ernte+Grounding-Gate, 6 Lücken-Kuration entschärfen, 7 Kurations-Export. **Das Herzstück des Milestones.** Slices 4+6 sind die nächsten sinnvollen Schnitte; 5 ist der große. |
| #978 | Unter-Attribution Nebensprecher | ✅ → Spielabend (optional) | `prompts.ex:58` sagt weiterhin „aus dem KONTEXT aufgelöst, NICHT der Sprecher-Turn" — der Ich-Form-Fall fehlt. #976 (cast_match) löst Alias, nicht Attribution. **Sonntags-Kandidat** (optional); sauber messbar mit #913. |
| #841 | other_entities-Feld | ✅ | Kein Treffer für `other_entities` im Worker — ungebaut. **Vor #856-Wiederaufnahme** entscheiden (Fakten-Modell v2; Cross-Milestone-Kante nach v0.7.0). |
| #850 | Frag die Kampagne | ✅ | Kein `Worker.Recall`, kein `complete_with_tools` — ungebaut. Tool-Use-Ansatz ist empirisch vorvalidiert (Kommentar 07.08., live gegen qwen2.5:7b inkl. „steht nicht in den Aufzeichnungen"-Negativfall). Nach Substrat-Qualität (#911-Slices) + #841. |
| #892 | Globale Arbeits-Sichtbarkeit | ✅ | Nichts Globales existiert (nur per-Session-Badges + Replay-Banner). Kernfeature-Entscheid vom 22.07. steht. Gap-Fill-Nachlauf (~25 min) und Dirty-Weiche laufen weiter unsichtbar. |
| #687 | Nordstern Recall / NULL SL-Arbeit | ✅ bleibt | Abnahmetest-Issue; Nachlese existiert (#907), Qualität hängt am Substrat. **Sonntag liefert das erste echte Abnahme-Material.** |
| #851 | Epic Kuration überlebt Generierung | ✂ **Schließ-Kandidat** | Kern im Code geliefert: Fakt-Anker content-adressiert + Carry-over (#861/#866), Fakt-Aktionen claim/character/thread/verified/dismiss mit Utterance-Mengen-Anker + Re-Attach (#916, `worker_fact_overrides` in `mnesia.ex:78`), **Prosa-Zwei-Slot kuratiert/generiert für Resümee+Epos+Chronik** (#914, `render_slots.ex` + `apply2.ex:248ff`), Arc-Re-Attach + stabile Overrides (#903/#905), Flags auf rebuild-stabilen IDs (#915). **Einzige Rest-Lücke:** `worker_thread_overrides` (#836) keyt auf Kanon-Text → orphant nur noch beim expliziten GM-Voll-Re-Cluster (Churn-Ursache durch #842 beseitigt, Confirm-Warnung existiert). |

### v0.3.5 — Security-Followups

| # | Titel (kurz) | Verdikt | Code |
|---|---|---|---|
| #524 | Worker-JWT at-rest | ✅ | `hub_client.ex:654` liest `hub_token` weiter klartext aus Mnesia. Optionen-Entscheid steht aus. |
| #634 | Secrets-Rotation-SOP | ✅ | Kein `docs/Secrets-Rotation.md`. Nach #524 (Entscheid fließt ein). |
| #1017 | earmark→MDEx (neu) | ✅ | earmark RETIRED; `~> 1.4`-Constraint + `render_md_safe/1`-Kette verifiziert. Sicherheitsfokus: gleiche Escape-Garantie nachweisen (`render_md_safe_test.exs`). |

### Spielabend 2026-08-16 (Nachtrag) + v0.6.0 — Aufnahme härten

| # | Titel (kurz) | Verdikt | Code |
|---|---|---|---|
| #1019 | Live-Verifikation #1016-Stand | 🆕 Spielabend | Verifikations-Issue (Ablauf + Log-Erwartungen im Body); der einzige unverifizierte Teil der Stop-/Flush-Umbauten. |
| #1013 | Discord-Beitritts-Ansagen | ✅ → Spielabend | Texte pure + getestet, unverdrahtet (Consumer verwirft `member`, keine Play-Queue). |
| #1020 | WS-Reconnect-Instrumentierung | 🆕 Spielabend | Mess-Vorstufe aus #927 (Uptime/Zähler/Browser-Seite fehlen heute — nur generisches Reason-Log `hub_client.ex:474`). |
| #979 | Re-Transkription verliert Spur | 🔧 → Spielabend | Ops-Hälfte auf cachyos gegenstandslos (RPC-verifiziert: `audio_dir` = `<mnesia>/audio`); `.48` offen. Code-Teil ungebaut (kein `wav_decode_failed`/`source_webm_missing`/ffprobe in `transcribe.ex`). |
| #978 | Unter-Attribution (optional) | ✅ → Spielabend | S. v0.3.2-Tabelle; der bewusst optionale Posten (Entscheidungspunkt 4). |
| #927 | WS-Reconnects `:closed` | ✅ bleibt v0.6.0 | Ursachen-/Fix-Arbeit NACH der #1020-Messung (#557). |
| #891 | Nativer Mobile-Client | ✅ → v1.0.0 | **Strategisch relativiert:** der Discord-Bot-Pfad deckt „Spieler-Handy als Mikro" für Discord-Gruppen inzwischen ab (Handy-Discord-App im Voice-Channel, kein Browser). Bleibt gültig für Nicht-Discord-Gruppen + Recap-Lesen. |
| #947 | Epic Capture-Agent | ✅ → v1.1.0 | Gleiche Relativierung: Discord-Bot ist die zweite robuste Capture-Alternative, Browser-Pfad ist gehärtet (#936/#938/#949). „Kein v1-Muss" steht im Issue selbst. |

### v0.7.0 — Model Tooling (Reihenfolge = Empfehlung)

| # | Titel (kurz) | Verdikt | Code |
|---|---|---|---|
| #869 | Stale Eval-Settings | ✅ **1.** | `eval_bootstrap.ex` referenziert `LORE_MNESIA_DIR` nicht; Settings kommen ungewarnt aus dem geteilten Store. Messhygiene-Voraussetzung für alles Weitere. |
| #874 | gpt-oss nicht lauffähig | ✅ **2.** | Keine `reasoning_effort*`-Keys in `settings.ex` (verifiziert); `think:`-Mechanik kennt nur bool. Blockt den stärksten lokalen Judge-/Extraktor-Kandidaten. |
| #913 | Real-Tisch-Deutsch-Eval | ✅ **3.** — **entsperrt** | Einwilligungen aller Sprecher liegen vor (Kommentar 07.08.). Das fehlende Messinstrument für #911-Slices, #978 und die Sweeps. Kandidaten-gestützter Gold-Fluss wie im Kommentar. |
| #856 | Judge-Sweep GUI | ✅ **4.** | Branch `issue-856-judge-sweep` existiert (2 Commits, Basis 037076f0 — **rebasen**). Wiederaufnahme nach Fakten-Modell-Entscheid (#841 + fact_type-Frage). |
| #857 | Extraktor-Sweep | ✅ **5.** | Nach #856 (braucht fixen Judge). |
| #858 | Modellentscheidung + Baselines | ✅ **6.** | Gate-Mechanik existiert (#888); verbleibt Holdout-Methodik + Doku = v0.7.0-Abschluss. |
| #852 | Admin-Modell-Katalog | ✅ danach | Sweep-Ergebnisse sind der Katalog-Inhalt; vorher gebaut wäre er leer. `honors_schema`-Befund (qwen3.6:27b) bleibt der Beleg. |
| #859 | Cloud-Judge | ✅ Backlog | Hinter #858. |
| #854 | Epic Modellvergleich | ✅ Rahmen | Slices 0+3 zu, 1/2/5 offen — konsistent mit obiger Reihenfolge. |

### v1.0.0 — Public Launch

| # | Titel (kurz) | Verdikt | Code |
|---|---|---|---|
| #766 | Epic Multi-Worker | ✅ | **I7 komplett** (C #816, C2 #824, D-Rest #894, D-Variante #896, dazu #401 + I1a/#772). Rest: F3 (Consent-Neufassung — Anmerkung: #1005 hat Klick-Consent+Widerruf gebaut, F3s Kern „Log-Volltext-Exposition benennen" ist Text-/Consent-Arbeit, noch offen), F4 (Leave-Löschung), Gates G2–G4. |
| #776 | graceful_halt hängt | ✅ **jetzt v1.0.0** + neue Evidenz | Heute verifiziert: Update 12.08. 16:10 → wieder ABRT; #959-Marker kamen NICHT (weder Haupt-Pfad noch Backstop) → Hänger vor beiden `hard_halt`-Stellen. Nächster Schritt im Kommentar (Marker ohne Logger). |
| #641 | CI-Konsolidierung + Cache | ✅ ⬆️ | Kill-Serie erreicht jetzt master-Push-Deploys (814+816 am 12.08. in Folge). Kostet real Merge- UND Deploy-Latenz. Vorzieh-Kandidat. |
| #367 | Onboarding Release-Binary | ✅ | Kein `release.worker` in `mix.exs` (nur `release.hub`, Worker bewusst exkludiert) — ungebaut. |
| #38 | Worker Auto-Update | ✅ blocked #367 | Mechanik existiert für git-Worker; Rest = Portierung auf Release-Binärwelt (22.07.-Kommentar gilt). |
| #96 | Verschlüsselte Cloud-Backups | ✅ | `mix lore.backup` existiert (#65); Crypto + Push ungebaut. |
| #543 | Staging-E2E operative Pfade | ✅ | Kein Harness. #776-Evidenz zeigt erneut: operative Bugs manifestieren nur im systemd-Umfeld — genau die Lücke dieses Issues. |
| #625 | Deps-Bumps | 🔧 | Constraints verifiziert (`~> 1.7.14`, gettext `~> 0.24`). earmark-Teil → #1017 ausgegliedert; Rest = Patch-Sammel-PR + Major-Bumps einzeln. |
| #46 | Feedback → Codeberg-Issue | ✅ | Kein `.gitea/issue_template/`, kein Feedback-Link — ungebaut. Klein. |
| #67 | Accessibility-Basis | ✅ | Unverändert; A11y-Disziplin wird in neuer UI mitgeführt (#915-Toggle), der Token-/Label-Pass steht aus. |
| #980 | Kampagne archivieren | ✅ | Producer nur `admin_users_live.ex:223`; kein `:archive_campaign` in `permissions.ex`; Fold einseitig. Klein + direkt nützlich (9 Kampagnen real). |

### v1.1.0 — Post-Launch / Scale & Polish

| # | Titel (kurz) | Verdikt | Code |
|---|---|---|---|
| #872 | Pipeline-Arbeit verteilen | ✅ | Nach #766-Rest. Erster Schnitt: Gap-Fill + Evals (strukturell konfliktfrei). |
| #769 | WCAG AA Vollausbau | ✅ blocked #67 | Reflow-Posten braucht eigenes Konzept (seit #17-Schließung). |
| #575 | Rolle in Session-Cookie | ✅ ⚠️ | Toms Einwand im Issue (Rolle pro Worker unterschiedlich) → Design-Klärung vor Bau. |
| #542 | Runtime-Observability | ✅ | `[:hub, :audio, :chunk_dropped]` existiert nur für no_member_worker; wrong_worker-Symmetrie + pending-Counter-Alert offen. |
| #541 | AsyncLiveView + Worker.Tasks | ✅ | Kein `HubWeb.AsyncLiveView`, kein `Worker.Tasks` — ungebaut. |
| #445 | CampaignLive → LiveComponents | ✅ | Members-LC existiert (Pilot #621); Rest (Recording-Bar + 4 Sync-Spalten) offen. |
| #930 | handle_diff Reconnect-Filter | ✅ | `worker_registry.ex:44ff` broadcastet ungefiltert (verifiziert) — join∩leave-Filter fehlt. Klein. |
| #18 | i18n | ✅ | Unverändert; EN = erste Zielsprache nach Launch. |

### v1.2.0 — Polish

| # | Titel (kurz) | Verdikt |
|---|---|---|
| #356 | Scroll-Sync-Visualisierung | ✅ geparkt |
| #840 | Beziehungsgraph | ✅ geparkt; Fehlversuch sauber dokumentiert (Zwei-Call-Split: Threads geheilt, Relationen fabulieren ohne Transkript-Kontext); nächster Anlauf mit Transkript-Kontext + deterministischem Alias-Nachfilter |
| #933 | Skeleton statt Popp-in | ✅ geparkt; hängt am Ausgang von #927 |

## Empfohlene Gesamt-Reihenfolge

1. **Bis Sonntag (16.08.):** Live-Kurztest #1016 → **#1013** → #927-Instrumentierung →
   #979-Code-Teil → optional #978-Prompt-Fix.
2. **Nach Sonntag — Messfundament:** **#913** (Eval-Set aus Free Seattle S1, jetzt
   entsperrt) → #869 → #874. Damit werden #911-Slices 4–6 und #978 erstmals ehrlich
   messbar.
3. **#911-Slices 4 + 6** (Parroting-Fix, Lücken-Kuration entschärfen — beide klein,
   beide gegen #913 messbar), dann **Slice 5** (Bogen-Ernte + Grounding-Gate, der
   große).
4. **Modellvergleich zu Ende:** #841-Entscheid → #856 (rebasen!) → #857 → #858 =
   Baselines frieren = v0.7.0-Abschluss; #852 danach.
5. **Parallel, klein:** #980, #46, #930.
6. **Security-Block:** #524 → #634 → #1017.
7. **Launch-Strecke:** #766-Rest (F3/F4/Gates) → #367 → #38; #641 beim nächsten
   CI-Ärger sofort vorziehen; #543, #96, #67, #625-Rest.

## Entscheidungspunkte für Tom

1. **#851 schließen?** Der Epic-Kern ist code-verifiziert geliefert (s. Tabelle).
   Vorschlag: schließen mit Beleg-Kommentar; die eine Rest-Lücke
   (Thread-Override-Anker beim expliziten Voll-Re-Cluster) entweder als akzeptierte,
   dokumentierte Grenze — oder als kleines Einzel-Issue.
2. ~~**#891 + #947 Platzierung**~~ — **im Nachtrag umgesetzt** (#891 → v1.0.0,
   #947 → v1.1.0, Begründungs-Kommentare an beiden Issues).
3. **v0.3.2-Milestone pflegen** (nur Maintainer-UI): Beschreibung neu fassen + due
   aktualisieren (Vorschlag 2026-10-01) — oder den Milestone schließen und den Rest
   nach v0.4.0 umziehen.
4. **#978 vor Sonntag riskieren?** Prompt-Fix ohne echtes Multi-Speaker-Eval ist
   Measure-First-Grenzfall — mein Vorschlag: nur mit Regressions-Check bauen, echte
   Messung nach #913.
