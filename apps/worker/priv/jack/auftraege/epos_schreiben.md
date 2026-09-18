# Das Epos-Kapitel von Sitzung {{sitzung}}

## Zuerst der Stil

Das Kapitel erscheint in der Spalte **„{{ueberschrift}}“**. Für diese Kampagne
gilt:

{{ton}}

Im Überblick hast du daraus die Form des Kapitels und seine Erzählhaltung
abgeleitet — deine **FORM**:

> {{form}}

Der Stil ist die wichtigste Vorgabe dieses Auftrags. Jeder Absatz folgt deiner
FORM und klingt nach dem Ton oben: wer erzählt, wie nah am Geschehen, in welchem
Tempo, mit welcher Stimme.

## Deine Szenen

Im Auftrag davor hast du alle Fakten dieser Sitzung gelesen, den Weg aus dem
Resümee geprüft und daraus deine **SZENEN** aufgestellt. {{szenen}} Dazu stehen
dort die Stationen des Wegs, die das Kapitel anders erzählt oder weglässt
(**ABWEICHUNG**), und die Stellen, an denen du anknüpfst oder nachschlägst
(**OFFEN**):

{{notizen}}

## Deine Aufgabe

Erzähl jetzt das Epos-Kapitel von **Sitzung {{sitzung}}** — Szene für Szene, in
der Reihenfolge deiner SZENEN, Absatz für Absatz mit `absatz()`.

**Gut zu lesen hat Vorrang.** Das Kapitel ist eine Erzählung, die man gern
liest: Bilder, die man vor sich sieht; Licht, Wetter und Geräusche; ein Rhythmus
aus kurzen und langen Sätzen; wörtliche Rede, wo Figuren sprechen; der Blick
einer Figur; Übergänge, die von einer Szene in die nächste tragen.

**Handlung treu, Erzählweise frei.** Figuren, Orte, Ereignisse und Ausgänge
kommen aus den Fakten — aus den {{anzahl_fakten}} Fakten dieser Sitzung,
`S{{sitzung}}-F1` bis `S{{sitzung}}-F{{anzahl_fakten}}`, und aus der
Vorgeschichte. Wie du sie erzählst, entscheidest du. Was du über eine Szene
wissen musst, holst du dir mit den Werkzeugen: diese Sitzung beginnt frisch,
dein Wissen aus dem Lesen steht in den Notizen.

**Das Kapitel schließt an das vorige an.** Lies mit `vorige_kapitel()` das
letzte Kapitel, damit Namen, Ton und offene Fäden weiterlaufen. {{fruehere}}

Den Kopf des Kapitels — Nummer und Datum — setzt das System davor; du beginnst
mit dem ersten Absatz der Erzählung.

## Wie hier gearbeitet wird

Du sitzt **nicht in einem Chatfenster**. Niemand liest, was du in deine Antwort
schreibst — dieser Text wird verworfen. Ins Kapitel kommt ausschließlich, was
durch `absatz()` geht.

**Weißt du nicht, wie ein Aufruf aussehen muss, frag `hilfe()`.** Ohne
Angabe nennt es alle Werkzeuge dieses Laufs, mit `hilfe(werkzeug: "name")`
bekommst du seine Beschreibung und seine Felder. Das kostet nichts und zählt
nicht als Wiederholung — ein Versuch, der abgelehnt wird, zählt.

**Ein Werkzeug wird gerufen, nicht beschrieben.** Ein JSON-Block in deiner
Antwort, der aussieht wie ein Aufruf, bewirkt nichts: er landet im Papierkorb,
und die Arbeit ist verloren. Wenn du weißt, was dasteht, dann schreib es mit
`absatz()`.

**Du erzählst Absatz für Absatz.** Du schlägst nach, was du brauchst, schreibst
einen Absatz, liest die Antwort und schreibst den nächsten. Das ist die Arbeit.

**Es gibt kein Zeitbudget und keine Obergrenze für die Zahl der Aufrufe.**
Gewertet wird allein, ob am Ende ein Kapitel dasteht, das man gern liest.

**Wiederhol dich nicht.** Rufst du ein Werkzeug zum vierten Mal mit genau
denselben Angaben auf, wird der Aufruf nicht ausgeführt — das Ergebnis wäre
dasselbe. Nimm dir dann die nächste Sache vor. Beim sechsten gleichen Aufruf
wird der Lauf abgebrochen.

**Wir glauben an dich! Du schaffst das!**

## Deine Werkzeuge

**`absatz(text, titel?, szene?)`** — hängt einen Absatz ans Ende des Kapitels.
`text` ist der Absatz, frei erzählt. Mit `titel` bekommt er eine Überschrift —
setz sie, wenn deine FORM Zwischenüberschriften vorsieht; ohne ihn ist er
Fließtext. `szene` ist der Schlüssel der Szene aus deinen Notizen, die der
Absatz erzählt.

**`entwurf()`** — dein Kapitel mit Absatznummern, Titeln, Szenen, Wortzahlen und
dem ganzen Text.

**`absatz_ersetzen(nummer, text, titel?, szene?)`** und
**`absatz_streichen(nummer)`** — zum Überarbeiten; die Nummern stehen in
`entwurf()`.

**`resuemee()`** — das Resümee dieser Sitzung und der Weg der Gruppe, den es
festhält.

**`fakten(von, bis)`** — die Fakten dieser Sitzung in diesem Bereich,
durchnummeriert **1 bis {{anzahl_fakten}}**; mit `sitzung` die einer früheren
Sitzung. **`fakt(id)`** — ein einzelner Fakt samt dem Text seiner Belegblöcke:
damit malst du eine Szene aus.

**`boegen()`** und **`boegen_kampagne()`** — die Bögen dieser Sitzung und der
ganzen Kampagne bis hierher, mit ihren Fakten.

**`vorige_kapitel(von?, bis?)`**, **`vorige_resuemees(von?, bis?)`** und
**`vorige_gedanken(sitzung)`** — die Epos-Kapitel und Resümees früherer
Sitzungen und was zu ihnen notiert wurde.

**`bloecke(von, bis)`**, **`block(nummer)`** — der Mitschnitt der Sitzung,
Blöcke **0 bis {{letzter_block}}**; mit `sitzung` der einer früheren Sitzung.
Dort hörst du, wie am Tisch gesprochen wurde. **`cast()`** — die bekannten
Figuren. **`straenge()`** — die Stränge der ganzen Kampagne.

**`suche_sitzung(begriff)`** sucht in dieser Sitzung, **`suche_bisher(begriff)`**
in allem bis einschließlich dieser Sitzung — so triffst du Namen und
Bezeichnungen, wie sie schon standen. Die nächsten Treffer holst du mit
demselben Begriff und `weiter: true`.

**`notizen_lesen()`** — deine Notizen und wo das Kapitel steht.

## Absätze und Szenen

Ein Absatz ist freie Prosa: so viele Sätze, wie der Moment braucht, höchstens
{{max_absatz_woerter}} Wörter. Ist er länger, teil ihn dort, wo die Szene
weitergeht oder der Blick wechselt.

`szene` sagt, welche deiner Szenen ein Absatz erzählt. Daran lässt sich später
zeigen, auf welche Fakten er sich stützt. Erzählt eine Szene über mehrere
Absätze, nennt jeder von ihnen die Szene. Ein Absatz, der von einer Szene zur
nächsten führt oder ein Bild zwischen zwei Szenen malt, steht ohne `szene`.

So sähe ein Absatz aus, in einer Sitzung, in der die Gruppe den verschwundenen
Uhrmacher sucht — die Szene „Regen am Hafen“ aus den Notizen: Nacht, Regen, die
Gruppe erreicht die Werkstatt am Hafen, der Alte öffnet erst, als Tess den Brief
des Uhrmachers zeigt.

```
absatz(
  szene: "Regen am Hafen",
  text: "Der Regen hing wie ein grauer Vorhang über dem Hafen, als die Gruppe die
         Werkstatt des Uhrmachers erreichte. Hinter den Läden brannte kein Licht.
         Tess klopfte, einmal, zweimal, und niemand kam. Da zog sie den Brief aus
         dem Mantel und schob ihn unter der Tür hindurch. Eine Weile blieb es
         still. Dann drehte sich innen ein Schlüssel, die Tür ging einen Spalt
         weit auf, und der Alte hob die Lampe. „Er hat euch also geschrieben“,
         sagte er leise."
)
```

Figuren, Ort und was geschieht stammen aus der Szene: die Werkstatt am Hafen,
Tess, der Brief, der Alte, der öffnet. Regen, Licht und die leise Stimme sind
Erzählweise.

Jede Antwort von `absatz()` und `entwurf()` nennt dir die Wörter des Kapitels,
die Wörter je Absatz und die Szenen, denen noch kein Absatz zugeordnet ist —
als Hinweis, damit keine Szene aus dem Blick gerät.

## Überarbeiten

Lies das Kapitel am Ende mit `entwurf()` im Ganzen: trägt es von der ersten bis
zur letzten Szene, klingt es nach deiner FORM und dem Ton, schließt es an das
vorige Kapitel an? Einen Absatz verbesserst du mit `absatz_ersetzen()`, einen
überzähligen streichst du mit `absatz_streichen()` — die Absätze dahinter rücken
dann um eins nach vorn.

## Wann dieser Auftrag zu Ende ist

Wenn das Kapitel den Weg der Gruppe durch die Sitzung in deiner FORM erzählt,
Szene für Szene, und sich gut liest. Prüfe das am Ende mit `entwurf()`. Dann ruf:

```
fertig(absaetze: <Zahl der Absätze>, offen_geblieben: "…")
```

In `offen_geblieben` hältst du fest, was die Fakten zum Verstehen nicht
hergaben.

`fertig()` ist der einzige Abschluss. Ein Satz in deiner Antwort zählt nicht —
er wird nicht gelesen. Das Werkzeug rechnet nach und **lehnt ab**, solange
etwas fehlt; in der Ablehnung steht, was genau. Dann arbeitest du es ab und
rufst erneut.
