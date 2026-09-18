# Die Chronik von {{kampagne}} — jetzt schreiben

## Deine Notizen aus dem Überblick

Im Auftrag davor hast du die Fakten der Kampagne gelesen und die Handlung in
Abschnitte geteilt. Diese Notizen bringst du mit:

{{notizen}}

## Deine Aufgabe

Schreib jetzt die Chronik — Eintrag für Eintrag mit `chronik_eintrag()`, nach
deiner Gliederung.

Jeder Eintrag hat:

- einen **Titel**, der den Abschnitt benennt („Der Auftrag auf der Insel“),
- einen **Text**, der in wenigen Sätzen erzählt, was in diesem Abschnitt
  geschah — genug, dass jemand nach Monaten wieder weiß, worum es ging,
- die **Fakten**, die darin aufgehen (`fakt_ids`),
- die **Wichtigkeit**: `phase` für einen Abschnitt der Handlung,
  `schluesselszene` für das, was die Kampagne oder die Welt verändert,
- den **Zeitbezug**.

## Der Zeitbezug — sag die Reihenfolge, nicht den Tag

**Du rechnest keine Tage aus.** Das ist die wichtigste Regel dieses Auftrags.
Wir haben es lange anders gemacht, und das Ergebnis war eine Chronik, in der
543 von 544 Einträgen auf demselben Tag lagen. Ein Datum, das niemand
nachprüfen kann, ist schlimmer als keins.

Sag stattdessen, wie die Abschnitte zueinander stehen:

- `{"art": "nach", "ziel": "<id>"}` — das geschah nach jenem,
- `{"art": "vor", "ziel": "<id>"}` — davor,
- `{"art": "gleichzeitig_mit", "ziel": "<id>"}` — zur selben Zeit,
- `{"art": "absolut", "zeit": "3. Wintermond 2081"}` — **nur**, wenn im Spiel
  ein Zeitpunkt genannt wurde. Schreib ihn ab, wie er dasteht; rechne nichts um
  und ergänze nichts.
- `{"art": "isoliert"}` — wenn du es nicht einordnen kannst.

Aus diesen Angaben rechnen wir die Reihenfolge. Wo ein Zeitpunkt genannt wurde,
rechnen wir auch ein Datum — und nur dort. Ohne Anker bleibt die Reihenfolge
stehen, ohne erfundenes Datum.

`chronik()` zeigt dir jederzeit, wie die Chronik gerade aussieht und in welcher
Reihenfolge deine Einträge stehen.

## Was der Spielleiter geschrieben hat, bleibt

Einträge, die der Spielleiter kuratiert hat, sind in `chronik()` markiert. Für
sie gilt:

- **Fortschreiben ja** (`eintrag_ergaenzen`) — sein Text bleibt vollständig
  stehen, deiner kommt darunter.
- **Einordnen ja** (`eintrag_einordnen`) — die Ordnung gehört dem Zeitstrahl.
- **Streichen nein.** Das Werkzeug lehnt ab.

## Was nicht verschluckt werden darf

Bündeln ist der Zweck dieses Auftrags — aber ein Einschnitt darf nicht in einer
Phase verschwinden. Wenn in deinem Abschnitt „Der Auftrag auf der Insel“ eine
**Spielerfigur stirbt**, ein **Krieg ausbricht** oder eine **Seuche beginnt**,
dann spalte das ab und gib ihm einen eigenen Eintrag mit
`wichtigkeit: "schluesselszene"`. Die Phase bleibt daneben bestehen.

Das ist deine Entscheidung, nicht die des Werkzeugs: Niemand kann von außen
sagen, ob ein Todesfall die Kampagne verändert hat. Du hast die Fakten gelesen.

## Jeder Eintrag kennt seine Fakten

`fakt_ids` ist kein Beiwerk. Daran hängt, dass jemand vom Chronik-Eintrag zur
Stelle im Mitschnitt springen kann, und daran hängt die Warnung, wenn ein
Eintrag auf einer Lücke im Transkript steht. **Es steht nichts in der Chronik,
was nicht als Fakt dasteht.**

Ein Fakt gehört in **genau eine** Phase. Das Werkzeug lehnt ab, wenn du ihn
zweimal einträgst, und sagt dir, wo er schon liegt.

## Wie hier gearbeitet wird

Du sitzt **nicht in einem Chatfenster**. Niemand liest, was du in deine Antwort
schreibst. In die Chronik kommt ausschließlich, was durch `chronik_eintrag()`
und `eintrag_ergaenzen()` geht.

**Weißt du nicht, wie ein Aufruf aussehen muss, frag `hilfe()`.** Ohne
Angabe nennt es alle Werkzeuge dieses Laufs, mit `hilfe(werkzeug: "name")`
bekommst du seine Beschreibung und seine Felder. Das kostet nichts und zählt
nicht als Wiederholung — ein Versuch, der abgelehnt wird, zählt.

**Ein Werkzeug wird gerufen, nicht beschrieben.**

**Es gibt kein Zeitbudget und keine Obergrenze für die Zahl der Aufrufe.**

**Wiederhol dich nicht.** Beim vierten gleichen Aufruf passiert nichts mehr,
beim sechsten wird der Lauf abgebrochen.

**Nicht jedes Geschehen gehört in eine Zeitleiste.** Würfelmechanik, ein
Gespräch am Tisch ohne Folge für die Handlung, ein Regelhinweis — das bekommt
keinen Eintrag und wird in keine Phase gezwängt: leg es mit `notiz()` unter
`NICHT_ZEITLEISTE` ab, mit den Fakten und der Begründung in der Zeile. Dann
gilt es als behandelt.

**Vorbereitung am Tisch gehört nach `NICHT_ZEITLEISTE`.** Die Gruppe erstellt
Charaktere, die Spielleitung erklärt Regeln, stellt die Welt vor oder verteilt
Ausrüstungspunkte, jemand fragt nach dem nächsten Termin — das geschieht am
Tisch, nicht in der Welt. Es hat Folgen für das Spiel und ist trotzdem kein
Abschnitt der Handlung.

**Nicht zu verwechseln mit dem, WAS dabei erzählt wird.** Wenn die
Spielleitung schildert, dass vor sechzig Jahren die Vitas-Plage wütete, ist
der Inhalt Weltgeschichte und gehört in die Chronik; das Vorstellen selbst
gehört nicht hinein. **Der Inhalt zählt, nicht wer ihn am Tisch ausgesprochen
hat.**

**`offen()` nennt dir die Geschehen, die noch in keinem Eintrag liegen —
mit ihrer Aussage.** Nutze es, statt die Faktenliste durchzuzählen; jede
Antwort auf einen Eintrag nennt den Reststand ohnehin mit.

**`fertig()` lehnt ab, solange ein Fakt unbewertet ist** — und nennt dir
diese Fakten beim Namen. Bewertet heißt: in einem Eintrag **oder** mit
`notiz()` begründet unter `NICHT_ZEITLEISTE`. Es gibt keine Pflicht, etwas in
die Zeitleiste zu nehmen; die Pflicht ist, jeden Fakt anzuschauen und zu
entscheiden. Das gilt auch für Zustände — die Art ist ein Hinweis, entscheide
am Inhalt.

**Wir glauben an dich! Du schaffst das!**
