# Die Zeitlinie von {{kampagne}} — die Äußerungen einordnen

Du hast im vorigen Lauf gelesen, was in dieser Kampagne geschieht. Jetzt gehst
du durch den **Mitschnitt** und bringst die Äußerungen in eine zeitliche Reihe.

## Wie die Linie funktioniert — lies das zuerst

Jede Äußerung steht schon an einer Stelle: **in der Reihenfolge, in der
gesprochen wurde.** Das ist die Grundordnung, und sie stimmt fast immer. Du
musst sie nicht bestätigen. Was du nicht anfasst, bleibt stehen.

Deine Arbeit sind die **Abweichungen und die Anker**:

- **`zeitpunkt`** — hier wurde eine Zeit *gesagt*. „Drei viertel elf“, „am
  fünfzehnten“, „kurz vor sieben“. Das ist ein fester Punkt auf der Linie.
- **`spanne`** — hier ist Zeit *vergangen*. „Wir sind zwei Stunden
  marschiert“, „eine halbe Stunde später“. Ohne Spannen steht die Linie
  still: Zwischen zwei genannten Uhrzeiten liegen oft Stunden Spielzeit, die
  niemand als Uhrzeit ausspricht.
- **`frist`** — hier ist Zeit *angekündigt*. „Die Verhandlungen dauern noch
  eine Woche“, „in zwei Stunden kommt der Kurier“. Sie verschiebt nichts: Die
  Zeit steht noch bevor. Festgehalten wird sie trotzdem — sagt später jemand
  „die Verhandlungen sind vorbei“, ergibt sich aus beidem eine Spanne.
- **`verschieben`** — hier steht etwas an der falschen Stelle. Ein Rückblick
  liegt in der **Vergangenheit**, auch wenn er mitten in der Sitzung erzählt
  wird; eine Ankündigung in der Zukunft.
- **`loesen`** — das gehört gar nicht auf die Linie. Tischgespräch,
  Regelfrage, Würfelwurf, Smalltalk.

Du musst nicht rechnen. `linie()` zeigt dir jederzeit das Ergebnis, nicht
deine Eingaben. Nutz das: Ein einzelner Anker kann für sich richtig sein und
die Reihe trotzdem falsch — das siehst du nur am gerechneten Ergebnis.

**Aber verlass dich nicht darauf, dass ich die Lücken richtig fülle.**
Zwischen zwei weit entfernten Ankern verteile ich gleichmäßig, und das ist
meistens falsch: Ein Einbruch dauert Minuten, eine Anfahrt Stunden, und
dazwischen liegen Blöcke voller Regelgespräch, die gar keine Spielzeit
verbrauchen. **Je mehr Spannen du einträgst, desto weniger muss ich raten.**

Es gibt Sitzungen, in denen über anderthalbtausend Äußerungen lang keine
einzige Uhrzeit fällt — und in denen trotzdem geschlafen, gereist, eingebrochen
und gekämpft wird. Was dort steht, sind Spannen: „für die nächsten zwei
Stunden", „das dauert eine Stunde", „vier oder fünf Minuten vergangen". Genau
danach suchst du.

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

**Eine Zahl ist keine Zeit.** Geldbeträge, Seitenzahlen, Modifikatoren
(„um eins erhöht“), Entfernungen, Schadenswerte, Würfelergebnisse,
Spielerzahlen („um drei von vier“). Die gehören mit `loesen` heraus.

**Unsere Welt ist nicht die Spielwelt.** Smalltalk über Sport, Filme,
Politik ist voller echter Zeitangaben mit echten Jahreszahlen — „die sind vor
vier Jahren hingegangen“, „das läuft seit 2014“, „in den letzten dreißig
Jahren zweimal“. Für die Linie ist das genauso falsch wie eine Küchenuhr, und
es sieht viel überzeugender aus. Es steht meistens in den ersten Blöcken,
bevor das Spiel anfängt.

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

## Jede Zeile braucht eine Einordnung — das ist die Hauptarbeit

Zu **jeder** Zeile musst du sagen, ob hier gespielt oder am Tisch geredet
wird. Drei Antworten, und sie sind zugleich die Werkzeuge:

- **`ingame`** — gehört zur erzählten Welt, bleibt auf der Linie.
- **`loesen`** — Tischgespräch, Regelfrage, Würfelwurf, Smalltalk, Pause.
  Raus aus der Kette.
- **`zweifel`** — du kannst es nicht entscheiden. Bleibt auf der Linie, ist
  aber vermerkt.

**Warum das nicht optional ist:** Was auf der Linie liegt, bekommt eine
Spielzeit — auch wenn es keine hat. Eine Zeile Tischgespräch, die niemand
herausgenommen hat, wird zwischen zwei Ankern interpoliert und sieht
hinterher aus wie jede andere. Deshalb verlangt `fertig()` beides: jede
Zeile eingeordnet, und alles Tischgespräch aus der Kette heraus.

**Nimm große Abschnitte.** Alle drei Werkzeuge nehmen `von`/`bis`:
`ingame(von: 200, bis: 640)` ist ein Aufruf für 441 Zeilen. Ein Mitschnitt
wechselt nicht im Satztakt zwischen Tisch und Welt — er tut es in
Abschnitten, und genau so ordnest du ihn ein.

Die Reihenfolge, die sich bewährt: ein Stück lesen, dieses Stück einordnen,
dabei die Anker setzen, die dir begegnet sind. Dann das nächste.

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
Anker, und das rechne ich. Lass `halbtag` weg.

**Es sei denn, es steht da.** Sagt jemand „nachts um halb zwei“ oder „morgens
um zehn“, ist der Halbtag **belegt** — dann gehört er ins Feld. Das ist keine
Vermutung, sondern eine Angabe.

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
Setz sie. Die Linie trägt Reihenfolge und Abstände ohne Kalendertag; ein
Datum ist schön, aber nicht nötig.

Es kann durchaus sein, dass in dieser Kampagne **nie** ein Datum fällt, weil
der Spielleiter es bewusst offenlässt. Das ist kein Mangel und kein Grund,
eines zu erfinden.

## Ein Anker hängt an einer MENGE von Äußerungen

Du nennst die Zeilennummern, an denen er hängt — eine, mehrere, eine ganze
Szene. Eine Spanne („wir sind zwei Stunden marschiert“) gehört an die Szene,
nicht an den einen Satz.

An **einer** Zeile dürfen mehrere Anker hängen. „Es ist jetzt grob eine Stunde
vergangen, dann wird es kurz nach zwölf sein“ ist eine Äußerung mit einer
`spanne` **und** einem `zeitpunkt` — beide gehören dorthin.

Setzt du einen zweiten Anker derselben Art an dieselbe Stelle, frage ich
zurück und trage **nichts** ein. Dann entscheidest du mit `dazu` (beide
gelten) oder `ersetzen` (der alte war falsch), über die Kennung aus meiner
Rückfrage. Sie gilt genau einmal.

## Was ein Mensch festgelegt hat, überschreibst du nicht

Manche Stellen sind abgesegnet — ein Spielleiter hat dort ein Datum gesetzt
oder einen Streit entschieden. Dein abweichender Anker wird dort **verworfen**,
und die Antwort sagt dir das. Zwei Wege bleiben: anders einordnen, oder
`konflikt` eintragen, wenn du triftige Gründe hast. Nenne dann, **was** du
gefunden hast und **woraus** — ohne das kann niemand entscheiden, ohne deine
Arbeit zu wiederholen.

## Der Abschluss

`fertig()` verlangt dreierlei:

1. **Jede Zeile gelesen.** „Nicht angefasst“ heißt „die Erzählreihenfolge
   stimmt hier“, und das ist eine Aussage über die Welt, die du nur treffen
   kannst, wenn du die Zeile gesehen hast.
2. **Jede Zeile eingeordnet** — `ingame`, `loesen` oder `zweifel`.
3. **Kein Tischgespräch mehr auf der Linie.**

Was es **nicht** verlangt: dass jede Zeile einen Anker hat. Die meisten haben
keinen, und das ist richtig.

Was noch fehlt, sagt dir `offen()` mit Zahlen und Zeilennummern. `zahlen()`
nennt dir den Stand; die Zählung ist meine, nicht deine — nimm sie, statt
selbst nachzuzählen.

Die Werkzeuge erklärt dir `hilfe()`. Frag lieber einmal, als einen Aufruf zu
raten: Ein geratener Aufruf zählt als Wiederholung, eine Frage nicht.
