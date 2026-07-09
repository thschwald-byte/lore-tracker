# Issue-Audit 2026-07-09

Löst `docs/issue-audit-2026-06-01.md` ab. Stichtag: nach dem **Wahrheitsbild-Default-Flip**
(#651 Phase C, PR #761, worker 0.104.0 auf Prod) und dem Free-Seattle-Referenz-Lauf
(command-r:35b, 2171 Utts: 281 Fakten → 192 grounded → 92 verifiziert).
45 offene Issues, 4 offene Milestones.

## Milestone-Bewertung

| Milestone | Stand | Verdikt |
|---|---|---|
| **v0.3.2 — Wahrheitsbild** (7 offen / 20 zu) | Mission im Kern erfüllt: Flip ist auf Prod. | **Umfokussieren auf „Nachschärfen"**: #651/#649/#686 schließen, #762/#763/#753/#689 rein, Abschluss-Kriterium = Recall-Re-Messung gegen #687/#689 nach den Tweaks. |
| **v0.3.5 — Security-Audit-Followups** (6 offen / 0 zu) | Kohärentes Paket, nichts obsolet. | Unverändert lassen; als Block **vor** v1.0.0 abarbeiten. |
| **v1.0.0 — Public Launch** (11 offen / 15 zu) | Enthält 2 fragwürdige Einträge (#47 obsolet, #67 zu fett) und es fehlen 3 unzugeordnete, launch-relevante Bugs (#698, #703, #758→757-Cluster). | Bereinigen + auffüllen, siehe unten. |
| **v1.1.0 — Post-Launch** (14 offen / 1 zu) | Parkplatz funktioniert. #426 ist durch den Flip obsolet, #681 braucht Re-Scope. | 1 schließen, 1 umformulieren, Rest liegen lassen. |

## Empfohlene Sofort-Aktionen (Tracker-Hygiene)

- **Schließen:** #651 (Flip vollzogen, Protokoll-Kommentar drin), #649 (strukturell gelöst
  durch Ep_n), #686 (Strategie-Befund dokumentiert, Verdikt lebt in #687/#689 weiter),
  #688 (Reflexions-Protokoll, kein Arbeitsauftrag), #426 (galt dem Chain-Reduce-Schritt —
  Chain ist seit dem Flip Legacy-Fallback), #47 (Repo ist bereits public; Restposten
  „Issue-Templates" in #46 ziehen).
- **Milestone zuweisen:** #689→v0.3.2, #753→v0.3.2, #698→v1.0.0, #703→v1.0.0,
  #757→v1.0.0, #758→v1.0.0.
- **Re-Scopen:** #681 (Selbstkorrektur galt Chain-Stage-2/4 — auf Wahrheitsbild-Pfad
  umformulieren: Extraktions-Retry am Verify-Signal), #67 (Basis-A11y nach v1.0.0,
  volle WCAG-AA nach v1.1.0 splitten), #38 (explizit als „blocked by #367" führen).

## Per-Issue-Bewertung

### v0.3.2 — Wahrheitsbild (nach Umbau: das Nachschärf-Paket)

| # | Titel (kurz) | Gültig? | Milestone-Fit | Reihenfolge / Begründung |
|---|---|---|---|---|
| #762 | Attributions-Judge unterkalibriert | ✅ | ✅ v0.3.2 | **1.** Größter Recall-Hebel: 100 grounded Fakten abgelehnt, Quote 33 %→~68 % möglich. Reiner Judge-Prompt-Fix, Eval-messbar. |
| #763 | num_predict-Deckel Extraktion | ✅ | ✅ v0.3.2 | **2.** Fixt 82 % der Laufzeit UND das 18-%-Datenloch (degenerierte Chunks). Klein, klarer Fix. |
| #753 | Kapitel-Edit + LWW-Guard | ✅ | ⬅️ neu v0.3.2 | **3.** Direktes Flip-Follow-up; ohne Guard zermahlt ein Re-Run GM-Edits (Datenverlust-Klasse). |
| #689 | Wahrheitszielbild (Risk-Coverage) | ✅ | ⬅️ neu v0.3.2 | **Messlatte**, kein Bau-Issue: Kriterienrahmen für die Re-Messung nach 1–3. |
| #687 | Gründungs-Use-Case (Recall, null GM-Arbeit) | ✅ | ✅ v0.3.2 | **Nordstern/Epic** — bleibt offen als Abnahme-Rahmen; Free Seattle zeigte: Wahrheit ✅, Recall noch ~⅓. |
| #724 | Epic Zeitstrahl/Datums-Auflösung | ✅ (Rest) | ✅ v0.3.2 | Slices A–E gebaut; offen: Review-Queue für undatierte Fakten. Free Seattle: dated=0 → Nutzen hängt an gesetzten Session-Ankern (📅), ggf. UI-Nudge als Mini-Slice. |
| #651 | Pipeline umstellen auf Wahrheitsbild | ✅ erledigt | — | **Schließen.** Flip 2026-07-08/09 vollzogen, Chain = Legacy-Fallback. |
| #649 | O(N²)-Wand Epos | ✅ erledigt | — | **Schließen.** Ep_n macht Kosten pro Session konstant. |
| #686 | Strategie-Befund Machbarkeit | dokumentiert | — | **Schließen.** Verdikt („GM-geprüfter Assistent, keine autonome Perfektion") ist in CLAUDE.md/#689 konserviert. |

### v0.3.5 — Security-Audit-Followups (vor v1.0.0 als Block)

| # | Titel (kurz) | Gültig? | Reihenfolge / Begründung |
|---|---|---|---|
| #629 | Rate-Limit auth/pair/invite | ✅ | **1.** Unauth DOS-Vektor mit Worker-Roundtrip pro Call — billigster Angriff. |
| #630 | Rate-Limit publish_intent | ✅ | **2.** Kompromittierter Worker flutet alle Member-Worker; token-bucket klein. |
| #636 | Server-side Längen-Caps | ✅ | **3.** Trivial umgehbare Client-Caps; kleine, mechanische Runde. |
| #632 | Spend-Cap-Härtung | ✅ | **4.** nil-Bypass ist der wichtigste Teil (unpaired Worker + API-Key = ungebremst). |
| #524 | Worker-JWT at-rest | ✅ | **5.** Physischer Zugriff nötig → geringste Dringlichkeit; Optionen-Bewertung zuerst. |
| #634 | Secrets-Rotation-SOP | ✅ | **6.** Doku; gut als Abschluss der Welle. |

### v1.0.0 — Public Launch (nach Bereinigung)

| # | Titel (kurz) | Gültig? | Milestone-Fit | Reihenfolge / Begründung |
|---|---|---|---|---|
| #757 | Multi-Track-Timeline first_chunk_at | ✅ | ⬅️ neu v1.0.0 | **Audio-Cluster 1.** Cross-Speaker-Drift verfälscht Transkript-Reihenfolge → vergiftet auch die Extraktion. War zuletzt in Arbeit (Parallel-Session). |
| #758 | AudioBuffer :write truncatet WebM | ✅ | ⬅️ neu v1.0.0 | **Audio-Cluster 2.** Echter Datenverlust im Live-Betrieb — mit #757 zusammen anfassen. |
| #469 | WebM-Re-Header beim Auto-Resume | ✅ (Verdacht) | ✅ v1.0.0 | **Audio-Cluster 3.** Gleiche Subsystem-Baustelle; Repro zuerst. |
| #698 | Cross-Store-Replay-Zombies | ✅ | ⬅️ neu v1.0.0 | Frische-Worker-Sync muss stimmen, **bevor** #766 Multi-Worker zum Normalfall macht. |
| #703 | Deploy-Gate bei laufender Aufnahme | ✅ | ⬅️ neu v1.0.0 | Silent-Failure-Klasse (Transkript-Lücken durch Auto-Deploy); mit echten Usern Pflicht. |
| #766 | Epic Multi-Worker-Architektur | ✅ | ✅ v1.0.0 | Launch-definierendes Epic; nach dem Audio-Cluster + #698 slicen. |
| #367 | Onboarding Release-Binary + Wizard | ✅ | ✅ v1.0.0 | Ohne das kein Nicht-Entwickler-Onboarding; Voraussetzung für #38. |
| #38 | Worker Auto-Update Self-Hosted | ✅ (blocked) | ✅ v1.0.0 | Blocked by #367; Mechanik-Basis (#492/#500/#512/#516) existiert für Maintainer-Setup. |
| #17 | Mobile-GUI | ✅ | ✅ v1.0.0 | Spieler lesen am Handy — launch-kritisch. Nach dem Wahrheitsbild-Paket einplanbar. |
| #96 | Verschlüsselte Cloud-Backups | ✅ | ✅ v1.0.0 | Für Solo-Worker-Self-Hoster (kein Peer-Sync als Fallback) relevant. |
| #543 | Staging-E2E operative Pfade | ✅ | ✅ v1.0.0 | Deckt die einzige ungetestete Fehlerklasse (operativ/Integration); vor dem Launch-Rush. |
| #625 | Deps-Bumps (Phoenix 1.8 …) | ✅ | ✅ v1.0.0 | Vor Public-Launch; Patches sofort machbar, Major-Bumps eigene PRs. |
| #46 | Feature-Requests aus der App | ✅ | ✅ v1.0.0 | Klein (Redirect + Pre-Fill); Issue-Template-Rest aus #47 hier miterledigen. |
| #47 | Public-Repo-Übergang | ❌ obsolet | — | **Schließen** — Repo ist public (seit AGPL #477/CI-Grant); Restposten → #46. |
| #67 | WCAG 2.1 AA | ✅ (zu fett) | ✂️ splitten | Basis (Keyboard, Kontrast, Alt-Texte) → v1.0.0; volle AA-Compliance → v1.1.0. |

### v1.1.0 — Post-Launch / Scale & Polish

| # | Titel (kurz) | Gültig? | Begründung |
|---|---|---|---|
| #681 | Iterative Selbstkorrektur Stage 2+4 | ⚠️ Re-Scope | Galt der Chain; sinnvolle Neuauflage = Extraktions-Retry am Verify-Signal (nach #762/#763 neu bewerten). |
| #426 | Map-Reduce Reduce verdichtet nicht | ❌ obsolet | Chain-spezifisch; seit dem Flip Legacy-Fallback ohne Weiterentwicklung. **Schließen.** |
| #641 | CI-Konsolidierung + R2-Cache | ✅ ⬆️ dringlicher | Runner-Infra-Kills (Pipelines 445/449/450/452 am 08./09.07.) sind genau die prognostizierte Manifestation; Bridge-IP-Exhaust wird durch weniger Container direkt gelindert. Kandidat für Vorziehen nach v1.0.0. |
| #539 | Event-Kind-Makro k/1 | ✅ | Präventionsklasse, kein Termindruck. |
| #541 | AsyncLiveView + Worker.Tasks Wrapper | ✅ | Strukturelle Enforcement-Wrapper; gut nach dem nächsten LV-Neubau. |
| #542 | Runtime-Observability Silent-Failures | ✅ | Wird mit echten Usern wichtiger; nach Launch. |
| #575 | Rolle in Session-Cookie | ✅ | Perf-Cut, hängt an keinem Launch-Kriterium. |
| #445 | CampaignLive → LiveComponents | ✅ | Render-Isolation; nach #442-Erfahrung. |
| #401 | PubSub-Topic pro Campaign | ✅ | Erst bei Multi-Campaign-Last relevant. |
| #356 | Scroll-Sync-Visualisierung | ✅ | UI-Polish. |
| #293 | Job-Verteilung auf freie Worker | ✅ | Nach #766-Epic neu bewerten (überschneidet sich mit dessen Verteilungs-Slices). |
| #176 | LLM-Streaming | ✅ | UX-Polish für Cloud-Backends. |
| #89 | Probelauf Cloud-Backends | ✅ | Probelauf ist seit #764-Flip chain-gepinnt; bei Umsetzung Wahrheitsbild-Probelauf mitdenken. |
| #18 | i18n | ✅ | Launch DE-only ist ok (v1.0.0-Beschreibung nennt DE+EN — Entscheidung nötig: EN in #18 vorziehen oder v1.0.0-Beschreibung anpassen). |

## Empfohlene Gesamt-Reihenfolge (nächste Wochen)

1. **Wahrheitsbild nachschärfen:** #762 → #763 → Recall-Re-Messung (Eval #685-Mechanik +
   Free-Seattle-Re-Run) gegen #687/#689 → #753.
2. **Audio-Korrektheits-Cluster:** #757 → #758 → #469 (ein Subsystem, eine Session).
3. **Sync-Härtung:** #698 (vor Multi-Worker-Normalfall).
4. **Security-Welle v0.3.5:** #629 → #630 → #636 → #632 → #524 → #634.
5. **v1.0.0-Kern:** #766-Epic slicen, parallel #367 → #38, dazu #17, #703, #543, #625, #96, #46, #67-Basis.
6. **Danach:** v1.1.0-Parkplatz, #641 bei nächstem CI-Ärger vorziehen.

## Diskussionspunkte für Tom

- **#18 vs. v1.0.0-Beschreibung:** Milestone verspricht „i18n DE+EN", #18 liegt aber in
  v1.1.0. Entweder EN-Minimalausbau nach v1.0.0 ziehen oder die Milestone-Beschreibung
  ehrlich auf DE-only kürzen.
- **#67-Split** braucht dein OK (Basis jetzt, AA komplett später).
- **#762-Erwartung:** Auch nach Judge-Fix bleibt die Grounding-Decke (~68 %) — „dünn,
  aber wahr" ist Stand heute der Designzustand; volle Recall-Parität mit der (lügenden)
  Chain ist nicht das Ziel (#689-Rahmen).
