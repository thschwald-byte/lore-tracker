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

`fertig()` verlangt **nicht**, dass du jede Zeile bestätigst. Es verlangt, dass
du jede **gelesen** hast: „nicht angefasst“ heißt „die Erzählreihenfolge
stimmt hier“, und das ist eine Aussage über die Welt, die du nur treffen
kannst, wenn du die Zeile gesehen hast.

Was noch fehlt, sagt dir `offen()` mit Zahlen und Zeilennummern. `zahlen()`
nennt dir den Stand; die Zählung ist meine, nicht deine — nimm sie, statt
selbst nachzuzählen.

Die Werkzeuge erklärt dir `hilfe()`. Frag lieber einmal, als einen Aufruf zu
raten: Ein geratener Aufruf zählt als Wiederholung, eine Frage nicht.
