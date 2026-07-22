# Issue-Audit 2026-07-22

> **Nachtrag (gleicher Tag, Entscheidungsrunde mit Tom):** nach dem Vormittags-Snapshot unten
> wurden **alle 43 offenen Issues einzeln durchentschieden**. Die Tabellen unten zeigen den
> Vormittags-Stand; hier das verbindliche Ergebnis (40 offene Issues danach):
>
> - **Priorität: #766 (Multi-Worker-Epic) ist die Top-Priorität** — vor dem Modellvergleichs-Track.
>   Kleine Posten (#869, #889, #874) laufen daneben, wo sie passen.
> - **Geschlossen:** #853 (4/5 Knöpfe waren schon gebaut; Rest — reasoning_effort_stage{2..5},
>   num_predict_stage2 — in #874 gefaltet, #854-Slice-3 damit dort aufgegangen) · #89 (abgelöst
>   durch #859) · **#17** (Produktentscheidung: Übersicht zu groß für responsiven Umbau →
>   ersetzt durch #891) · **#176** (Token-Streaming greift zu kurz → ersetzt durch #892) ·
>   #681 (nicht auf Vorrat; nach #858 ggf. frisch formulieren).
> - **Neu angelegt:** **#891** „Nativer Mobile-Client mit Basisfunktionen (Aufnahme zuerst)"
>   (v1.0.0, audio/feature/mobile) · **#892** „Globale Arbeits-Sichtbarkeit: immer sehen können,
>   wenn gerade irgendwo etwas arbeitet" (**Kernfeature**, v1.0.0, feature/ui).
> - **Verschoben:** #641 → v1.0.0 (CI-Infra-Kill-Serie als neuer Beleg, Kommentar am Issue) ·
>   #356 → neuer Milestone **„v1.2.0 — Polish"** (reiner Polish-Parkplatz hinter Post-Launch).
> - **Bewusst NICHT gemacht:** #687-Slice-A-Ausgliederung (bleibt im Nordstern) · #681-Wiedervorlage
>   (stattdessen geschlossen).
> - **Hygiene:** #625 infra-Label · #96/#445 stale Assignments entfernt · Stand-Kommentare an
>   #38 (Update-Mechanik existiert, Rest = Portierung auf Release-Binärwelt) und #769 (Reflow-
>   Grundlage durch #17-Schließung weg — eigenes Konzept oder AA-Eingrenzung bei Angehen) ·
>   v1.0.0-Milestone-Beschreibung: „mobile-optimiert" → #891.
> - **Korrektur zum Diskussionspunkt #18 unten:** der DE/EN-Widerspruch war schon am 09.07.
>   aufgelöst (v1.0.0-Beschreibung sagt bereits „UI DE-only → #18") — der Punkt unten ist
>   gegenstandslos.
> - **Reihenfolge-Notizen aus der Runde:** #634 nach #524 (Optionen-Entscheid fließt in die SOP) ·
>   #541 vor #445 (LV-Migration nur einmal anfassen) · #401 nach den #766-Skalen-Slices ·
>   #543-Gossip-Teil bei der #766-Slice-Planung prüfen · #852 erst nach #857/#858 füllen.
>
> Milestone-Stand danach: v0.3.2 **16** offen · v0.3.5 **2** · v1.0.0 **12** · v1.1.0 **9** ·
> v1.2.0 **1**.

Löst `docs/issue-audit-2026-07-09.md` ab. Stichtag: nach Abschluss von **Epic #829**
(Handlungsbögen komplett — A/B/C/D1/D2/D3 + #885 Arc/Context + #837 Eval-Gate) und
**Epic #861** (Stage 1.1: Glättung, Gap-Fill, Kuration, Dirty-Weiche, content-adressierte
Fakt-IDs), sowie dem **E2E-Beweis der Wahrheitsschicht auf Prod** (Real Free Seattle:
247 Lücken kuratiert → 703 Fakten / 550 verifiziert / 0 geklemmt, Chronik 1 → 539 Einträge).
Das komplette Nachschärf-Paket des 07-09-Audits ist gelandet (#762, #763, #753, #689,
#724 alle zu). 43 offene Issues, 4 offene Milestones.

Anders als die Vorgänger dokumentiert dieses Audit **durchgeführte** Refinement-Aktionen,
nicht nur Empfehlungen (siehe unten).

## Durchgeführte Refinement-Aktionen (2026-07-22)

- **#889 angelegt** (v0.3.2, bug/llm): Stage-4/5-Render skaliert nicht mit der Faktenzahl —
  der Teststage-Befund vom 2026-07-17 („Es tut mir leid, aber ich kann keine Informationen
  zu den Nummern 325 bis 496 finden") als strukturelles Issue; Empfehlung (Render-Map-Reduce
  vs. priorisierter Fakten-Deckel + Prompt-Größen-Guard) als Kommentar.
- **#838 / #841 / #842 Bodies nachgetragen + gelabelt** — die drei #829-Folge-Issues waren
  leere, ungelabelte Platzhalter (fielen aus jeder Filterung raus).
- **#874 → v0.3.2** (gpt-oss-Bug blockt den stärksten lokalen Sweep-Kandidaten),
  **#872 → v1.1.0** (Verteilung hängt an #766).
- **#293 geschlossen** (superseded durch #872; Transkriptions-/Diarisierungs-Aspekt per
  Kommentar in #872 übernommen).
- **#851 Stand-Update kommentiert**: der Fakt-Anker-Teil ist durch Epic #861 strukturell
  erledigt (content-adressierte Fakt-IDs, `extraction_event_id`-Pin entfallen, Carry-over);
  verbleibender Scope = Fakt-Aktionen (Slice 1), Strang-Anker, Prosa-Edit-Guards.
- **#858 Stand-Update kommentiert**: #837-Gate-Mechanik existiert (PR #888); Slice 5 ist
  jetzt reine Methodik (Entscheidung + Holdout + Baseline-Freeze).
- **#681 Re-Scope-Kommentar** (Chain-Ära-Nummerierung → Wahrheitsbild-Neuauflage =
  Extraktions-Retry am Verify-Signal).
- **#46 entblockt** (`blocked`-Label entfernt — #47 ist zu, die Issue-Templates sind
  eigener Scope, nichts blockiert mehr).

## Milestone-Bewertung

| Milestone | Stand | Verdikt |
|---|---|---|
| **v0.3.2 — Wahrheitsbild** (17 offen / 50 zu) | Nachschärf-Paket gelandet, E2E bewiesen. Der Milestone hat aber **zwei Tracks** absorbiert: (A) Modellvergleich/Mess-Infrastruktur, (B) Wahrheitsbild-v2-Projektionen + Kurations-Epic. | **Abschlusskriterium schärfen**: v0.3.2 endet mit Track A (Modellentscheidung dokumentiert + Baselines gefroren + #889 gefixt). Track B (#838/#840/#841/#842/#850/#851) → eigener Milestone „v0.4.0 — Wahrheitsbild v2" oder v1.1.0 (Diskussionspunkt). Sonst schließt v0.3.2 nie. |
| **v0.3.5 — Security-Audit-Followups** (2 offen / 4 zu) | Rate-Limits + Caps sind durch; Rest: #524 (JWT at-rest), #634 (Rotation-SOP). | Unverändert: als kleiner Block **vor** v1.0.0. |
| **v1.0.0 — Public Launch** (10 offen / 25 zu) | Kohärent; #766-Epic macht Fortschritt (I7-Buckets C/C2 gemerged). Kein Eintrag obsolet. | Unverändert lassen. |
| **v1.1.0 — Post-Launch** (14 offen / 3 zu) | Parkplatz funktioniert; #293 durch #872 ersetzt, #681 re-scoped. | Liegen lassen; #641 bei nächstem CI-Infra-Ärger vorziehen (die Infra-Kill-Serie der letzten Woche — 6 Kills auf einem einzigen PR — ist erneut die prognostizierte Manifestation). |

## Per-Issue-Bewertung

### v0.3.2 Track A — Modellvergleich + Mess-Infrastruktur (das Abschluss-Paket)

| # | Titel (kurz) | Gültig? | Reihenfolge / Begründung |
|---|---|---|---|
| #869 | Eval-Tasks übernehmen stale Settings | ✅ | **1.** Quick-Win. Messhygiene-Voraussetzung: ein Eval ist ein Messinstrument, kein Zustandsträger — vor jedem Sweep fixen, sonst kostet jeder Fehlalarm wieder eine Debug-Runde. |
| #889 | Stage-4/5-Render-Skalierung (neu) | ✅ | **2.** Akutes Loch: je besser die Kuration, desto sicherer stirbt das Resümee. Sabotiert sonst jede Kurations-Demo und verfälscht `eval.summary`-Messungen auf großen Sessions. |
| #874 | gpt-oss nicht lauffähig | ✅ ⬅️ v0.3.2 | **3.** Ohne Fix fehlt der Fakten-Ausbeute-Sieger als Sweep-Kandidat (Stage 2) und der stärkste lokale Judge-Kandidat neben gpt-oss:120b (Stage 3). Überschneidet sich mit #853 (endpoint/reasoning_effort-Knöpfe) — zusammen anfassen. |
| #841 | other_entities-Feld | ✅ Body neu | **4.** Teil der „Fakten-Modell v2"-Frage, die #856 pausiert hat — **vor** dem Judge-Sweep entscheiden (sonst wird der Judge gegen einen sich ändernden Achsen-Satz gewählt). Dazu gehört die fact_type-Multi-Label-Frage aus dem #840-Body. |
| #856 | Judge-Sweep GUI (pausiert) | ✅ | **5.** Wiederaufnahme nach dem Fakten-Modell-Entscheid. Branch `issue-856-judge-sweep` (2 Commits, Basis 037076f0) **vorher rebasen**. Neue Chance: die 550 verifizierten + 247 kuratierten Free-Seattle-Fakten als zweiter, realistischer Eval-Satz neben dem Doyle-Fixture. |
| #857 | Extraktor-Sweep | ✅ | **6.** Nach #856 (braucht den fixen Judge). |
| #858 | Modellentscheidung + Baseline-Freeze | ✅ | **7.** = v0.3.2-Abschluss. Gate-Mechanik existiert seit #837/#888; verbleibt Holdout-Methodik + Dokumentation (docs/llm-eval.md). |
| #853 | Per-Stage-Lauf-Optionen GUI | ✅ | Parallel möglich; von #874 praktisch vorausgesetzt (endpoint/num_predict/reasoning_effort pro Stage). |
| #852 | Admin-Modell-Katalog | ✅ | Nach #853 + #858 neu bewerten — die Sweep-Ergebnisse sind genau der Inhalt, den der Katalog tragen soll; vorher gebaut wäre er leer. |
| #859 | Cloud-Judge im Modellvergleich | ✅ | Backlog hinter #858. **Überschneidung mit #89** (Probelauf Cloud-Backends): beim Angehen zusammenlegen — beide bauen Cloud-Kandidaten + Kosten-Sichtbarkeit in Sweeps. |
| #854 | Epic Modellvergleich | ✅ | Rahmen; Slices 0 ✅, 1/2/3/5 offen. |

### v0.3.2 Track B — Wahrheitsbild v2 (Empfehlung: eigener Milestone)

| # | Titel (kurz) | Gültig? | Begründung |
|---|---|---|---|
| #687 | Nordstern Recall / null GM-Arbeit | ✅ bleibt | Abnahme-Rahmen, kein Bau-Issue. Der E2E-Stand erfüllt „lügt nicht" (0 geklemmt, Gate greift); „Recap automatisch bei den Spielern" (Slice A der Skizze) ist weiter ungebaut. |
| #851 | Epic Kuration überlebt Generierung | ✅ re-scoped | Fakt-Anker durch #861 erledigt (siehe Kommentar); Rest: Fakt-Aktionen (claim/Attribution/bestätigen), Strang-Anker, Prosa-Edit-Guards. **#842 zuerst** (beseitigt die Churn-Ursache, #851 das Symptom). |
| #842 | Inkrementelles Cluster-Capping | ✅ Body neu | Vor/mit dem #851-Strang-Anker; verhindert zugleich die Prompt-Wand des Voll-Re-Clusters (61 Labels nach wenigen Free-Seattle-Sessions). |
| #850 | Frag die Kampagne (Q&A) | ✅ | Projektion 1 der Fakten-Basis — „der Zahltag dafür, Fakten statt Prosa zu speichern". Nach #841 (Entitäts-Match braucht Nicht-Figur-Entitäten für „Was ist die Fotografie?"). |
| #838 | Prosa-Progressionen pro Strang | ✅ Body neu | Projektion 2; nur Arcs (#885). Erbt das #889-Skalierungs-Thema (Fakten-Liste pro Strang wächst). |
| #840 | Beziehungsgraph | ✅ | Projektion 3; der fact_type-Design-Anker im Body (single-select/lossy) fließt in den Fakten-Modell-v2-Entscheid ein. #783-Disziplin: erst bei belegtem Delta bauen. |

### v0.3.5 — Security-Audit-Followups (vor v1.0.0 als Block)

| # | Titel (kurz) | Gültig? | Begründung |
|---|---|---|---|
| #524 | Worker-JWT at-rest | ✅ | Optionen-Bewertung zuerst (kurzlebige Tokens vs. at-rest-Crypto vs. dokumentierter Trade-off). |
| #634 | Secrets-Rotation-SOP | ✅ | Doku; Abschluss der Welle. |

### v1.0.0 — Public Launch

| # | Titel (kurz) | Gültig? | Begründung |
|---|---|---|---|
| #766 | Epic Multi-Worker | ✅ | Launch-definierend; I7-Buckets C (#816/#822) + C2 (#824/#825) gemerged — weiter slicen. |
| #703 | Deploy-Gate bei laufender Aufnahme | ✅ | Silent-Failure-Klasse; mit echten Usern Pflicht. |
| #367 | Onboarding Release-Binary + Wizard | ✅ | Voraussetzung für #38 und jedes Nicht-Entwickler-Onboarding. |
| #38 | Worker Auto-Update | ✅ blocked #367 | Mechanik-Basis (#492/#500/#512/#516) existiert. |
| #17 | Mobile-GUI | ✅ | Spieler lesen am Handy — launch-kritisch. |
| #96 | Verschlüsselte Cloud-Backups | ✅ | Für Solo-Worker-Self-Hoster (kein Peer-Sync-Fallback). |
| #543 | Staging-E2E operative Pfade | ✅ | Die einzige ungetestete Fehlerklasse (operativ/Integration). |
| #625 | Deps-Bumps (Phoenix 1.8 …) | ✅ | Patches sofort, Major-Bumps eigene PRs. |
| #46 | Feature-Requests aus der App | ✅ entblockt | Klein (Redirect + Pre-Fill + Issue-Templates aus #47-Rest). |
| #67 | Accessibility-Basis | ✅ | Seit dem 07-09-Split sauber geschnitten (AA-Vollausbau = #769 in v1.1.0). |

### v1.1.0 — Post-Launch / Scale & Polish

| # | Titel (kurz) | Gültig? | Begründung |
|---|---|---|---|
| #872 | Pipeline-Arbeit verteilen | ✅ ⬅️ v1.1.0 | Ersetzt #293 (geschlossen). Natürlicher erster Schnitt: Gap-Fill + Eval-Läufe (strukturell konfliktfrei). Nach den #766-Slices. |
| #769 | WCAG 2.1 AA Vollausbau | ✅ blocked #17/#67 | Korrekt geparkt. |
| #681 | Iterative Selbstkorrektur | ⚠️ re-scoped | Kommentar 2026-07-22: Neuauflage = Extraktions-Retry am Verify-Signal; nach #858 neu bewerten. |
| #641 | CI-Konsolidierung + Cache | ✅ ⬆️ | Die Infra-Kill-Serie (Docker-Bridge/Daemon) der letzten Woche bestätigt die Prognose erneut — Kandidat fürs Vorziehen. |
| #575 | Rolle in Session-Cookie | ✅ | Perf-Cut. |
| #542 | Runtime-Observability | ✅ | Nach Launch wichtiger. |
| #541 | AsyncLiveView + Worker.Tasks | ✅ | Strukturelle Enforcement-Wrapper. |
| #539 | Event-Kind-Makro k/1 | ✅ | Präventionsklasse. |
| #445 | CampaignLive → LiveComponents | ✅ | Render-Isolation. |
| #401 | PubSub-Topic pro Campaign | ✅ | Bei Multi-Campaign-Last. |
| #356 | Scroll-Sync-Visualisierung | ✅ | UI-Polish. |
| #176 | LLM-Streaming | ✅ | UX-Polish Cloud. |
| #89 | Probelauf Cloud-Backends | ✅ | Bei Umsetzung mit #859 zusammenlegen (siehe oben). |
| #18 | i18n | ✅ | Diskussionspunkt DE/EN unten — unverändert offen seit 07-09. |

## Empfohlene Gesamt-Reihenfolge (nächste Wochen)

1. **Mess-/Render-Fundament:** #869 → #889 → #874 (+#853 im selben Zug).
2. **Fakten-Modell-v2-Entscheid:** #841 + fact_type-Frage (#840-Body) — kleiner Design-Entscheid,
   entsperrt #856.
3. **Modellvergleich zu Ende:** #856 (rebasen!) → #857 → #858 = Baselines frieren =
   **v0.3.2-Abschluss** (Track A).
4. **Track B** nach Toms Priorität: #842 → #851-Slices; #850/#838/#840 bei belegtem Bedarf.
5. **Security-Block v0.3.5:** #524 → #634.
6. **v1.0.0-Kern:** #766 weiter slicen, parallel #703, #367 → #38, #17, #543, #625, #96, #46, #67.

## Diskussionspunkte für Tom

- **v0.3.2-Abschlusskriterium + Track-B-Umzug:** Vorschlag oben (neuer Milestone
  „v0.4.0 — Wahrheitsbild v2" für #838/#840/#841/#842/#850/#851 — wobei #841 wegen der
  #856-Kopplung in v0.3.2 bleiben sollte). Braucht dein OK, Milestones lege ich nicht
  eigenmächtig an.
- **#18 vs. v1.0.0-Beschreibung** (seit 07-09 offen): Milestone verspricht „i18n DE+EN",
  #18 liegt in v1.1.0 — EN vorziehen oder Beschreibung auf DE-only kürzen.
- **Free-Seattle-Ground-Truth nutzen:** die 550 verifizierten + 247 kuratierten Fakten sind
  der erste **echte** (nicht-fixture) gelabelte Satz — als zweiter Judge-Eval-/Holdout-Satz
  für #856/#858 deutlich realistischer als Doyle allein. Export-Mechanik wäre ein kleiner
  Vorab-Schritt in #856.
- **#641 vorziehen?** Die CI-Infra-Kills kosten inzwischen real Merge-Latenz (6 Kills auf
  einem PR diese Woche). Wäre ein Vorzieh-Kandidat noch vor v1.0.0.
