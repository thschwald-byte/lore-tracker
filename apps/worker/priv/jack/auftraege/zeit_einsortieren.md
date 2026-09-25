# Die Zeitlinie von {{kampagne}} — die Äußerungen einordnen

Du hast im vorigen Lauf gelesen, was in dieser Kampagne geschieht. Jetzt gehst
du durch den **Mitschnitt** und bringst die Äußerungen in eine zeitliche Reihe.

## Zwei Achsen — und du baust die zweite

**Die Sprechlinie** ist, was wann gesagt wurde. Sie steht fest, niemand fasst
sie an; `lies_sprechlinie(ab: n)` zeigt sie dir.

**Die Kette** ist, was wann *geschah*. Sie gehört der **Kampagne** und ist
älter als dein Lauf: `lies_kette()` zeigt dir, was schon darin steht — aus
früheren Sitzungen oder aus einem früheren Lauf über diese. Deine Arbeit ist,
sie zu **ergänzen**; nur bei einer ganz neuen Kampagne ist sie leer.

Für die meisten Äußerungen fällt beides zusammen: Es geschieht in der
Reihenfolge, in der gesprochen wird. Für einen Rückblick nicht — er wird
jetzt erzählt und geschah früher.

## Die Reihenfolge, in der es zählt

Wenn zwei Regeln sich zu widersprechen scheinen, gilt die weiter oben.

1. **Nichts erfinden.** Kein Anker ohne Beleg im Text.
2. **Was ein Mensch festgelegt hat, bleibt.** Dagegen hilft nur `melde_konflikt`.
3. **Jede Zeile lesen.**
4. **Jede Zeile entscheiden**: in ein Kettenglied (`haenge_an_kette`) oder
   ausdrücklich heraus (`nicht_in_die_kette`).
5. **Erst einreihen, dann datieren.** Ein Anker an einer Zeile, die in keinem
   Glied liegt, wird abgelehnt — er wäre gesetzt und unsichtbar.
6. **Rückblicke an ihren Platz** (`versetze_kettenglied`) — aber nur, wenn der
   Text es belegt.
7. **Im Zweifel `kettenplatz_unklar`**, nie raten.
7b. **Eintragen schlägt planen** — alles ist später änderbar (s.u.).
8. **`lies_kette()` prüfen**, bevor du weitergehst; `fertig()` erst, wenn
   `offen()` nichts mehr nennt.

## Ein Glied ist eine Zeiteinheit, keine Zeile

Eine Szene — Ankunft, Verhandlung, Rückzug — ist **ein** Glied, auch wenn
vierzig Zeilen dazugehören. Alle Zeilen eines Gliedes teilen sich seine Zeit;
gerechnet wird zwischen Gliedern.

Das ist kein Detail, sondern der Grund, warum die Kette überhaupt lesbar ist:
Eine Sitzung mit zweitausend Äußerungen hat vielleicht achtzig Glieder. Die
kannst du überblicken, die Äußerungen nicht.

**Nimm also grosse Abschnitte** — aber nur so gross, wie **eine** Zeit reicht.
`haenge_an_kette(von: 200, bis: 640)` ist ein Aufruf für 441 Zeilen.

### Zwei Zeiten sind zwei Glieder

Hier hört „gross" auf: Sobald in einem Abschnitt **zwei verschiedene
Zeitpunkte der Spielwelt** vorkommen, sind es zwei Glieder — auch wenn
derselbe Sprecher ohne Pause durchredet und das Thema dasselbe ist.

Der echte Fall (20.09.2026): Ein Glied „Welteinleitung“ über 127 Zeilen trug
die Vitas-Plage (frühe 2000er), die ersten Metamenschen (2010) **und** Ryumyo
am Mount Fuji (24.12.2011). Das sind elf Jahre in einem Glied, das genau eine
Zeit tragen kann — zwei der drei Zeitpunkte sind damit unsichtbar, obwohl sie
im Text stehen.

Richtig sind drei Glieder, jedes mit seinem Anker, jedes an seinem Platz auf
dem Zeitstrahl. Der Sprechabschnitt bleibt einer; die **Kette** ist nicht die
Sprechlinie.

## Ein Glied kann Glieder tragen

Die Kette ist ein Zeitstrahl, auf dem Glieder stehen — und an jedem Glied
können wieder Glieder hängen, wie Bäume auf dem Strahl. Ein Glied ist ein
**zusammenhängender Kontext**; ein grosser besteht oft aus kleineren. „Der
Überfall“ steht auf dem Zeitstrahl, „der Hinterhalt“ und „die Flucht“ hängen
daran (`unterhaenge_kettenglied`).

**Die Glieder an einem Glied sind wieder eine Kette**: dieselbe Reihenfolge,
dieselben Wörter — `vor`, `nach`, `anfang` meinen dort seine Geschwister.
Versetzen und Löschen gelten auf jeder Ebene.

Ein Glied hängt **entweder am Zeitstrahl oder an einem Glied**, nie an
beidem. Deshalb bewegt `versetze_kettenglied` ein Glied nur unter seinen
Geschwistern: Wer eine Szene aus ihrem Zusammenhang lösen will, nimmt sie
heraus (`loesche_kettenglied`) und hängt sie neu ein.

**Staffle nur, wo der Zusammenhang wirklich verschachtelt ist.** Eine Szene
nach der anderen gehört nebeneinander auf den Zeitstrahl, nicht ineinander.

## Nichts davon ist endgültig

**Du kannst alles ändern, was du eingetragen hast.** Das ist der wichtigste
Satz dieses Auftrags, weil er dir die Planung erspart:

- Ein Glied falsch geschnitten? `loesche_kettenglied`, dann neu bilden.
- An der falschen Stelle? `versetze_kettenglied`.
- Zu klein? `erweitere_kettenglied`. Eine Zeile gehört woanders hin? Reih sie
  einfach neu ein — sie verlässt ihr altes Glied von selbst.
- Für Tisch gehalten, war doch Welt? `haenge_an_kette` holt sie aus dem
  Draussen zurück. Umgekehrt genauso.

**Also fang an, statt zu planen.** Trag ein, was du vor dir hast, und
korrigier es, wenn du später mehr weisst — ein Glied ist ein Zwischenstand,
keine Festlegung. Wer erst die perfekte Gliederung sucht, hat am Ende eine
Gliederung und keine Kette.

Der einzige Weg, echt etwas zu verlieren, ist **gar nichts einzutragen**: Was
du nur denkst, ist nach der nächsten Zusammenfassung deines Gedächtnisses
weg. Was du eingetragen hast, bleibt — und lässt sich ändern.

## So arbeitest du — abschnittsweise

**Lies ein Stück, entscheide dieses Stück, setz die Zeiten, die dir darin
begegnet sind. Dann das nächste.**

Nicht: erst zweitausend Zeilen lesen und dann entscheiden. Dein Gedächtnis
wird zwischendurch zusammengefasst, und was du nur gedacht und nicht
aufgerufen hast, ist dann weg.

Ein Durchgang sieht so aus:

    lies_sprechlinie(ab: 1, anzahl: 80)
    nicht_in_die_kette(von: 1, bis: 41, grund: "Technik-Geplänkel vor dem Spiel")
    haenge_an_kette(von: 42, bis: 80, grund: "Ankunft im Hafen")
    setz_zeitpunkt(zeilen: [61], wert: "kurz vor sieben", welt: "spielwelt", beleg: "…")
    lies_sprechlinie(ab: 81, anzahl: 80)
    …

Achtzig Zeilen sind der Richtwert, keine Vorschrift: Nimm weniger, wenn ein
Szenenwechsel eine feinere Grenze nahelegt.

## Die sechs Werkzeuge der Kette

- **`haenge_an_kette`** — bildet ein Glied und stellt es auf den Zeitstrahl.
  Ohne Angabe ans Ende; mit `vor`/`nach` an eine bestimmte Stelle, mit
  `anfang: true` vor alles.
- **`unterhaenge_kettenglied`** — bildet ein Glied und hängt es **an ein
  bestehendes**, als Teil davon. `glied` ist eine Zeile aus dem Glied, in das
  es hineingehört.
- **`erweitere_kettenglied`** — ein bestehendes Glied wächst und **bleibt, wo
  es ist**. Für den Fall „ach, die Szene fing schon bei 98 an". Die Zeilen
  eines Gliedes sind selbst eine Kette: `vor`/`nach` nennen dort eine Zeile
  im Glied.
- **`versetze_kettenglied`** — ein Glied wandert. Vor ein anderes, hinter ein
  anderes, oder an den Anfang.
- **`loesche_kettenglied`** — nimmt ein Glied heraus; seine Zeilen sind danach
  wieder **offen**, nicht draussen. Für ein Glied, das du neu schneiden willst.
- **`nicht_in_die_kette`** — Tischgespräch. Kommt nie hinein, wird nie datiert.

## Dann die Zeiten

- **`setz_zeitpunkt`** — hier wurde eine Zeit *gesagt*. „Drei viertel elf“,
  „am fünfzehnten“, „kurz vor sieben“.
- **`setz_spanne`** — hier ist Zeit *vergangen*. „Wir sind zwei Stunden
  marschiert“. Ohne Spannen steht die Kette still: Zwischen zwei genannten
  Uhrzeiten liegen oft Stunden, die niemand ausspricht.
- **`nimm_anker_zurueck`** — ein Anker von dir, der nicht trägt. Eine Dauer
  ohne Bezugspunkt, eine Angabe, die du beim zweiten Lesen anders verstehst,
  ein Zeitpunkt, der die Reihe verbiegt: nimm ihn weg, mit Grund. **Das ist
  kein Eingeständnis, sondern die billigste Korrektur, die es gibt** — ein
  falscher Anker zieht die ganze Linie schief, und ich rechne ihn mit.
  Für „der alte ist falsch, hier ist der richtige" nimm `anker_ersetzen`;
  hier geht es um „weg damit, ohne Ersatz".
- **`setz_frist`** — hier ist Zeit *angekündigt*. **Eine Frist bewegt die
  Kette nie** — die Zeit steht noch bevor. Festgehalten wird sie trotzdem.

**Verlass dich nicht darauf, dass ich die Lücken richtig fülle.** Zwischen
zwei weit entfernten Ankern verteile ich gleichmäßig, und das ist meistens
falsch. Je mehr Spannen du einträgst, desto weniger muss ich raten.

Es gibt Sitzungen, in denen über anderthalbtausend Äußerungen lang keine
einzige Uhrzeit fällt — und in denen trotzdem geschlafen, gereist,
eingebrochen und gekämpft wird. Was dort steht, sind Spannen.

## Die Welt-Frage kommt bei JEDEM Anker zuerst

Gilt die Zeit **in der erzählten Welt** oder **am Tisch**?

- *Spielwelt:* „Ihr kommt kurz vor sieben an.“ „Es ist drei viertel elf.“
- *Tisch:* „Wir machen noch zehn Minuten.“ „Ich muss morgen um sechs raus.“
  „Wann treffen wir uns nächste Woche?“

Das ist **fast ein Münzwurf**, keine Ausnahmebehandlung: In vier von Hand
durchgesehenen Sitzungen stehen 121 Angaben der Spielwelt gegen 90 des
Tisches, und in zweien ist der Tisch in der Mehrheit. Wer Tischzeit für den
Randfall hält, trägt die halbe Sitzung falsch ein.

Steht es nicht da, **nimm `zweifel` statt zu raten**. Zweifeln soll so billig
sein wie Setzen.

## Drei Sorten Rauschen, die wie Zeit aussehen

**Eine Zahl ist keine Zeit.** Geldbeträge, Seitenzahlen, Modifikatoren,
Entfernungen, Schadenswerte, Würfelergebnisse. Die gehören mit `loesen`
heraus.

**Unsere Welt ist nicht die Spielwelt.** Smalltalk über Sport, Filme,
Politik ist voller echter Zeitangaben mit echten Jahreszahlen — „die sind vor
vier Jahren hingegangen“, „das läuft seit 2014“. Für die Linie ist das genauso
falsch wie eine Küchenuhr, und es sieht viel überzeugender aus. Es steht
meistens in den ersten Blöcken, bevor das Spiel anfängt.

**Eine Wirkdauer ist keine Spanne.** „Eine Stunde hat man Zeit, das zu
benutzen“ sagt, wie lange etwas *dauert*, nicht, wann es *geschieht*. Die
Restzeit einer bestimmten Figur an einer bestimmten Stelle dagegen schon
(„mir bleiben noch fünf Minuten“).

## Vergangenheit gehört auf die Linie

Alles, was in der Spielwelt **früher** geschah und wovon jetzt erzählt wird,
bekommt einen Anker und seinen Platz. Es ist gleich, wie weit zurück und wie
groß:

- „Im Jahr 2011 erwachten die Drachen“ — Weltgeschichte.
- „Wir waren doch vor zwei Jahren in Namibia“ — die Gruppe selbst.
- „Damals beim Überfall“, „letzten Winter“ — irgendwo dazwischen.

Das ist alles dasselbe: **Vergangenheit.** Kein Tischgespräch, sondern
erzählte Welt — nur eben nicht jetzt.

**Die Kette ist die Zeitleiste der SPIELWELT**, nicht die des Abends. Was in
der Spielwelt verortet ist, gehört hinein und an seinen zeitlichen Platz —
auch Weltgeschichte, die nie jemand gespielt hat, und auch dann, wenn die
Spielleitung sie in einem Zug am Sitzungsanfang erzählt. Was am **Tisch**
gesagt wird, gehört nie hinein, auch wenn eine Uhrzeit darin vorkommt („es
ist schon zehn, ich muss um vier aufstehen“ ist Tisch).

**Und weil sie lange davor liegen, gehört die Zeile auch dorthin.** Drei
Schritte, und alle drei gehören zusammen:

1. **`ingame`** — es ist die erzählte Welt, kein Tischgespräch.
2. **`zeitpunkt`** — mit dem Jahr, das genannt wurde.
3. **`verschieben`** — an ihren Platz in der Vergangenheit, genauso wie einen
   Rückblick der Gruppe.

Ohne den dritten Schritt behauptet die Linie, das Jahr 2011 sei mitten in der
Sitzung gewesen — und alles, was danach kommt, hängt daran.

Die Grenze zum Rauschen ist die **Welt**, nicht das Alter: „Die Rams sind vor
vier Jahren hingegangen“ ist **unsere** Welt und fliegt raus; „die
Konzernkriege 2070“ und „vor zwei Jahren in Namibia“ sind die Spielwelt und
bleiben.

**Was du dabei NICHT tun musst:** dir Sorgen machen, dass eine grobe
Jahreszahl die Uhrzeiten der Sitzung kaputtmacht. Ein Anker, der nur ein
Jahr nennt, nennt keinen Tag — ich vererbe von ihm auch keinen. „Es ist kurz
nach acht“ bleibt dann eine Uhrzeit an einem unbekannten Tag, und das ist
richtig so.

Ein reiner Zeitraum ohne Ereignis („zwischen 2055 und 2065 haben wir die
Charaktere gespielt“) ist dagegen keiner: Er nennt keinen Punkt, an dem etwas
geschieht.

## Die Antwort steht selten neben der Frage

Eine Zeitangabe ist oft die Antwort auf eine Frage, und die Frage steht
mehrere Äußerungen früher — **mit fremdem Gerede dazwischen**: ein anderer
Sprecher, ein anderes Thema, ein Einwurf. In zwei durchgesehenen Sitzungen
kam dieses Muster dreimal vor, jedes Mal mit zwei Blöcken Abstand.

Die Regel ist deshalb nicht „lies den Block davor“, sondern: **lies zurück,
bis du die Frage gefunden hast.**

Und hör nicht bei der ersten plausiblen Antwort auf. Der bösartige Fall
sieht so aus:

```
[1104]  „Wie spät ist es denn jetzt?“
[1105]  „Noch fünfeinhalb Stunden.“        ← klingt wie eine Antwort, ist aber
                                             die Restwirkdauer eines Mittels
[1106]  „… dann wird es jetzt so kurz nach zwölf sein.“   ← DAS ist die Antwort
```

## Jede Zeile braucht eine Entscheidung — das ist die Hauptarbeit

Zu **jeder** Zeile musst du sagen, ob hier gespielt oder am Tisch geredet
wird:

- **`haenge_an_kette`** — gehört zur erzählten Welt, kommt in ein Glied.
- **`nicht_in_die_kette`** — Tischgespräch, Regelfrage, Würfelwurf, Smalltalk.
- **`kettenplatz_unklar`** — du kannst es nicht entscheiden. Die Zeile kommt
  in die Kette und ist vermerkt; ich leite keine Zeit aus ihr ab.

**Warum das nicht optional ist:** Deine Zeilen beginnen ohne Einordnung. Was
niemand entschieden hat, ist offen — nicht „steht schon richtig". `fertig()`
zählt genau diese Zeilen, und `offen()` sagt dir vorher, wo sie liegen.

## Die Kette ist älter als dieser Lauf

`lies_kette()` zeigt dir vielleicht schon **Glieder, die du nicht angelegt
hast** — aus früheren Sitzungen derselben Kampagne oder aus einem früheren
Lauf über diese. Die Kette ist persistent; sie gehört der Kampagne, nicht
deinem Lauf.

Das heißt für dich:

- **Du ergänzt, du baust nicht neu.** Fremde Glieder bleiben, wo sie sind.
  Deine neuen Zeilen hängen sich zwischen sie oder dahinter — `vor`, `nach`
  und `anfang` beziehen sich auf die ganze Kette, nicht nur auf deinen Teil.
- **Du kannst fremde Glieder anfassen**, wenn es nötig ist: erweitern, wenn
  eine Szene früher anfing als bisher gedacht, versetzen, wenn sie zeitlich
  falsch liegt. Tu es mit Grund; ein Glied aus einer anderen Sitzung hat
  jemand bewusst dort eingehängt.
- **Löschen ist die Ausnahme.** Ein Glied zu entfernen, das nicht aus deiner
  Sitzung stammt, heißt, die Arbeit eines anderen Laufs wegzuwerfen. Wenn es
  falsch liegt, versetze es.
- **Wo deine Sitzung liegt, entscheidest du.** Meistens hinten — sie ist die
  neueste. Aber alles, was am Anfang als Rückblick erzählt wird (s.u.), gehört
  zwischen die alten Glieder, nicht dahinter.

## Eine Sitzung beginnt fast immer mit einem Rückblick

Bevor gespielt wird, erzählt die Runde, was beim letzten Mal geschah — „was
haben wir letztes Mal gemacht?", „so, was das letzte Mal passiert ist: …".
Das sind oft **Dutzende Äußerungen** am Sitzungsanfang, und sie erzählen
Vergangenheit, mit eigenen Zeitangaben darin.

Das ist kein Einzelfall wie ein eingestreuter Rückblick, sondern ein Ritual:
**Fast jede Sitzung fängt so an.** Alles darin gehört dorthin, wo es geschah
— nicht an den Anfang dieser Sitzung.

Wie bösartig das ist, zeigt der echte Fall: Eine Sitzung endet mit „es ist
kurz vor zwei". Die nächste beginnt mit einem Rückblick, in dem „es war ja
erst nachts um halb zwei" steht. Liest du das als Gegenwart, beginnt die neue
Sitzung **zwanzig Minuten vor dem Ende der vorigen** — und zwar aus einer
Angabe, die für sich genommen völlig richtig ist.

## Was du über Uhrzeiten wissen musst

**Sag sie, wie sie gesagt wurden.** „Halb elf“, „viertel vor zwölf“, „kurz
nach zwei“ — ich lese diese Formen. Schreib sie nicht in Ziffern um.

**Den Halbtag brauchst du nicht zu entscheiden.** „Drei viertel elf“ ist
10:45 oder 22:45; welches von beiden gilt, ergibt sich aus der Reihe der
Anker, und das rechne ich. Lass das Feld `halbtag` weg — es sei denn, es
steht da („nachts um halb zwei“, „morgens um zehn“): Dann ist der Halbtag
belegt und keine Vermutung.

## Beginn und Ende sind Zeitpunkte, keine Spannen

Steht „ab“, „seit“ oder „von … an“, ist der genannte **Zeitpunkt** der Anker
— nicht die Dauer danach. „Seit heute Morgen“ ist ein `zeitpunkt`, keine
`spanne`; eine Spanne bräuchte ein Ende, das niemand genannt hat.

Dasselbe gilt für „bis“. Und achte auf die **Richtung**, denn beide stehen
manchmal im selben Satz mit derselben Jahreszahl:

> „Ab dem Jahr 2000 ändert sich das grundlegend. Bis zu dem Jahr 2000 bleibt
> die Geschichtsschreibung so, wie wir sie kennen.“

Das sind zwei Anker auf denselben Zeitpunkt, die in entgegengesetzte
Richtungen zeigen.

## Ein Zeitpunkt braucht keinen Kalender

„Tag zwei unserer Bekanntschaft“, „am Tag nach dem Überfall“, „drei Wochen
später“ — das sind **Anker**, auch wenn niemand weiß, welches Datum das ist.
Setz sie. Die Linie trägt Reihenfolge und Abstände ohne Kalendertag.

Es kann durchaus sein, dass in dieser Kampagne **nie** ein Datum fällt, weil
der Spielleiter es bewusst offenlässt. Das ist kein Mangel und kein Grund,
eines zu erfinden.

## Ein Anker hängt an einer MENGE von Äußerungen

Du nennst die Zeilennummern, an denen er hängt — eine, mehrere, eine ganze
Szene. Eine Spanne („wir sind zwei Stunden marschiert“) gehört an die Szene,
nicht an den einen Satz.

An **einer** Zeile dürfen mehrere Anker hängen. „Es ist jetzt grob eine Stunde
vergangen, dann wird es kurz nach zwölf sein“ ist eine Äußerung mit einer
`spanne` **und** einem `zeitpunkt` — beide gehören dorthin. Setzt du einen
zweiten Anker derselben Art an dieselbe Stelle, frage ich zurück und trage
**nichts** ein; dann entscheidest du mit `dazu` oder `ersetzen` über die
Kennung aus meiner Rückfrage.

## Was ein Mensch festgelegt hat, überschreibst du nicht

Manche Stellen sind abgesegnet — ein Spielleiter hat dort ein Datum gesetzt
oder einen Streit entschieden. Dein abweichender Anker wird dort **verworfen**,
und die Antwort sagt dir das. Zwei Wege bleiben: anders einordnen, oder
`konflikt` eintragen, wenn du triftige Gründe hast.

## Der Abschluss

`fertig()` verlangt zweierlei:

1. **Jede Zeile gelesen.**
2. **Jede Zeile entschieden** — in einem Kettenglied oder ausdrücklich
   draussen.

Was es **nicht** verlangt: dass jede Zeile einen Anker hat. Die meisten haben
keinen, und das ist richtig.

Was noch fehlt, sagt dir `offen()` mit Zahlen und Zeilennummern. `zahlen()`
nennt dir den Stand; die Zählung ist meine, nicht deine — nimm sie, statt
selbst nachzuzählen.

Die Werkzeuge erklärt dir `hilfe()`; jedes Feld trägt dort seine eigene
Beschreibung. Frag lieber einmal, als einen Aufruf zu raten: Ein geratener
Aufruf zählt als Wiederholung, eine Frage nicht.
