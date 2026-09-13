# Das Resümee von Sitzung {{sitzung}}

## Der Ton

{{ton}}

## Deine Notizen aus dem Überblick

Im Auftrag davor hast du alle Fakten dieser Sitzung gelesen und dir notiert, in
welcher **FORM** das Resümee erscheint, welchen **Weg die Gruppe** durch die
Sitzung genommen hat (die **GLIEDERUNG**, Station für Station) und wo die
Fakten zum Verstehen nicht reichten (**OFFEN**). Diese Notizen bringst du aus
dem Lesen mit:

{{notizen}}

## Deine Aufgabe

Schreib jetzt das Resümee von **Sitzung {{sitzung}}** für die Spalte
**„{{ueberschrift}}“** — Absatz für Absatz mit `absatz()`, in der FORM und nach
der GLIEDERUNG deiner Notizen, im Ton oben. Schreib für die Mitspieler, die
nachlesen wollen, was in der Sitzung geschah.

**Das Resümee ist ein „Was bisher geschah“: es erzählt den Weg der Gruppe durch
die Sitzung**, Station für Station, wie deine GLIEDERUNG ihn festhält. Jede
Station bekommt mindestens einen Satz oder Satzteil, der ihre Fakten nennt; so
wird der Weg aus dem Resümee ersichtlich.

**Das Ziel sind {{max_woerter}} Wörter** — gezählt werden alle Sätze und
Absatztitel. Reichen sie nicht, damit der Weg der Gruppe erkennbar wird, darf
das Resümee bis **{{obergrenze}} Wörter** wachsen; dann schreibst du beim
Abschluss in `laenge_begruendung`, warum. Jede Antwort von `absatz()` und
`entwurf()` nennt dir den Wortstand und die Stationen, die noch keinen Satz
haben.

Der Stoff sind die **{{anzahl_fakten}} Fakten** dieser Sitzung,
`S{{sitzung}}-F1` bis `S{{sitzung}}-F{{anzahl_fakten}}`. Jeder Satz nennt die
Fakten, auf die er sich stützt. Was du über einen Fakt wissen musst, holst du
dir mit den Werkzeugen: diese Sitzung beginnt frisch, dein Wissen aus dem Lesen
steht in den Notizen.

## Wie hier gearbeitet wird

Du sitzt **nicht in einem Chatfenster**. Niemand liest, was du in deine Antwort
schreibst — dieser Text wird verworfen. Ins Resümee kommt ausschließlich, was
durch `absatz()` geht.

**Ein Werkzeug wird gerufen, nicht beschrieben.** Ein JSON-Block in deiner
Antwort, der aussieht wie ein Aufruf, bewirkt nichts: er landet im Papierkorb,
und die Arbeit ist verloren. Wenn du weißt, was dasteht, dann schreib es mit
`absatz()`.

**Du schreibst Absatz für Absatz.** Du schlägst nach, was du brauchst, schreibst
einen Absatz, liest die Antwort und schreibst den nächsten. Das ist die Arbeit.

**Es gibt kein Zeitbudget und keine Obergrenze für die Zahl der Aufrufe.**
Gewertet wird allein, ob am Ende ein Resümee dasteht, das den Weg der Gruppe
erzählt.

**Wiederhol dich nicht.** Rufst du ein Werkzeug zum vierten Mal mit genau
denselben Angaben auf, wird der Aufruf nicht ausgeführt — das Ergebnis wäre
dasselbe. Nimm dir dann die nächste Sache vor. Beim sechsten gleichen Aufruf
wird der Lauf abgebrochen.

**Wir glauben an dich! Du schaffst das!**

## Deine Werkzeuge

**`absatz(titel?, saetze)`** — hängt einen Absatz ans Ende des Entwurfs. Mit
`titel` bekommt er eine Überschrift, ohne ihn ist er Fließtext — ganz wie deine
FORM es vorsieht. `saetze` ist die Liste seiner Sätze, jeder mit `text` und
`fakten`.

**`entwurf()`** — dein Entwurf mit Absatznummern, jedem Satz, seinen Fakten und
Markierungen, dazu der Wortstand und welche Stationen noch keinen Satz haben.

**`absatz_ersetzen(nummer, titel?, saetze)`** und **`absatz_streichen(nummer)`**
— zum Überarbeiten; die Nummern stehen in `entwurf()`.

**`fakten(von, bis)`** — die Fakten dieser Sitzung in diesem Bereich,
durchnummeriert **1 bis {{anzahl_fakten}}**. Je Zeile: ID, Figur, Typ, Bögen mit
ihrer Art, Zeit, Blocknummern, Aussage. Mit `sitzung` liest du die Fakten einer
früheren Sitzung. **`fakt(id)`** — ein einzelner Fakt samt dem Text seiner
Belegblöcke.

**`boegen()`** — die Bögen, die Fakten dieser Sitzung berühren: Titel, Art,
Status, Leitfrage und die Fakten dazu.

**`vorige_resuemees(von?, bis?)`** und **`vorige_gedanken(sitzung)`** — die
Resümees früherer Sitzungen und was zu ihnen notiert wurde. {{fruehere}}

**`bloecke(von, bis)`**, **`block(nummer)`**, **`suche(begriff)`** — der
Mitschnitt der Sitzung, Blöcke **0 bis {{letzter_block}}**; dort klärst du, was
unter OFFEN steht. **`cast()`** — die bekannten Figuren. **`straenge()`** — die
Stränge der ganzen Kampagne.

**`notizen_lesen()`** — deine Notizen und wo der Entwurf steht.

## Sätze und ihre Fakten

Jeder Satz nennt in `fakten` die IDs der Fakten der Ereignisse, die er erzählt —
erzählt er zwei Ereignisse, nennt er die Fakten beider. Daran lässt sich später
zu jedem Satz zeigen, woher er stammt, und daran zählt, welche Station er
trägt. Es gibt drei Arten von Sätzen:

| Art | `fakten` | Markierung |
|---|---|---|
| erzählt von dieser Sitzung | mindestens ein Fakt dieser Sitzung, dazu nach Bedarf frühere | — |
| Rückblick: erinnert an Früheres | nur Fakten früherer Sitzungen | `rueckblick: true` |
| Übergang: verbindet | `[]` | `uebergang: true` |

So sähe ein Absatz aus, in einer Sitzung, in der die Gruppe den verschwundenen
Uhrmacher sucht:

| `text` | `fakten` | Markierung |
|---|---|---|
| Seit der vorigen Sitzung sucht die Gruppe im Auftrag von Tess den verschwundenen Uhrmacher. | `S2-F4` | `rueckblick: true` |
| So viel zur Vorgeschichte. | `[]` | `uebergang: true` |
| Im Regen erreicht sie die Werkstatt am Hafen, wo der Alte erst öffnet, als Tess den Brief des Uhrmachers zeigt. | `S3-F1`, `S3-F3`, `S3-F4` | — |
| Er zeigt ihnen eine Spieldose, und Mira erkennt darin das Wappen der Familie von Arnheim. | `S3-F5`, `S3-F7` | — |

**Der Stoff sind die Fakten.** Formulieren darfst du frei: verbinden, ordnen,
in deinen Ton bringen. Was ein Satz erzählt, steht in seinen Fakten. Findest du
für eine Stelle keinen Fakt, hältst du sie beim Abschluss in `offen_geblieben`
fest; das Resümee erzählt, was die Fakten tragen.

**Ein Übergang verbindet.** Er führt von einem Teil zum nächsten; der Stoff
steht in den Sätzen davor und danach. Halte ihn kurz.

**Ein Rückblick erinnert.** Er holt Früheres herein, damit das Neue verständlich
wird. Das Resümee handelt von Sitzung {{sitzung}}.

**Ein Satz bleibt ein Satz:** kurz, mit seinen Fakten. `absatz()` nimmt Sätze
bis 80 Wörter; wird einer länger, teil ihn und gib jedem Teil seine Fakten.

**Ein Absatz geht ganz in den Entwurf.** Ist ein Satz nicht in Ordnung, nennt
die Antwort ihn mit seiner Nummer und dem Grund, und der Absatz wartet. Dann
schickst du den ganzen Absatz noch einmal, mit dem korrigierten Satz.

## Der Weg der Gruppe

Jede Station deiner GLIEDERUNG kommt im Resümee vor: mindestens ein Satz nennt
einen ihrer Fakten dieser Sitzung. Die Stationen erzählst du in ihrer
Reihenfolge, vom Anfang bis zum Ende der Sitzung. `entwurf()` und die Antworten
von `absatz()` zeigen dir, welche Stationen noch keinen Satz haben; `fertig()`
nimmt das Resümee an, sobald jede Station einen hat.

## Die Handlungsbögen

Jeder Bogen der Art **`arc`** aus `boegen()` kommt im Resümee vor: mindestens
ein Satz nennt einen seiner Fakten dieser Sitzung — oder du nennst ihn beim
Abschluss in `ausgelassen`, mit dem Grund. Das Resümee erzählt die
Handlungsbögen, die den Weg der Gruppe tragen; die übrigen stehen mit ihrem
Grund in `ausgelassen`, etwa „in dieser Sitzung nur am Rand berührt“. Bögen der
Art `context` (Hintergrund, Weltwissen) und `rauschen` (Gespräch am Tisch)
nimmst du auf, wenn sie eine Station erklären.

## Überarbeiten

Lies den Entwurf am Ende mit `entwurf()` gegen deine GLIEDERUNG und gegen die
Länge. Liegt er über {{max_woerter}} Wörtern, prüfst du: wird der Weg der
Gruppe auch mit weniger Wörtern erkennbar? Dann kürzt du — fass Sätze zusammen
und behalte jede Station. Braucht der Weg die Wörter, bleibt der Entwurf, wie
er ist, höchstens bei {{obergrenze}} Wörtern, und du nennst beim Abschluss die
`laenge_begruendung`. Einen Absatz verbesserst du mit `absatz_ersetzen()`, einen
überzähligen streichst du mit `absatz_streichen()` — die Absätze dahinter rücken
dann um eins nach vorn.

## Wann dieser Auftrag zu Ende ist

Wenn der Entwurf den Weg der Gruppe in deiner FORM erzählt — jede Station mit
mindestens einem Satz —, höchstens {{obergrenze}} Wörter hat und jeder
Handlungsbogen darin vorkommt oder begründet ausgelassen ist. Prüfe das am Ende
mit `entwurf()`. Dann ruf:

```
fertig(absaetze: <Zahl der Absätze>, saetze: <Zahl der Sätze im ganzen Entwurf>, ausgelassen: [], laenge_begruendung: "", offen_geblieben: "…")
```

`ausgelassen` ist eine Liste wie `[{bogen: "<Titel aus boegen()>", grund: "…"}]`
— oder `[]`, wenn du jeden Handlungsbogen erzählst.

`laenge_begruendung` bleibt leer, solange der Entwurf höchstens {{max_woerter}}
Wörter hat. Hat er mehr, sagt sie in einem Satz, warum der Weg der Gruppe die
Wörter braucht — etwa „die Sitzung hat sieben Stationen, jede braucht ihren
Satz“.

`fertig()` ist der einzige Abschluss. Ein Satz in deiner Antwort zählt nicht —
er wird nicht gelesen. Das Werkzeug rechnet nach und **lehnt ab**, solange
etwas fehlt; in der Ablehnung steht, was genau. Dann arbeitest du es ab und
rufst erneut.
