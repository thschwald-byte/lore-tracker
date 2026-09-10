# Entscheidung: Jack — pi behalten, pi einbetten oder in Elixir nachbauen

Stand 2026-09-09. Entwurf von dave für Tom. Status: **offen, Entscheidung bei Tom.**

> **Änderung gegenüber der ersten Fassung.** Die erste Fassung kannte zwei Wege
> und empfahl den Nachbau. Auf Toms Frage „was von pi benutzen wir eigentlich
> nicht?“ ist ein dritter Weg dazugekommen, der die beiden anderen schlägt:
> **pi als Bibliothek einbetten** statt als Programm zu betreiben. Die
> Empfehlung hat sich damit geändert.

## 1. Worum es geht

Der Spike #1174 (Epic #1172) hat gezeigt, dass ein Harness mit Werkzeugen
(pi + qwen3.8:27b, künftig „Jack“) die Fakten-Extraktion einer Session tragen
kann. Tom will damit die heutigen Einzelaufrufe an Ollama für **Extraktion
(Stufe 2)** und **Verify (Stufe 3)** ersetzen und dabei einen schlanken Stack
behalten: Erlang/Elixir/Phoenix.

## 2. Was heute läuft

Alle LLM-Aufrufe des Workers gehen durch `Worker.LLM.complete/3`
(`apps/worker/lib/worker/llm.ex:50`); auf Prod stehen alle vier Stufen auf
`:local` gegen Ollama, mit JSON-Schema-Zwang. Ein Aufruf, ein Prompt, eine
Antwort, kein Werkzeug. Verify ist **ein Aufruf pro Fakt** für Grounding und
einer für Attribution, bei 200 Fakten rund 400 Aufrufe.

Ersetzt würden vier Aufrufstellen: `stages.ex:103` und `:309` (Extraktion),
`verify.ex:231` und `:371` (Verify). Render, Gap-Fill und die beiden
Registry-Clusterings bleiben.

## 3. Wie groß pi wirklich ist — und welcher Teil davon uns dient

Gemessen am installierten Stand im Sandkasten (Version 0.85.1, transpiliertes
`dist/`, nicht Quelltext):

| Paket | Zeilen JS | Wovon wir Gebrauch machen |
|---|---:|---|
| `pi-coding-agent` (CLI, Werkzeuge, Sitzungen, Skills, Kompaktierung) | 51.151 | fast nichts, außer der Kompaktierung (1.064), s. Abschnitt 5 |
| `pi-ai` (Provider-APIs) | 18.285 | ein Provider von vielen; `openai-completions.js` allein hat 1.356 |
| `pi-agent-core` (Schleife, Werkzeugausführung) | 16.335 | **das ist der Teil, um den es geht**; `agent-loop.js` 559 + `agent.js` 421 |
| `pi-tui` (Terminal-Oberfläche) | 14.775 | null, der Lauf ist kopflos |
| **Summe** | **100.546** | |

Was `agent-loop.js` tatsächlich tut, steht in seinen Funktionsnamen:
`runLoop`, `streamAssistantResponse`, `executeToolCalls` (parallel und
sequenziell), `prepareToolCallArguments`, `createErrorToolResult`,
`failToolCallsFromTruncatedMessage`, `shouldTerminateToolBatch`, dazu das
Zusammensetzen der Stream-Häppchen (`text_delta`, `thinking_delta`,
`toolcall_delta`). Das ist die vollständige Liste dessen, was eine Schleife
können muss. Sie ist überschaubar, und sie ist nicht das Produkt.

**Antwort auf „sonst gäbe es sie ja nicht“:** pi verkauft nicht die Schleife.
pi verkauft 20+ Provider mit ihren Eigenheiten, eine Terminal-Oberfläche,
Sitzungen mit Verzweigung, Skills, Erweiterungen, MCP, Berechtigungen,
Unteragenten, Bild- und Diff-Anzeige. Für einen Menschen am Terminal ist das
das Produkt. Für einen Batch-Job mit acht Werkzeugen und einem Modell ist es
Beiwerk.

### Lizenz: MIT, und was das für uns heißt

pi steht unter der **MIT-Lizenz**, „Copyright (c) 2025 Mario Zechner“,
Standardtext mit der Erlaubnis zu „use, copy, modify, merge, publish,
distribute, sublicense“ und der einen Auflage, dass Copyright- und
Lizenzvermerk „in all copies or substantial portions of the Software“ erhalten
bleiben. Die Lizenz-RFC 0015 der Firma sagt zusätzlich zu, dass das so bleibt.
LoreTracker steht unter **AGPL-3.0**. MIT ist damit verträglich: MIT-Code darf
in ein AGPL-Projekt übernommen werden, umgekehrt nicht.

Praktisch, in vier Abstufungen:

| Was wir tun | Erlaubt | Auflage |
|---|---|---|
| Code lesen, um zu verstehen | ja | keine |
| Architektur und Ideen übernehmen | ja | keine, Lizenzen schützen keine Ideen |
| Struktur in Elixir nachbauen, Vorbild erkennbar | ja | Vermerk setzen, auch wenn strittig wäre, ob es ein abgeleitetes Werk ist |
| Zeilen wörtlich portieren | ja | Copyright- und Lizenzvermerk zwingend |
| pi als Abhängigkeit einbinden (A′) | ja | Vermerk, sobald wir es mit ausliefern |

Wo der Vermerk hingehört: bei einer Portierung in den Kopf des Moduls, dazu der
MIT-Text im Repo. Bei A′ reicht der übliche Weg über die Paketverwaltung,
solange wir pi nicht ins Repo legen; legen wir es hinein, kommt die
LICENSE-Datei mit. **Spicken ist also ausdrücklich erlaubt**, und die billigste
Haltung ist, den Vermerk auch dann zu setzen, wenn man nur die Struktur
übernommen hat. Er kostet drei Zeilen und beendet jede spätere Diskussion.

**Ehrliche Grenze:** das ist meine Lesart der Lizenztexte, keine
Rechtsberatung.

## 4. Was Jack im Spike benutzt hat

Lauf 11, aus dem Ereignisstrom gezählt:

| Werkzeug | Aufrufe |
|---|---:|
| `aussage` | 53 |
| `bloecke` | 32 |
| `notiz` | 14 |
| `suche` | 12 |
| `cast`, `straenge`, `notizen_lesen` | je 1 |

Alle sieben sind **unsere** Werkzeuge aus `werkzeuge.ts`. Von pis eingebauten
Werkzeugen (`bash`, `read`, `write`, `edit`, `glob`, `grep`) kam in diesem Lauf
**keines** vor.

Dazu eine Zahl, die ich nicht erklären kann: der Torwächter hat 1.114 Anfragen
an `/v1/chat/completions` gezählt, bei 169 Modell-Nachrichten. Rund sechs
Anfragen je Nachricht. Ob das Streaming-Wiederaufnahmen, Zählabfragen oder eine
Eigenheit der Zählung sind, ist ungeprüft. Es gehört nachgesehen, bevor jemand
daraus etwas ableitet.

## 5. Kompaktierung: was pi tut, und eine Korrektur

„Kompaktierung“ ist nicht eine Sache. Drei Ebenen sind zu unterscheiden.

**pi hat zwei Mechanismen**, die dasselbe Format benutzen: *Compaction*, wenn
der Kontext die Schwelle reißt oder `/compact` gerufen wird, und
*Branch-Summarization* bei `/tree`-Navigation. Compaction kennt drei Anlässe:
`manual`, `threshold`, `overflow`.

**Der Ablauf ist festgelegt.** Ausgelöst wird bei
`contextTokens > contextWindow − reserveTokens`, bei unseren Einstellungen also
bei 94.208 von 98.304. Dann wird vom neuesten Eintrag rückwärts gezählt, bis
`keepRecentTokens` voll ist (bei uns 8.000); alles davor geht in **einen
zusätzlichen LLM-Aufruf**, der eine Zusammenfassung in festem Markdown schreibt:
Goal, Constraints, Progress (Done / In Progress / Blocked), Key Decisions,
Next Steps, Critical Context, dazu gelesene und geänderte Dateien.

**Was das in Lauf 11 gekostet und geliefert hat:**

| | |
|---|---:|
| Kontext vor der Kompaktierung | 95.608 Token |
| danach | 8.970 Token |
| Zusatz-Aufruf ans Modell | 52.299 rein, 1.814 raus |
| Länge der Zusammenfassung | 3.255 Zeichen |

**Korrektur.** In der ersten Fassung stand, pis Zusammenfassung sei der
Schwachpunkt: sie beginne mit „No prior history“ und beschreibe die Sitzung als
abgeschlossen. Ich hatte das übernommen, ohne den Wortlaut zu lesen. Er hält
das nicht: „No prior history“ heißt, dass es **keine frühere Zusammenfassung**
gab, die iterativ fortgeschrieben werden könnte. Der Text danach ist korrekt und
brauchbar — er nennt den Auftrag, den gelesenen Inhalt, die Cast- und
Strang-Listen, die `notiz()`-Falle, die eingetragenen Aussagen, die
Zahlungs-Korrektur von 10.000 auf 8.000, die drei widersprüchlichen Uhrzeiten,
und er endet mit „Next statements to record start around block 349“ und einer
Liste von rund 45 geplanten Aussagen. Auch die scheinbare Untertreibung „10
statements recorded“ ist richtig: die Aussagen 11 bis 38 lagen in den behaltenen
8.000 Token und mussten nicht zusammengefasst werden.

**Damit fällt ein Argument weg und ein anderes bleibt.** Weg ist „pis
Zusammenfassung führt den Agenten in die Irre“. Geblieben sind zwei sachliche
Gründe für eine eigene, deterministische Fassung: sie kostet keinen zweiten
großen Modellaufruf, und sie ist reproduzierbar, weil sie aus Daten gebaut wird,
die das Werkzeug ohnehin führt (Gerüst, Zahl der Aussagen, höchster belegter
Block, nächster Schritt). Das ist eine Optimierung, kein Fix.

**Und die Diagnose zum Einbruch ist damit offen.** Lauf 11 lief regulär zu Ende
(`agent_end`, letzte Aussage aus Block 1709 von 1801), die Zusammenfassung war
gut, der Plan stand darin, und der Agent hat danach weitergelesen — trug aber
statt der geplanten 45 nur 13 weitere Aussagen ein. Woran das liegt, ist nicht
geklärt; „die Kompaktierung war schuld“ trägt als Erklärung nicht mehr.

## 6. Der Fund: wir betreiben die CLI, obwohl es die Bibliothek gibt

Die VM ist da, weil pi als **Programm** ein Coding-Agent mit Shell und
Dateisystem ist. Genau diese Fähigkeiten wollen wir nicht, und Jack hat sie
nachweislich nicht benutzt. pi kann sie abschalten, und pi lässt sich einbetten:

- `docs/sdk.md`: `createAgentSession({...})` startet eine kopflose Sitzung im
  eigenen Node-Prozess, mit `customTools` für eigene Werkzeuge.
- `noTools: "all"` schaltet **alle** Werkzeuge ab, `noTools: "builtin"`
  schaltet die eingebauten ab und behält Erweiterungs- und eigene Werkzeuge.
  `excludeTools` entfernt einzelne. `tools: [...]` ist eine Positivliste.
- `docs/settings.md`: „An empty array starts with no built-in tools while
  preserving extension tools.“

Damit ist die Isolationsfrage eine andere: ohne `bash`, `read`, `write` gibt es
keinen Dateisystem- und keinen Prozesszugriff mehr, den man einsperren müsste.
Was bleibt, ist ein Node-Prozess, der Ollama anruft und unsere acht Funktionen
aufruft.

## 7. Die drei Wege

**A — pi als CLI in der VM.** Der heutige Aufbau, produktiv gemacht: stehende
VM, Auftrags- und Ergebniskanal, Herzschlag, Abbild-Versionierung, Torwächter.

**A′ — pi als Bibliothek im Worker-Umfeld.** Ein kopfloser Node-Prozess neben
whisper, ffmpeg und piper, gestartet vom Worker, mit `noTools: "builtin"` und
unseren acht Werkzeugen, Ollama direkt. Keine VM, kein Kanalbau. Absicherung
über `systemd-run` als eigener Benutzer, wie eve es für die VM gebaut hat.

**B — Jack in Elixir.** Werkzeuge werden `Worker.Repo`-Aufrufe, die Schleife
läuft auf `Worker.LLM.Local`, die Kompaktierung wird deterministisch.

| Kriterium | A: CLI in VM | A′: pi eingebettet | B: Elixir |
|---|---|---|---|
| Stack im Betrieb | Elixir + Node-VM + Python + TS | Elixir + Node + TS | Elixir |
| Gemessenes Verhalten | vorhanden | **derselbe Loop, derselbe Provider** | neu zu messen |
| Isolation | VM, Torwächter | keine Shell, dazu systemd-Sandbox | nichts, wovor zu schützen wäre |
| Neu zu bauen | Kanäle, Herzschlag, Abbild, Import | Prozessstart, stdio-Vertrag, Import | Schleife, Kompaktierung, Werkzeug-Portierung |
| Fremdcode | pi + Node + QEMU | pi + Node | keiner |
| Werkzeugänderung | in TS, plus Abbild neu | in TS | in Elixir, eine Sprache |
| Zweiter Worker (#766) | Abbild je Maschine | Node je Maschine | nichts Zusätzliches |
| Kompaktierung | pi, brauchbar, ein Zusatz-Aufruf; per Hook ersetzbar | dito | eigene, deterministisch, ohne Zusatz-Aufruf |
| Risiko | VM hängt, Kanal reißt, Drift | pi-Versionen, Systemprompt-Rest | Verhalten unbekannt |
| Aufwand initial | hoch, fast nur Betrieb | **niedrig** | mittel, plus zwei Messläufe |

## 8. Empfehlung

**A′ zuerst, B als Option danach.** Begründung: A′ behält das gemessene
Verhalten vollständig, weil derselbe Loop und dieselbe Provider-Schicht laufen,
und wirft trotzdem den gesamten VM-Betrieb weg, der in keiner Messung vorkam.
Der Schritt ist klein: Prozessstart, ein stdio- oder Datei-Vertrag, der Import
ins `SessionFactsExtracted`. Genau der Import wird bei B ohnehin gebraucht.

B bleibt danach jederzeit möglich und ist dann billiger als heute, weil
Werkzeuge, Vertrag und Import bereits stehen und nur die Schleife wechselt. Ob
sich das lohnt, entscheidet ein Vergleichslauf, nicht eine Meinung.

Reihenfolge:

0. **Zuerst im Spike klären, vor jedem Bau.** Die einzige offene Frage an A′ ist
   eine Messfrage: verhält sich der SDK-Pfad wie die CLI? Sie ist im Sandkasten
   billig zu beantworten, weil dort alles steht: dieselbe VM, dieselben Blöcke,
   derselbe Torwächter als Messinstrument. Statt `pi` als Programm läuft ein
   kleines Node-Skript mit `createAgentSession`, `noTools: "builtin"` und
   unseren Werkzeugen aus `werkzeuge.ts`. **Bedingung: fester Prompt.** Sonst
   variieren Unterbau und Prompt gleichzeitig, und der Lauf ist so wenig
   zuordenbar wie v9 und v12. Der Kalibrierungslauf (v12 oder v13 ein zweites
   Mal, für das Rauschmaß) ist der natürliche Rahmen: derselbe Prompt einmal
   über die CLI, einmal über das SDK. Kosten: ein Lauf, rund 30 Minuten.
   Derselbe Lauf beantwortet nebenbei die zweite offene Frage, welchen
   Systemprompt pi im SDK-Pfad voranstellt; das steht im Ereignisstrom.
   **Was der Spike NICHT klären muss:** ob sich ein Node-Prozess ohne VM
   starten lässt. Das ist keine Erkenntnisfrage.
1. **A′ bauen.** Node-Prozess mit `createAgentSession`, `noTools: "builtin"`,
   unsere Werkzeuge; Worker startet ihn unter der GpuQueue mit Frist,
   Fortschritt über die zählbaren Aussagen ins Laufband.
2. **Ein Lauf auf S1** gegen Lauf 12, gleiche Messgrößen. Er soll bestätigen,
   dass der eingebettete Pfad dasselbe liefert wie der VM-Pfad.
3. **Import und Umschaltung.** Backend `:jack` für Stufe 2 hinter
   `Worker.LLM.complete/3`, Verify fällt darin zusammen, je Stufe schaltbar.
4. **B nur, wenn Node stört.** Dann Schleife nachbauen und gegen die dann
   vorliegenden A′-Zahlen messen; Abbruchkriterium vorab, Vorschlag: unter
   80 % der belegten Aussagen wird nicht getunt, sondern A′ bleibt.

**B gehört ausdrücklich nicht in den Spike.** Für A′ ist die offene Frage eine
Messung, für B ist sie erst nach einem Tag Bauarbeit messbar. Ein Spike-Schritt,
der zuerst einen Loop schreiben muss, ist kein Spike mehr, sondern die
Umsetzung. Und wenn A′ trägt und Node niemanden stört, braucht es B nie.

## 9. Ehrliche Grenzen

- **A′ ist nicht gemessen.** Dass `noTools: "builtin"` und der SDK-Pfad sich
  genauso verhalten wie die CLI im Spike, steht in der Doku, nicht in einem
  Lauf. Schritt 2 existiert genau deshalb.
- **Der Systemprompt ist offen.** pi stellt der Sitzung eigene Anweisungen
  voran; wie viel davon im SDK-Pfad bleibt und ob es abschaltbar ist, habe ich
  nicht geprüft. Bleibt ein Coding-Vorspann stehen, verändert er das Verhalten
  gegenüber dem Spike.
- **Restrisiko ohne VM.** Ein Fehler in pi oder eine falsch gesetzte Option
  bringt eingebaute Werkzeuge zurück. Die systemd-Sandbox deckt das ab, eine VM
  deckt es besser ab. Das ist eine Abwägung, keine Gleichheit.
- **In allen drei Wegen** werden Extraktor und Prüfer derselbe Agent. #783
  hatte Verify bewusst als zweites Modell getrennt. Die mechanische Belegpflicht
  im Werkzeug ist für Grounding stärker als der heutige LLM-Richter,
  Attribution bleibt Modellurteil. Das gehört in die CLAUDE.md.
- **Meine erste Empfehlung war zu schnell.** Ich hatte den Sandkasten als
  gegeben genommen und daraus geschlossen, pi gehe nur mit VM. Toms Frage nach
  dem Ungenutzten hat den Fehler aufgedeckt.

## 10. Was Tom entscheidet

- A, A′ oder B als erster Schritt.
- Ob die systemd-Sandbox als Ersatz für die VM genügt.
- Ob die Aufgabe der Extraktor/Prüfer-Trennung aus #783 so gewollt ist.

Entscheidung: ______  Datum: ______

## 11. Quellen

- pi: <https://github.com/earendil-works/pi> (MIT, 103.344 Sterne, Push 2026-09-09, 149 offene Issues) · Lizenz-RFC: <https://rfc.earendil.com/0015/>
- pi-Doku lokal: `sharp-solution/opt/pi/node_modules/@earendil-works/pi-coding-agent/docs/{sdk,settings,extensions,compaction}.md`
- Ollama Tool Calling: <https://docs.ollama.com/capabilities/tool-calling> · Issue <https://github.com/ollama/ollama/issues/14601>
- Elixir: <https://github.com/brainlid/langchain> · <https://github.com/agentjido/req_llm> · <https://hexdocs.pm/ollama>
- Muster: <https://ampcode.com/notes/how-to-build-an-agent> · <https://www.anthropic.com/engineering/building-effective-agents>
- Eigene Messungen: `~/Projekte/.lore-messungen/1174-s1-extraktion/` (Läufe 5–12)
