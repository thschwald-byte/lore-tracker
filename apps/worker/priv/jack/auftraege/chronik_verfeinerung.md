# Die Chronik von {{kampagne}} — verfeinern

Die Chronik dieser Kampagne steht bereits. Du baust sie **nicht neu**. Du
liest, was da ist, und arbeitest ein, was seit dem letzten Mal dazugekommen
ist.

Das ist der Normalfall: Der volle Aufbau mit Überblick passiert genau einmal,
solange die Chronik leer ist. Danach wird sie verfeinert — auch nach einer
neuen Sitzung, auch beim erneuten Erzeugen einer alten.

## Was dasteht

{{chronik}}

## Was dazugekommen ist

Die Fakten der Sitzung **{{sitzung}}** — es sind {{anzahl_fakten}}. Sie sind
der Anlass dieses Laufs, aber nicht deine Grenze: Du siehst die ganze
Kampagne, und du darfst dich auf alles beziehen.

## Deine Aufgabe

Geh die neuen Fakten durch und entscheide für jeden, wohin er gehört:

**In eine bestehende Phase** — das ist der häufigste Fall. Der Auftrag, der in
der letzten Sitzung erteilt wurde, wird jetzt ausgeführt: Das ist dieselbe
Phase. Nimm sie mit `eintrag_ergaenzen()` fort — dein Text kommt an den
vorhandenen, die Fakten kommen dazu.

**In eine neue Phase** — ein neuer Abschnitt der Handlung hat begonnen. Leg ihn
mit `chronik_eintrag()` an und ordne ihn ein.

**In einen eigenen Eintrag** — wenn etwas geschehen ist, das die Kampagne oder
die Welt verändert: der Tod einer Spielerfigur, ein Krieg, eine Seuche, ein
Epochenereignis. `wichtigkeit: "schluesselszene"`.

**Nirgendwohin** — wenn der Fakt ein dauerhafter Zustand ist („X ist
Steuerberater“). Solche Fakten gehören nicht in die Zeitleiste; `fertig()`
verlangt sie auch nicht.

Dazu: Wenn du beim Lesen merkst, dass ein Bezug nicht stimmt, korrigiere ihn
mit `eintrag_einordnen()`. Das darfst du auch bei Einträgen, die aus früheren
Läufen stammen.

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

## Was du nicht tust

**Du baust die Chronik nicht um.** Was dasteht, steht — es sei denn, du findest
einen echten Fehler. Die Einträge früherer Sitzungen bleiben.

**Du streichst nichts, was der Spielleiter kuratiert hat.** Solche Einträge
sind in `chronik()` markiert. Fortschreiben und einordnen ja, streichen nein —
und sein Text bleibt vollständig stehen, auch wenn du ergänzt.

**Du rechnest keine Tage.** Sag die Reihenfolge (`nach`, `vor`,
`gleichzeitig_mit`), oder schreib einen im Spiel genannten Zeitpunkt ab
(`absolut`). Den Rest rechnen wir.

## Wie hier gearbeitet wird

Du sitzt **nicht in einem Chatfenster**. In die Chronik kommt ausschließlich,
was durch die Werkzeuge geht.

**Es gibt kein Zeitbudget und keine Obergrenze für die Zahl der Aufrufe.**

**Einen einzelnen Fakt umhängen:** `fakt_umhaengen(fakt, von, nach)` — von
einem Eintrag in einen anderen, ohne die Texte anzufassen. Damit musst du
keinen Eintrag mit seiner ganzen Faktenliste neu schreiben.

**Zähl nichts selbst:** `zahlen()` nennt dir die Zähler dieses Laufs, auch
die, die `fertig()` als Quittung verlangt. Lies sie dort ab.

**Weißt du nicht, wie ein Aufruf aussehen muss, frag `hilfe()`.** Ohne
Angabe nennt es alle Werkzeuge dieses Laufs, mit `hilfe(werkzeug: "name")`
bekommst du seine Beschreibung und seine Felder. Das kostet nichts und zählt
nicht als Wiederholung — ein Versuch, der abgelehnt wird, zählt.

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
