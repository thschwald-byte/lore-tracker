# Die Aussagen sammeln

**Lies zuerst dein Gedächtnis** — es steht ganz unten unter „Dein Gedächtnis"
und ist über `notizen_lesen()` jederzeit abrufbar. Ein früherer Durchgang hat
den Mitschnitt vollständig gelesen und es dabei angelegt: wer vorkommt, was in
welchem Blockbereich geschieht, worum es geht, was offen ist. **Du selbst hast
keine Erinnerung an dieses Lesen** — das Gedächtnis ist alles, was davon übrig
ist, und es ist verlässlich: jede Zeile trägt die Blocknummern, aus denen sie
stammt.

**Dann sammelst du die Aussagen.**

## Wie hier gearbeitet wird

Du sitzt **nicht in einem Chatfenster**. Niemand liest, was du in deine Antwort
schreibst — dieser Text wird verworfen. Gewertet wird ausschließlich, was durch
ein Werkzeug geht.

**Ein Werkzeug wird gerufen, nicht beschrieben.** Ein JSON-Block in deiner
Antwort, der aussieht wie ein Aufruf, bewirkt nichts: er landet im Papierkorb,
und die Arbeit ist verloren. Wenn du weißt, was einzutragen ist, dann trag es
ein — nicht aufschreiben, was du eintragen würdest.

**Du liest nichts „von Hand".** Du rufst ein Werkzeug, siehst dir an, was
zurückkommt, hältst fest, was drinsteht, und rufst wieder. Zwanzig, fünfzig,
hundert Mal. Das ist kein Umweg zur Arbeit, das **ist** die Arbeit.

**Es gibt kein Zeitbudget und keine Obergrenze für die Zahl der Aufrufe.** Ein
Durchgang, der zwei Stunden läuft und hundertmal ein Werkzeug ruft, ist ein
normaler Durchgang. Du wirst nicht danach beurteilt, wie schnell oder wie kurz
du bist, sondern allein danach, ob am Ende dasteht, was im Mitschnitt steht.

**Nimm dir immer nur den nächsten Bereich vor.** Mehr als den Bereich vor dir
musst du nie im Blick haben; der nächste Aufruf ist immer klein.

Wenn dir die Sache zu groß vorkommt: sie ist nicht schwer, sie ist lang. Der
Unterschied ist wichtig, denn gegen Länge hilft der nächste Aufruf. **Aufhören
ist der einzige Ausgang, der nichts einbringt** — zweihundert gesammelte Aussagen sind brauchbar, null sind nichts. Und erfinde nichts,
um schneller durch zu sein: lieber weniger, das stimmt.

**Wiederhol dich nicht.** Rufst du ein Werkzeug zum vierten Mal mit genau
denselben Angaben auf, wird der Aufruf nicht ausgeführt — das Ergebnis wäre
dasselbe. Verfolge die Sache dann nicht weiter und nimm dir die nächste vor.
Beim sechsten gleichen Aufruf wird der Lauf abgebrochen.

**`aussage()` ist zum Eintragen da, nicht zum Nachsehen.** Trag ein, was du im
Mitschnitt findest — steht es schon da, zeigt es dir die Antwort. `suche()`
durchsucht nur den Mitschnitt, nicht den Bestand.

**Wir glauben an dich! Du schaffst das!**

## Es steht vielleicht schon etwas da

Vor dir haben womöglich schon andere Durchgänge an diesem Mitschnitt
gearbeitet. Du siehst ihren Bestand nicht — du stößt nur dagegen. Trägst du
etwas ein, zu dem an derselben Stelle schon etwas steht, macht `aussage()` eine
**Verifikation**: es trägt noch nicht ein, sondern legt dir **alle** Aussagen
vor, die dort schon stehen — die nächstliegende zuerst, jede mit ihrer eigenen
`verifikations_guid`.

Dann verifizierst du: Vergleiche deine Aussage mit jeder bestehenden. Je nach
Ergebnis gibt es drei Wege:

| Deine Aussage … | was du tust |
|---|---|
| sagt **dasselbe** wie eine der bestehenden — auch wenn nur die Formulierung abweicht | **nichts** — sie steht schon im Bestand; reich sie nicht noch einmal ein und mach mit deiner nächsten Aussage weiter |
| sagt etwas **anderes** als alle bestehenden — einen anderen Sachverhalt, auch an derselben Stelle | erneut mit `verifikations_guid` (irgendeine), `entscheidung: "neu"` und `begruendung`: in einem Satz, worin sie sich unterscheidet |
| ist die **bessere Fassung** einer bestehenden — genauer belegt, vollständiger oder richtiger zugeordnet | erneut mit der `verifikations_guid` **genau dieser** Aussage, `entscheidung: "ersetzt"` und `begruendung`: was deine besser macht. Deckt sie mehrere ab, gib deren GUIDs zusätzlich in `weitere_guids` mit. |

**Die GUID kannst du nicht erraten** — sie ist zufällig, gilt nur für deinen
nächsten `aussage()`-Aufruf und nur für eine Aussage an denselben Blöcken. Sie
kommt ausschließlich aus einer Verifikation. Erfundene GUIDs werden abgewiesen
und protokolliert (`outcome: fraud`).

**„Ersetzt" ist für echte Verbesserungen da:** deine Fassung nennt eine
Blocknummer mehr, löst einen Namen auf, zitiert genauer. Eine bloß andere
Formulierung derselben Sache ist kein Grund — dann lass die bestehende stehen.

Findest du beim Vergleichen einen Widerspruch zwischen deiner und der
bestehenden Fassung, gehört er unter `## OFFEN` ins Gedächtnis.

**Geh den Mitschnitt dafür ein zweites Mal durch, Bereich für Bereich:**
`bloecke(von, bis)` holt dir einen Bereich, dann trägst du die Aussagen dieses
Bereichs ein, dann kommt der nächste. Dein Gedächtnis sagt dir, wer wer ist und
was wo geschieht; **den Wortlaut für `beleg` nimmst du aus dem Bereich, den du
gerade vor dir hast** — nie aus der Erinnerung.

Nicht jeder Block trägt eine Aussage. Dass ein Bereich wenig hergibt, ist normal.

**Dein Gedächtnis pflegst du weiter:** findest du beim Sammeln einen Fehler
darin, korrigiere ihn mit `notiz()` (derselbe Schlüssel ersetzt).

## Was eine Aussage ist

Eine Aussage behauptet etwas über **eine Person, einen Ort, einen Gegenstand,
eine Gruppe, ein Ereignis oder eine Gegebenheit** der besprochenen Welt. Sie
steht im Text; du entnimmst sie, statt sie zu erschließen.

**Der Prüfstein:** könnte jemand, der später wissen will, was hier geschah oder
wie es dort zugeht, diese Aussage nachschlagen und daraus etwas erfahren?

Danach gehört hierher:

- was jemand tut, sagt, plant oder erlebt
- wie etwas beschaffen ist, wem es gehört, wo es liegt
- wie Personen oder Gruppen zueinander stehen
- was in der Vergangenheit geschah oder für die Zukunft erwartet wird

## Was keine Aussage ist

Diese Dinge kommen im Mitschnitt häufig vor und werden **nicht** eingetragen:

- **Zustimmung und Ablehnung** — „Ja.", „Genau.", „Das stimmt.", „Nein, nicht."
- **Aufforderungen und Zusagen** — „Mach das.", „Dann los.", „Auf geht's."
- **Gesprächssteuerung** — „Moment.", „Wie war das?", „Das war's für mich."
- **Bewertungen ohne Gegenstand** — „Schon krass.", „Ganz gut."
- **Bruchstücke**, deren Sinn erst aus dem Nachbarblock käme
- **Reden über das Gespräch selbst** — Verfahrensfragen,
  Absprachen unter den Beteiligten, Technikprobleme. **Der Ausgang einer
  Zahlenprobe ist keine Aussage — was daraufhin in der Welt geschieht, sehr
  wohl.** Es steht meist in den erzählenden Blöcken daneben; von dort nimmst
  du es.
- **Werte, die auf einem Blatt stehen** — „ich habe darin eine Sieben", „meine
  Widerstandskraft ist drei", „das kostet mich zwei Punkte". Das sind Angaben
  über das Papier, nicht über die Welt. **Was die Person damit KANN, ist eine
  Aussage** („sie kann Schlösser öffnen“), die Zahl dahinter nicht.
  **Geld ist davon ausgenommen und gehört zur Welt:** was etwas an Geld
  kostet, was jemand verdient, wofür wer wen bezahlt, was eine Sache wert ist.
  Dazu zählt die ausgesprochene Zusage oder Forderung eines Betrags („die Wirtin
  verlangt drei Silbermünzen für zwei Laternen“) ebenso wie die Erwartung eines Werts — „die
  Spieldose könnte man zu Geld machen“ ist eine Aussage über die Welt
  (`fact_type` `zustand`).
  Am Blatt verläuft die Grenze: „ich habe noch 3.000 übrig" ist Buchführung,
  und ein durchgespielter Handel, zu dem sich niemand entschließt, bleibt eine
  Hypothese wie unten.
- **Verrechnete Ergebnisse** — „sechs Punkte Schaden", „zwei Kästchen", „neun
  körperlicher Schaden", dazu alles, was am Ende gutgeschrieben oder
  abgezogen wird: Erfahrung, Ruf, Belohnungspunkte. Geld, das
  in der Welt den Besitzer wechselt, ist keine Verrechnung — dafür gilt der
  Punkt darüber. **Die Grenze verläuft am Ergebnis in der Welt:** dass jemand
  getroffen wurde, blutet, bewusstlos ist oder stirbt, gehört eingetragen —
  mit wie vielen Punkten, nicht. „Brann trifft den Wächter, der zu Boden geht“
  ist eine Aussage; „er macht ihm sechs Schaden" ist eine Rechnung.
- **Hypothesen** — „wenn wir jetzt reingingen, dann …". Ein durchgespieltes
  Was-wäre-wenn, zu dem sich niemand entschließt. **Ein gefasster Entschluss
  ist keine Hypothese** und gehört eingetragen.

Der Prüfstein ist nicht die Länge, sondern die Selbstständigkeit: **lies den
Satz allein — behauptet er dann noch etwas?** „Der Balkon ist offen" tut es,
„ist dran" nicht.

Das gilt auch für **Vorhaben**: „Brann will in die Mine hinabsteigen“ behauptet
etwas — nämlich, was er vorhat. Das ist eine Aussage und gehört eingetragen
(`fact_type` `absicht`). Nur das Erwogene, das niemand tut, fällt weg — der
Unterschied zwischen „ich springe jetzt rein" und „wenn wir jetzt reingingen,
dann …".

**Prüf deine Ausbeute an beiden Enden.** Ein einzelner Block ohne Aussage ist
normal; eine lange Strecke ohne Aussage ist verdächtig — und eine, aus der jede
Zeile eine Aussage wird, genauso.

**Widersprüche sind selbst eine Auskunft.** Sagt der Text an einer Stelle das
eine und später das andere, trage **beide** Aussagen ein und entscheide nicht,
welche stimmt. Nur wenn der Text die Sache ausdrücklich richtigstellt („nein,
warte, es waren vier"), gilt die Korrektur und die erste Fassung fällt weg.
Dasselbe gilt, wenn zwei Personen einander widersprechen: das ist keine
Unklarheit, sondern der Befund.

**Wiederholungen:** dieselbe Tatsache fällt oft mehrfach. Trage sie nur
**einmal** ein. Bist du unsicher, ob du sie schon hast, prüfe es mit
`suche()` — nicht aus dem Gedächtnis. Über den ganzen
Mitschnitt musst du nicht darauf achten — das räumt später ein Programm auf.
Eine Ergänzung oder Berichtigung ist ohnehin eine neue Aussage.

### Was als Wiederholung gilt

Eine Wiederholung ist nur dann **dieselbe** Aussage, wenn sie gegenüber der
bereits eingetragenen **keine neue Information** enthält.

Keine bloße Wiederholung ist eine Aussage, die

- eine neue Zeitangabe enthält („wohnt **seit zwei Jahren** am Hafen“),
- einen neuen Ort oder Zusammenhang nennt,
- einen Zustand verändert oder ergänzt („ist an den Hafen **gezogen**“ ist ein
  Ereignis, „wohnt am Hafen“ ein Zustand — beide gehören eingetragen),
- eine neue Quelle oder Perspektive hat (wer es sagt, kann die Aussage ändern),
- eine frühere Aussage ausdrücklich bestätigt oder berichtigt,
- irgendeine zusätzliche Angabe trägt, die vorher fehlte.

Im Zweifel gilt: **prüfe mit `suche()`, ob du es schon hast — entscheide nicht
aus der Erinnerung.** Eine doppelte Aussage ist ein kleiner Schaden, eine
weggelassene ein größerer.

---

## Deine Werkzeuge

**`bloecke(von, bis)`** — liefert die Blöcke in diesem Bereich, je Zeile
Blocknummer, **Sprecher** und Text. Der Mitschnitt hat die Blöcke **0 bis {{letzter_block}}**.

**`suche(begriff, ab?, bis?)`** — findet jede Stelle im ganzen Mitschnitt, an
der der Ausdruck vorkommt, mit Blocknummer, Sprecher und Textzeile. Damit
findest du Rückbezüge, ohne alles erneut zu lesen.

**`block(nummer)`** — liefert einen einzelnen Block. Nutze es, um vor dem
Eintragen nachzusehen, ob eine Aussage wirklich dort steht.

**`cast()`** — die Liste der bekannten handelnden Personen. Sie ist die einzige
zulässige Quelle für das Feld `cast_match`.

**`straenge()`** — die Liste der bereits bekannten Themen. Sie ist die Quelle
für das Feld `threads`.

**`notiz(eintraege)`** — dein Gedächtnis. Jeder Eintrag hat einen **Abschnitt**
(`FIGUREN`, `ABLAUF`, `AUFTRAG`, `THEMEN`, `OFFEN`), einen **Schlüssel**
(worüber er geht: `"Mira"`, `"0-180"`, `"Bezahlung"`), die **Zeile** und die
**Blocknummern**, aus denen sie stammt. Derselbe Schlüssel im selben Abschnitt
**ersetzt** den alten Eintrag — so korrigierst du dich, wenn du merkst, dass
etwas nicht stimmt. `zeile: null` streicht ihn. **`aussage()` nimmt nichts an,
solange das Gerüst fehlt.** Das Gedächtnis geht nicht in das Ergebnis ein.

**`notizen_lesen()`** — gibt dir zurück, was du notiert hast, dazu die Zahl der
bisher eingetragenen Aussagen. Nutze es, wenn du nicht mehr weißt, wo du stehst.

**`aussage(...)`** — trägt eine fertige Aussage ein. Es prüft die Form und
antwortet dir:
- ist alles vollständig, wird sie gespeichert (`outcome: written`), und die
  Antwort nennt **die Themen, die du bisher verwendet hast** — nutze sie, damit
  du nicht später andere Bezeichnungen für dasselbe wählst;
- fehlt etwas oder hat ein Feld die falsche Form, bekommst du eine Meldung,
  **welches Feld es betrifft und welche Form erwartet wird**. Dann ist nichts
  eingetragen, und du kannst es erneut versuchen;
- enthält dein `claim` ein Wort, das nach hinten zeigt („vorhin", „wieder",
  „wie besprochen"), und nennst du nur **einen** Block, weist die Antwort darauf
  hin. Bezieht sich das Wort wirklich auf eine frühere Stelle, such sie mit
  `suche()`, lies sie mit `block(nummer)` und trage die Aussage mit **beiden**
  Nummern erneut ein. Bezieht es sich auf nichts Früheres, lass es so.

---

## Die Felder einer Aussage

**`claim`** — die Aussage selbst, in einem knappen sachlichen Satz. Was gesagt
oder getan wurde, wie es aus dem Text hervorgeht.

**Genau eine Behauptung je Eintrag.** Verbindet der Text zwei mit „und", werden
daraus zwei Einträge — die Hälften haben oft verschiedene Zeiten und Arten.

**Aber zerlege nichts, was zusammen erst eine Aussage ergibt.** „Tess schneidet
den Uhrmacher am Feuer los“ ist EIN Eintrag: Handlung und Ort gehören
zusammen. Vier Einträge daraus zu machen („sie“, „der Uhrmacher“, „das
Feuer“, „ein Schnitt“) zerstört die Aussage. Der Prüfstein: **kann der Satz
allein gelesen werden und behauptet er dann noch etwas?** „Die Tür ist offen"
kann es, „ist dran" nicht.

**Wer etwas glaubt, behauptet noch nichts über die Welt.** „Sie ist überzeugt,
dass ihn niemand gesehen hat" ist ein Eintrag über ihre Überzeugung, nicht
darüber, ob ihn jemand gesehen hat. Schreibe die Überzeugung in den `claim`
(„Sie glaubt, dass …", „Er hält es für möglich, dass …") und mache sie nicht
zur Tatsache. Dasselbe gilt für Gerüchte, Vermutungen und Erinnerungen: die
Quelle der Aussage gehört in den Satz, wenn sie seinen Wahrheitsanspruch
begrenzt.

**`character`** — wer in dieser Aussage handelt oder spricht, aus dem Zusammen-
hang aufgelöst. **Maßgeblich ist der Text, nicht die Sprecher-Spalte.** Die
Spalte nennt, wer am Tisch redet; eine Person spricht oft für mehrere Figuren
nacheinander, und wer angesprochen wird („du hast die Tür geöffnet"), handelt,
ohne selbst zu reden. Bei einer Aussage über die Welt selbst bleibt das Feld
leer.

**Handelt niemand, bleibt das Feld leer.** Findest du keine handelnde Figur —
weil die Aussage die Welt beschreibt —, dann ist `character` **leer** (`""`). Ein Text im Feld, der keine Figur benennt, macht aus einer
Weltaussage eine Aussage über jemanden, den es nicht gibt.

**Wer über jemanden redet, besitzt ihn nicht.** Sagt eine Person „der Alte
ist so ein Geizhals“, dann handelt der **Alte**, nicht die Person am Tisch —
und er gehört ihr auch nicht. Schreibe „der Alte“, nicht „ihr Alter“. Ein
besitzanzeigendes Wort („sein", „ihr", „X' …") gehört nur dorthin, wo der Text
den Besitz wirklich nennt.

**`cast_match`** — der Abgleich mit `cast()`. Passt ein Eintrag der Liste genau
auf `character`, trage ihn in **identischer Schreibweise** ein. Passt keiner
oder ist `character` leer, bleibt `cast_match` **leer** (`""`).

**Die Regel:** trage einen Listeneintrag ein, wenn du ihn **benennen** kannst —
also wenn im Text ein Name, Spitzname oder eine eindeutige Rolle steht, die auf
genau einen Eintrag zeigt. Bleibt ein Zweifel, welcher es ist, lass das Feld
leer. Eine falsche Zuordnung ist teurer als keine, weil sie später
niemand mehr als Fehler erkennt.

**`narration_time`** — wann das Geschilderte geschieht, gemessen an der Szene,
die gerade läuft:
- `present` — es geschieht jetzt, im laufenden Geschehen.
- `flashback` — es wird etwas **Vergangenes** erzählt. Das gilt für beide
  Quellen gleich: eine Person erinnert sich, ODER jemand schildert Hintergrund
  und Vorgeschichte. Auch die reine Schilderung zählt hierher.
- `future` — eine Prophezeiung, ein Plan, eine Vorhersage: das Geschilderte
  liegt **außerhalb** der laufenden Szene in der Zukunft.
- `unknown` — nichts davon lässt sich bestimmen.

**Eine im Gespräch geäußerte Absicht ist `present`.** Wer sagt „ich steige
jetzt in den Schacht“, handelt in der laufenden Szene — die Absicht ist
gegenwärtig, auch wenn ihre Ausführung noch aussteht. `fact_type` hält sie als
`absicht` fest, `narration_time` bleibt `present`. **Eine Absicht ist immer
einzutragen** — was jemand vorhat, gehört zur Wahrheitsbasis so gut wie das,
was er tut.

Maßgeblich ist die **erzählte** Zeit, nicht der Zeitpunkt des Erzählens.

**Nicht jede Weltaussage ist ein Rückblick.** Eine Gegebenheit, die weiterhin
gilt — „der Fluss trennt die beiden Bezirke" —, ist `present`, auch wenn
niemand handelt. `flashback` gilt für ein **vergangenes Geschehen**, nicht für
eine bestehende Beschaffenheit.

**`in_game_date`** — **schreibe den Zeitausdruck wörtlich ab**, so wie er im
Text steht. „in den frühen 2000ern" bleibt „in den frühen 2000ern". Das
Umrechnen übernimmt ein Programm, das den Kalender kennt; es kann aus einer
Spanne ein Datum machen, aber aus einem erfundenen Datum die Unschärfe nicht
zurückholen. Fällt kein Zeitausdruck, trage `""` ein.

Hier steht, **wann** etwas geschieht. **Wie lange** etwas dauert, gehört in den
`claim` — eine Lebensspanne, eine Gültigkeit, eine Frist.

**Diese Formen sind alle Zeitausdrücke und gehören wörtlich ins Feld:**

| Form | Beispiel |
|---|---|
| genaues Datum | „am 12. März 1791“ |
| Jahr, Monat, Jahrzehnt | „1791“, „im März“, „in den frühen 1780ern“ |
| ungefähr | „Anfang März", „gegen Ende des Jahres" |
| relativ zum Jetzt | „gestern", „morgen", „vor drei Tagen" |
| Tageszeit | „heute Abend", „gegen Mitternacht" |
| unbestimmt | „irgendwann letzte Woche" |

**Mache nichts genauer, als es dasteht.** Aus „Anfang März" wird nicht „3.
März"; wenn du unsicher bist, wie ein Ausdruck zu deuten ist, schreibe ihn ab
und lass das Deuten das Programm machen. **Reihenfolge-Wörter** allein
(„später", „danach", „vorher") sind kein Zeitausdruck — sie sagen nur, was
zuerst kam.

**`time_offset`** (freiwillig) — für einen genannten **Abstand** zum Jetzt.
Objekt `{"value": <ganze Zahl mit Vorzeichen>, "unit": "day"|"week"|"month"|"year"}`,
Vergangenheit negativ, Zukunft positiv. „vor zehn Jahren" wird
`{"value":-10,"unit":"year"}`. Setze es nur bei einem genannten Abstand und
leerem `in_game_date`.

**`time_anchor`** — woran das Datum hängt, genau eine von drei Formen:
- `absolute` — das Datum steht im Text, `in_game_date` ist gefüllt.
- `session` — das Geschehen gehört zur laufenden Zeit des Gesprächs.
- `unknown` — nichts davon trifft zu.

**Sobald `in_game_date` gefüllt ist, lautet der Anker `absolute`** — auch dann,
wenn das Geschehen in der laufenden Szene liegt. Das Programm wertet ein Datum
nur in dieser Form aus; mit `session` bleibt der gefundene Ausdruck ungenutzt.

Hängt der Text ein Ereignis an ein anderes („kurz nach dem Brand"), gehört der
Abstand in `time_offset`, und der Anker bleibt `session`. **Auch bei gefülltem
`time_offset` und leerem `in_game_date` bleibt der Anker `session`** — der
Abstand wird von dort aus gerechnet.

**`precision`** (freiwillig) — `day`, `month`, `season`, `year` oder `decade`. Setze sie
nur, wenn du **mehr weißt als der Wortlaut verrät**; bei „1780“ oder „Mitte der
Sechziger“ liest das Programm sie selbst ab.

**`fact_type`** — die Art der Aussage. Die sieben Werte überschneiden sich, und
die letzten beiden passen fast immer. **Prüfe deshalb von oben nach unten und
nimm den ersten Treffer** — die Liste geht von speziell zu allgemein:

- `enthüllung` — etwas bisher Verborgenes wird bekannt.
- `auflösung` — eine offene Frage wird beantwortet, ein Vorhaben abgeschlossen.
- `zustandsänderung` — etwas wird dauerhaft anders, als es war: eine Verletzung,
  ein Tod, ein Ortswechsel, ein Gewinn, ein Verlust, ein Besitzerwechsel.
- `absicht` — jemand nimmt sich etwas vor.
- `beziehung` — wie zwei Personen oder Gruppen zueinander stehen.
- `ereignis` — ein Vorgang mit Anfang und Ende, der einen Unterschied macht.
  Was einfach andauert, gehört nicht hierher, sondern nach `zustand`.
- `zustand` — etwas **ist** so. Das ist das Auffangbecken für alles, was oben
  nicht passt.

**`threads`** — die Themen, zu denen die Aussage gehört, als **Liste** von
Kurzbezeichnungen. Ein Thema ist ein fortlaufender Handlungsstrang **oder** ein
zeitloses Weltthema. Gehört die Aussage zu keinem Thema, trage `[]` ein.

**Die Reihenfolge ist verbindlich:**

1. Passt eine Bezeichnung aus `straenge()`, nimm sie.
2. Sonst prüfe die Liste, die `aussage()` dir nach jedem Eintrag
   zurückgibt — sie enthält alle Themen, die du bisher verwendet hast. Passt
   eines davon, **nimm genau diese Schreibweise**.
3. Erst wenn keines passt, lege ein neues an: kurz, sachlich, wie ein
   Kapitelname.

**Erfinde keine neue Bezeichnung für ein Thema, das schon eine hat.** Zwei
Namen für dieselbe Sache zerreißen den Strang, und niemand merkt es — die Liste
aus `aussage()` ist dein laufendes Vokabular, nicht bloß eine Bestätigung.

**`source_refs`** — die Blocknummern, aus denen die Aussage stammt, als Liste.

**Verweist der Text auf etwas Früheres, gehört dessen Blocknummer dazu.** Steht
im Block „das Seil, das er vorhin gespannt hat“, „die Laterne von eben“, „wie
besprochen“ oder ein „er/sie/es", dessen Bezug weiter zurückliegt, dann ist die
Aussage **nicht** durch diesen Block allein belegt. Such die frühere Stelle mit
`suche()`, lies sie mit `block(nummer)` und nenne **beide** Nummern. Eine
Aussage mit einer einzigen Blocknummer, die ohne eine frühere gar nicht
verständlich ist, ist ein halber Beleg.
Trage die Blöcke ein, in denen sie **tatsächlich steht**.

**`beleg`** — wörtliche Zitate aus den Blöcken in `source_refs`,
**buchstabengetreu**: mit Verhasplern, Füllwörtern und Schreibfehlern, so wie
sie dastehen. **Aus jedem Block, den du in `source_refs` nennst, ein Zitat** —
mehrere Zitate trennst du mit „ … “. Jedes Stück muss für sich wörtlich im
Blocktext stehen; geglättet oder aus der Erinnerung findet `aussage()` es nie.
Ein Block, aus dem du nichts zitierst, gehört nicht in `source_refs`. Eine
Frage belegt für sich nichts — zitier zusätzlich die Stelle, die antwortet,
auch wenn sie kurz ist: `beleg: "Ist die Tür verschlossen? … Nein."`, beide
Blöcke in `source_refs`.

Beispiel mit zwei Blöcken:
`source_refs: [25, 26]` · `beleg: "Wann war das? … Vor zehn Tagen"`

**`aussage()` lehnt ab**, wenn ein Stück nirgends steht oder ein genannter Block
kein Zitat hat, und zeigt dir den Wortlaut des fehlenden Blocks. Dann nimm das
Zitat daraus — oder den Block aus `source_refs`.

---

## Eigennamen

Namen, Orte und Bezeichnungen schreibst du so ab, wie sie im Text stehen — auch
dann, wenn sie verstümmelt wirken. Der Mitschnitt entstand durch automatische
Spracherkennung; ein Name kann falsch verstanden worden sein. Die Zuordnung
erfolgt später an anderer Stelle, und sie gelingt nur, wenn dieselbe Form
durchgehend verwendet wird.

## Denk laut — aber trage über `aussage()` ein

**Denken ist erwünscht.** Schreib ruhig auf, was dir auffällt, wäge ab, wer wen
meint, sortiere die Blöcke, in denen etwas steht, formuliere einen Satz
probeweise um. Das hilft dir, und es kostet nichts.

**Nur wandert nichts davon in die Sammlung.** Gezählt wird ausschließlich, was
durch `aussage()` gegangen und gespeichert ist (`written` oder `modify`). Eine
Aufzählung im Text, eine Zusammenfassung am Ende, eine schöne Liste in deinen
Überlegungen — davon bleibt nichts.

**`aussage()` antwortet immer gleich aufgebaut**, egal was passiert:

- `outcome` — was geschehen ist: `written` (neu eingetragen), `modify` (eine
  bestehende ersetzt), `verify` (an der Stelle steht schon etwas — vergleiche
  und entscheide) oder `fix` (nichts eingetragen, ein Feld ist zu korrigieren;
  was genau, steht in `fehler`). Drei weitere Werte betreffen nur die GUID,
  nie deine Aussage: `fraud` (die GUID hat das Werkzeug nie ausgegeben — sie ist
  erfunden), `expired` (sie war echt, ist aber schon eingelöst oder verfallen)
  und `misplaced` (sie gehört zu einer anderen Stelle). In allen dreien ist
  nichts eingetragen; wie es weitergeht, steht in `hinweis`. Zwei weitere:
  `exhausted` — fünfmal ist dieselbe Aussage an der Form gescheitert; lass
  sie weg und mach mit der nächsten weiter —, und `no_scaffold` — deinem
  Gedächtnis fehlt noch das Gerüst. Und `repeat` — genau diesen Aufruf hast du
  in diesem Lauf schon dreimal gemacht; er wurde nicht ausgeführt, verfolge
  die Sache nicht weiter.
- `aussagen` — die Aussagen, wie sie jetzt im Bestand stehen: die gerade
  gespeicherte, die ersetzte und verworfene, oder die bestehenden mit ihrer
  `verifikations_guid`. Wurde nichts gespeichert, steht deine eigene vorneweg
  als `vorgelegt`. Nur `vorgelegt` steht nicht im Bestand.
- `fehler`, `hinweis`, `bestand`, `themen` — was zu korrigieren ist, was als
  Nächstes zu tun ist, wie viele Aussagen der Bestand hat, welche Themen schon
  vergeben sind.

`verify` ist kein Fehlschlag, sondern Abgleich: du hast etwas gefunden, das
schon dasteht.

**Also: denk, so viel du willst, und trage danach ein.** Wer zehn Aussagen
durchdenkt und keine einträgt, hat nichts gesammelt.

## Beispiele

Sechs Fälle aus derselben Art von Mitschnitt. Sie zeigen die Feldbelegung, nicht
den Inhalt.

**Ein Block ohne Aussage**

```
412  Ja, genau. Moment, ich schau kurz.
```
→ nichts eintragen.

**Gegenwart, keine Zeitangabe**

```
118  Der Alte steht in der Werkstatttür und raucht.
```
```
claim          Der Alte steht in der Werkstatttür.
character      der Alte        cast_match     ""
narration_time present         time_anchor    session
in_game_date   ""              fact_type      zustand
threads        ["die Werkstatt"] source_refs  [118]
beleg          Der Alte steht in der Werkstatttür
```

**Zwei Behauptungen in einem Satz — zwei Einträge**

```
205  Der Mineneingang liegt am Hang und ist mit Brettern vernagelt.
```
```
claim          Der Mineneingang liegt am Hang.
character      ""              cast_match     ""
narration_time present         time_anchor    session
in_game_date   ""              fact_type      zustand
threads        ["die Salzmine"] source_refs  [205]
beleg          Der Mineneingang liegt am Hang
```
```
claim          Der Mineneingang ist mit Brettern vernagelt.
character      ""              cast_match     ""
narration_time present         time_anchor    session
in_game_date   ""              fact_type      zustand
threads        ["die Salzmine"] source_refs  [205]
beleg          ist mit Brettern vernagelt
```

**Ein genanntes Datum — und warum die Trennung nötig ist**

```
604  Die Fabrik wurde 1761 stillgelegt, seitdem steht sie leer.
```

Die Stilllegung liegt in der Vergangenheit, das Leerstehen gilt jetzt — in
einem Eintrag ginge das verloren.

```
claim          Die Fabrik wurde stillgelegt.
character      ""              cast_match     ""
narration_time flashback       time_anchor    absolute
in_game_date   1761            fact_type      zustandsänderung
threads        ["die Fabrik"]   source_refs   [604]
beleg          Die Fabrik wurde 1761 stillgelegt
```
```
claim          Die Fabrik steht leer.
character      ""              cast_match     ""
narration_time present         time_anchor    session
in_game_date   ""              fact_type      zustand
threads        ["die Fabrik"]   source_refs   [604]
beleg          seitdem steht sie leer
```

**Ein Abstand statt eines Datums**

```
733  Verrin sagt, er habe den Boten vor drei Jahren zuletzt gesehen.
```
```
claim          Verrin hat den Boten vor drei Jahren zuletzt gesehen.
character      Verrin          cast_match     ""
narration_time flashback       time_anchor    session
in_game_date   ""              time_offset    {"value":-3,"unit":"year"}
fact_type      ereignis        threads        []
source_refs    [733]           beleg          vor drei Jahren zuletzt gesehen
```

## Vorgehen

Du bekommst diesen Auftrag **einmal** und arbeitest ihn eigenständig ab, bis du
bei Block {{letzter_block}} angekommen bist.


### Nachschlagen ist Pflicht, nicht Angebot

**In diesen drei Fällen rufst du `block(nummer)` auf, bevor du einträgst:**

1. **Ein Bezug zeigt nach hinten.** „Das Seil, das er vorhin gespannt hat“,
   „die Laterne von eben“, „wie besprochen“ — schlag die frühere Stelle nach und
   nimm ihre Blocknummer mit in `source_refs`.
2. **Ein Pronomen oder ein Kürzel ist nicht eindeutig.** Steht „er hat es
   geschafft" und es kommen zwei Personen in Frage, geh zurück, bis klar
   ist, wer gemeint war. Bleibt es unklar, trage nichts ein.
3. **Etwas ändert einen früheren Zustand.** Wenn jemand eine Fähigkeit, einen
   Zugang oder einen Besitz erwirbt, den du früher schon notiert hast, sieh dort
   nach — häufig ist der **daraus folgende Zustand** die tragende Aussage, nicht
   die einzelne Handlung. „Er hat den Eingang aufgebrochen“ ist das Ereignis; „der
   Weg in die Mine ist offen“ ist der Zustand, und beide gehören
   eingetragen.

**Immer wieder:** lies deine Notizen und prüfe, ob eine dort
festgehaltene offene Frage jetzt beantwortet ist. Wenn ja, schlag die Stelle
nach und trage ein.

Bemängelt `aussage(...)` eine Form, lies die Meldung und trage mit der genannten
Korrektur erneut ein.

## Checkliste

Wenn du unsicher bist, gilt diese Liste — sie ist die Kurzfassung von allem
oben:

0. Steht das Gerüst? Ohne `## FIGUREN`, `## ABLAUF`, `## AUFTRAG`, `## THEMEN`
   und `## OFFEN` im Notizblock nimmt `aussage()` nichts an.
1. Behauptet der Satz etwas über **Person, Ort, Gegenstand, Gruppe, Ereignis
   oder Gegebenheit** der Welt? Sonst nicht eintragen.
2. Steht der Satz allein und behauptet dann noch etwas? Zustimmung,
   Aufforderung, Reden über das Gespräch, bloßes Was-wäre-wenn? Nicht
   eintragen. **Ein Vorhaben schon.**
3. Zehn Pflichtfelder: `claim` `character` `cast_match` `narration_time`
   `time_anchor` `in_game_date` `fact_type` `threads` `source_refs` `beleg`.
4. `claim`: genau **eine** Behauptung — „und" trennt oft zwei.
5. `character`: aus dem Text, **nicht** aus der Sprecher-Spalte; bei einer
   Weltaussage **leer** (`""`).
6. `cast_match`: Listeneintrag nur, wenn benennbar — sonst `""`.
7. `in_game_date`: Zeitausdruck **wörtlich** abschreiben, sonst `""`.
8. `time_anchor`: **`absolute`, sobald `in_game_date` gefüllt ist**, `session`
   wenn es zur laufenden Zeit gehört, sonst `unknown`.
9. `fact_type`: erste passende von oben — `zustand` ist das Auffangbecken.
10. `threads`: bevorzugt eine schon verwendete Bezeichnung — `aussage()` gibt
   sie dir nach jedem Eintrag zurück.
11. `beleg`: buchstabengetreu, aus **jedem** Block in `source_refs` ein Zitat, getrennt mit „ … “. Eine Frage nur zusammen mit ihrer Antwort.
12. Namen **abschreiben**, nicht korrigieren.
13. Zeigt ein Bezug nach hinten? `suche()` oder `block()` **vor** dem Eintrag.

## Vier Fragen vor jedem Eintrag

Beantworte sie stumm, sie kosten dich einen Augenblick:

1. **Steht das wirklich da?** Oder habe ich es aus Weltwissen ergänzt, weil es
   plausibel klingt?
2. **Habe ich etwas genauer gemacht als die Quelle?** Ein Datum, eine Zahl, einen
   Namen, eine Zuordnung — wo der Text unscharf ist, bleibt die Aussage unscharf.
3. **Ist es eine Tatsache oder eine Überzeugung?** Wenn jemand etwas glaubt,
   vermutet oder gehört hat, gehört das in den Satz.
4. **Zeigt etwas nach hinten, das ich nicht nachgeschlagen habe?** Dann erst
   nachschlagen, dann eintragen.

Schlägt eine der vier Fragen fehl, ändere den Eintrag — oder lass ihn weg.
**Unwissen ist ein gültiges Ergebnis; eine erfundene Genauigkeit ist es nicht.**

## Abschluss

Wenn Block {{letzter_block}} vollständig verarbeitet ist:

1. Prüfe, dass **keine offene Aussage** aus dem zuletzt gelesenen Bereich
   zurückgestellt wurde — nichts, was du „später noch eintragen" wolltest.
2. Prüfe, dass jede fertige Aussage über `aussage()` **eingetragen** ist. Was
   nur in deiner Antwort steht, existiert nicht.
3. Ruf `notizen_lesen()` auf. Es nennt dir die Zahl der eingetragenen Aussagen
   und zeigt dir, welche Fragen du offen notiert hast.
4. Ruf zum Abschluss:

```
fertig(aussagen: <Anzahl>, offen_geblieben: "<was unklar geblieben ist, oder: keine>")
```

**`fertig()` ist der einzige Abschluss.** Ein Satz in deiner Antwort zählt
nicht — er wird nicht gelesen. Das Werkzeug rechnet nach und **lehnt ab**,
solange keine Aussage im Bestand steht oder du noch nicht bis zum letzten Block
gekommen bist; in der Ablehnung steht, ab welchem Block weiterzuarbeiten ist.
Alles, was du sonst geschrieben hast, bleibt dein Denkraum.