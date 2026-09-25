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
- `{"art": "absolut", "zeit": "3. Wintermond 1147"}` — **nur**, wenn im Spiel
  ein Zeitpunkt genannt wurde. Schreib ihn ab, wie er dasteht; rechne nichts um
  und ergänze nichts.
- `{"art": "isoliert"}` — wenn du es nicht einordnen kannst.

Aus diesen Angaben rechnen wir die Reihenfolge. Wo ein Zeitpunkt genannt wurde,
rechnen wir auch ein Datum — und nur dort. Ohne Anker bleibt die Reihenfolge
stehen, ohne erfundenes Datum.

## Die Zeitlinie ist ein Angebot — prüfe sie, bevor du sie nimmst

An manchen Fakten steht **`Zeitlinie: …`**. Das kommt von einem anderen Lauf:
Er geht den Mitschnitt durch, sucht Zeitangaben im Gesprochenen und ordnet die
Äußerungen in eine Kette. Was er gefunden hat, siehst du am Fakt, mit
Herkunft:

- **`Zeitlinie: 24. Dezember 2011 belegt mit „Ryumyo erwacht am Fuji"`** — dort
  wurde diese Zeit gesagt, und das ist das Zitat.
- **`Zeitlinie: 1. August 2020 (gerechnet)`** — dort wurde **nichts** gesagt.
  Der Wert liegt zwischen zwei Ankern und ist gleichmäßig verteilt: eine
  Schätzung, keine Fundstelle.
- **`⚠ …`** dahinter heißt, dass der andere Lauf selbst gezweifelt hat.

**Meistens ist die Zeitlinie die bessere Angabe.** Sie ist am gesprochenen
Wort gelesen, von einem Lauf, der nichts anderes tut — das Datum am Fakt ist
ein Nebenprodukt der Extraktion, die vor allem Aussagen sammelt. Wo beide
etwas sagen und das Zitat passt, nimm die Zeitlinie.

**Und wo dir etwas verdächtig vorkommt, schau selbst nach.** Du hast den
Mitschnitt: `block(n)` zeigt dir die Stelle im Wortlaut, `bloecke(von, bis)`
ihre Umgebung, `suche_sitzung("…")` findet, wo ein Ausdruck sonst noch fällt,
und `fakt(id)` nennt die Blöcke, auf denen ein Fakt steht. Zwei Angaben
gegeneinander abzuwägen ist ein Münzwurf — im Mitschnitt nachlesen ist eine
Prüfung.

Verdächtig heißt zum Beispiel:

- Das Zitat der Zeitlinie stammt aus einer **anderen Szene** als die Aussage,
  die du einordnest.
- Zwei Fakten desselben Abschnitts tragen Zeiten, die **Jahre** auseinander
  liegen.
- Ein Datum widerspricht der Reihenfolge, die du beim Lesen der Fakten
  gesehen hast.
- Jemand spricht über Zeit, aber am **Tisch** („wir machen noch zehn Minuten")
  — das gehört in keine Chronik, und die Zeitlinie kann sich darin geirrt
  haben.

**Du darfst abweichen, und du sollst nicht ungeprüft übernehmen.** Beides
gehört zusammen:

- **Prüfen heißt: am Beleg.** Passt das Zitat zu der Aussage, die du
  einordnest? Steht die Zeit überhaupt in derselben Szene? Wenn ja, nimm sie
  als `{"art": "absolut", "zeit": "…"}` — schreib den Ausdruck ab, wie er
  dasteht.
- **Ein gerechneter Wert ist kein Beleg.** Er sagt „irgendwo dazwischen".
  Daraus ein absolutes Datum zu machen, wäre genau der Fehler, der diese
  Chronik einmal auf einen einzigen Tag gelegt hat. Nutze ihn für die
  **Reihenfolge**, nicht für ein Datum.
- **Widerspricht die Zeitlinie dem, was du in den Fakten liest, entscheide
  gegen sie** — und sag in der Begründung, warum. Der andere Lauf hat die
  Blöcke gelesen, nicht die Fakten; du hast beides.
- **Fehlt eine Zeitlinie, fehlt sie.** Sie ist nicht Pflicht, und ihr Ausbleiben
  ist kein Befund: Der Lauf darf scheitern, und viele Stellen tragen zu Recht
  keine Zeit.

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

**Einen einzelnen Fakt umhängen:** `fakt_umhaengen(fakt, von, nach)` — von
einem Eintrag in einen anderen, ohne die Texte anzufassen. Damit musst du
keinen Eintrag mit seiner ganzen Faktenliste neu schreiben.

**Zähl nichts selbst:** `zahlen()` nennt dir die Zähler dieses Laufs, auch
die, die `fertig()` als Quittung verlangt. Lies sie dort ab.

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
