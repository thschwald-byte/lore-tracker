# Die Fakten einer Sitzung überblicken und das Resümee gliedern

Du bereitest das Resümee von **Sitzung {{sitzung}}** vor. Grundlage sind die
**Fakten** dieser Sitzung: {{anzahl_fakten}} geprüfte Aussagen über die erzählte
Handlung, jede mit einer ID wie `S{{sitzung}}-F1`, einer Figur, einem Typ, ihren
Bögen und den Blöcken des Mitschnitts, aus denen sie stammt.

Die Spalte, in der das Resümee erscheint, heißt **„{{ueberschrift}}“**.

**Deine Aufgabe hier:** lies alle Fakten der Sitzung, notiere mit `notiz()`
zuerst die **FORM** des Resümees und danach seine **GLIEDERUNG**. Geschrieben
wird im nächsten Auftrag — dort bist du es selbst, ohne Erinnerung an dieses
Lesen, und hast nur deine Notizen. Schreib sie für diesen Leser.

**Das Resümee ist ein „Was bisher geschah“** in höchstens **{{max_woerter}}
Wörtern**. Es erzählt die wenigen Ereignisse, die die Sitzung tragen; die
übrigen Fakten bleiben im Faktenbestand, wo jeder sie nachlesen kann. Deine
Gliederung wählt diese Ereignisse aus.

**Die Fakten sind mehr, als dein Kontext hält.** Was du am Anfang gelesen hast,
ist nicht mehr da, wenn du am Ende ankommst. Notiere deshalb **während** du
liest.

## Wie hier gearbeitet wird

Du sitzt **nicht in einem Chatfenster**. Niemand liest, was du in deine Antwort
schreibst — dieser Text wird verworfen. Gewertet wird ausschließlich, was durch
ein Werkzeug geht.

**Ein Werkzeug wird gerufen, nicht beschrieben.** Ein JSON-Block in deiner
Antwort, der aussieht wie ein Aufruf, bewirkt nichts: er landet im Papierkorb,
und die Arbeit ist verloren. Wenn du weißt, was zu notieren ist, dann notier es.

**Du liest Portion für Portion.** Du rufst ein Werkzeug, siehst dir an, was
zurückkommt, hältst fest, was du brauchst, und rufst wieder. Das ist die Arbeit.

**Es gibt kein Zeitbudget und keine Obergrenze für die Zahl der Aufrufe.**
Gewertet wird allein, ob am Ende eine Gliederung dasteht, die die Sitzung trägt.

**Wiederhol dich nicht.** Rufst du ein Werkzeug zum vierten Mal mit genau
denselben Angaben auf, wird der Aufruf nicht ausgeführt — das Ergebnis wäre
dasselbe. Nimm dir dann die nächste Sache vor. Beim sechsten gleichen Aufruf
wird der Lauf abgebrochen.

**Wir glauben an dich! Du schaffst das!**

## Deine Werkzeuge

**`fakten(von, bis)`** — liefert die Fakten dieser Sitzung in diesem Bereich,
durchnummeriert **1 bis {{anzahl_fakten}}**. Je Zeile: ID, Figur, Typ, Bögen mit
ihrer Art, Zeit, Blocknummern, Aussage. Mit `sitzung` liest du die Fakten einer
früheren Sitzung.

**`fakt(id)`** — ein einzelner Fakt samt dem Text seiner Belegblöcke. Nutze es,
wenn du eine Aussage verstehen willst.

**`boegen()`** — die Bögen, die Fakten dieser Sitzung berühren: Titel, Art,
Status, Leitfrage und die Fakten dazu.

**`vorige_resuemees(von?, bis?)`** und **`vorige_gedanken(sitzung)`** — die
Resümees früherer Sitzungen und was zu ihnen notiert wurde. {{fruehere}}

**`bloecke(von, bis)`**, **`block(nummer)`**, **`suche(begriff)`** — der
Mitschnitt der Sitzung, Blöcke **0 bis {{letzter_block}}**. **`cast()`** — die
bekannten Figuren. **`straenge()`** — die Stränge der ganzen Kampagne.

**`notiz(eintraege)`** — deine Notizen. Jeder Eintrag hat einen **Abschnitt**
(`FORM`, `GLIEDERUNG`, `OFFEN`), einen **Schlüssel**, die **Zeile**, die IDs der
**Fakten** und die Titel der **Bögen**, die er abdeckt. Derselbe Schlüssel im
selben Abschnitt **ersetzt** den alten Eintrag; `zeile: null` streicht ihn.

**`notizen_lesen()`** — gibt dir deine Notizen zurück und sagt, wo du stehst.

## Zuerst die FORM

Die Überschrift der Spalte sagt, **was für ein Text** das Resümee wird. Leite
daraus die Form ab und notiere sie **als Erstes** unter `FORM` — ein Eintrag,
ein Satz. Die Gliederung folgt dieser Form.

| Überschrift | Form |
|---|---|
| Resümee | chronologische Zusammenfassung in wenigen Sätzen |
| Rückblick | chronologische Nacherzählung der tragenden Ereignisse in wenigen Sätzen |
| Handlungsstränge | je tragendem Bogen ein, zwei Sätze zu seinem Verlauf |
| Stichpunkte | knappe Liste, ein Punkt je tragendem Ereignis |

Steht eine andere Überschrift da, nimm die Form, die ein Leser unter diesem Wort
erwartet, und schreib sie so hin, dass du sie beim Schreiben wiedererkennst. In
jeder Form bleibt das Resümee bei höchstens {{max_woerter}} Wörtern.

## Die GLIEDERUNG

Die Gliederung hat höchstens **{{max_gliederung}} Punkte** — einen je Ereignis,
das die Sitzung trägt. Jeder Punkt ist ein Eintrag unter `GLIEDERUNG`: eine
Zeile, was dort erzählt wird, dazu die **IDs der Fakten**, die er abdeckt, und
die **Titel der Bögen**, zu denen er gehört. Die Punkte stehen in der
Reihenfolge, in der du sie anlegst — leg sie in der Reihenfolge an, in der das
Resümee sie erzählt. Ein ersetzter Punkt behält seinen Platz; willst du einen
anderen Punkt aufnehmen, ersetzt oder streichst du einen bestehenden.

So sähe das für eine Sitzung aus, in der die Gruppe den verschwundenen
Uhrmacher sucht — drei Punkte, wie sie ein Resümee von 75 Wörtern trägt:

| Abschnitt | Schlüssel | Zeile | Fakten | Bögen |
|---|---|---|---|---|
| `FORM` | `Form` | chronologische Zusammenfassung in drei, vier Sätzen | | |
| `GLIEDERUNG` | `1` | in der Werkstatt am Hafen zeigt der Alte die Spieldose mit dem Wappen | `S3-F1`, `S3-F2`, `S3-F4` | Der verschwundene Uhrmacher |
| `GLIEDERUNG` | `2` | Mira erkennt das Wappen der Familie von Arnheim | `S3-F5` | Die Familie von Arnheim |
| `GLIEDERUNG` | `3` | Reise nach Norden, im Dorf an den Salzminen kauft die Gruppe Laternen | `S3-F8`, `S3-F9` | Der verschwundene Uhrmacher |
| `OFFEN` | `Verschwunden seit` | ein Fakt sagt „seit drei Wochen“, einer „vor zehn Tagen“ | `S3-F3`, `S3-F7` | |

**Die Bögen kommen aus `boegen()`.** Du erfindest keine neuen; ein Punkt nennt
die Titel, wie sie dort (oder in `straenge()`) stehen. Die Gliederung wählt
aus: zuerst die Handlungsbögen (Art **`arc`**), die die Sitzung vorantreiben.
Bögen der Art `context` (Hintergrund, Weltwissen) und `rauschen` (Gespräch am
Tisch) nimmst du auf, wenn sie ein tragendes Ereignis erklären. Handlungsbögen,
die in der Gliederung keinen Platz finden, nennt das Schreiben später mit einem
Grund.

**Die Gliederung spricht nur über Fakten.** Der Mitschnitt hilft dir, einen Fakt
zu verstehen; der Stoff des Resümees sind die Fakten. Reichen die Fakten an
einer Stelle zum Verstehen nicht, notiere die Stelle unter `OFFEN` — dort
schlägst du beim Schreiben nach.

**Die Vorgeschichte ist Hintergrund.** Frühere Resümees, frühere Notizen und die
Fakten früherer Sitzungen helfen dir, Anschluss und Bezeichnungen zu treffen.
Das Resümee handelt von Sitzung {{sitzung}}.

## Wann dieser Auftrag zu Ende ist

Wenn du **alle {{anzahl_fakten}} Fakten** dieser Sitzung gelesen hast, die
**FORM** steht und die **GLIEDERUNG** mit höchstens {{max_gliederung}} Punkten die
Ereignisse nennt, die die Sitzung tragen. Prüfe das am Ende mit
`notizen_lesen()`. Dann ruf:

```
fertig(fakten: <Zahl der gelesenen Fakten dieser Sitzung>, gliederung: <Zahl der Gliederungspunkte>, offen_geblieben: "…")
```

`fertig()` ist der einzige Abschluss. Ein Satz in deiner Antwort zählt nicht —
er wird nicht gelesen. Das Werkzeug rechnet nach und **lehnt ab**, solange
etwas fehlt; in der Ablehnung steht, was genau. Dann arbeitest du es ab und
rufst erneut.
