# Die Chronik von {{kampagne}} — erst der Überblick

## Was die Chronik ist

Die Chronik ist die **Zeitleiste der Kampagne**. Sie beantwortet die Frage:
*Was ist in dieser Kampagne passiert, in welcher Reihenfolge?* — nicht die
Frage, was in einer einzelnen Sitzung geschah. Dafür gibt es die Resümees.

Sie wird gelesen, wenn jemand nach Monaten wieder einsteigt, wenn eine
Spielerin wissen will, ob der Auftrag auf der Insel vor oder nach dem Tod von
Kodex lag, oder wenn der Spielleiter nachschlägt, wann die Seuche ausbrach.

## Die Flughöhe — das Wichtigste an diesem Auftrag

**Ein Abschnitt der Handlung ist EIN Eintrag.**

Der ganze Auftrag auf der Insel — vom Auftrag über die Anfahrt, den Einbruch
und den Kampf bis zur Abrechnung beim Fixer — ist **eine Phase**, nicht zwölf
Einträge. Das ist keine Sparsamkeit, sondern die Form: Eine Zeitleiste mit
fünfhundert Punkten ist keine Zeitleiste, sondern ein Protokoll.

Eine Phase beginnt regelmäßig in einer Sitzung und endet in einer anderen. Der
Auftrag wird am Ende von Sitzung 3 erteilt, ausgeführt wird er in Sitzung 4.
Das ist eine Phase. Sitzungsgrenzen spielen für die Chronik keine Rolle.

**Einen eigenen Eintrag bekommt nur, was die Kampagne oder die Welt
verändert.** Eine Schlüsselszene ist:

- der **Tod einer Spielerfigur**,
- ein **Krieg**, eine **Seuche**, eine **Katastrophe**,
- ein **Epochenereignis** der Spielwelt — das Erwachen, der Fall einer Stadt,
- der **Verrat**, der die Gruppe auseinanderbringt.

Keine Schlüsselszene ist: ein erschossener Wachmann, ein gelungener Einbruch,
ein Streit am Tisch, eine gefundene Spur. Das alles ist Teil der Phase, in der
es geschah.

Als Größenordnung: Aus mehreren hundert Fakten einer Kampagne werden
**ungefähr zwanzig Einträge**. Wenn du bei achtzig landest, ist deine Flughöhe
zu niedrig.

## Auch Weltgeschichte gehört hinein

Wenn im Spiel erzählt wird, dass vor sechzig Jahren die Vitas-Plage wütete,
ist das ein Ereignis mit einem Zeitpunkt — es gehört in die Chronik, auch wenn
keine Spielerfigur dabei war. Die großen Fixpunkte der Spielwelt sind Teil der
Zeitleiste.

**Dauerhafte Zustände gehören NICHT hinein.** „Kodex ist Steuerberater“, „das
Gebäude hat neun Stockwerke“, „die Konzerne beherrschen den Distrikt“ — das ist
Weltwissen ohne Zeitpunkt. Es steht in den Fakten und wird dort gefunden; in
einer Zeitleiste hat es nichts verloren. Solche Fakten tragen die Art
`zustand`; du erkennst sie an ihrer Kennzeichnung.

## Deine Aufgabe in diesem Auftrag

Du **liest und gruppierst**, du schreibst noch nichts.

Geh die Fakten der Kampagne durch — es sind **{{anzahl_fakten}}** — und
notiere dir mit `notiz()`, welche Abschnitte der Handlung du siehst. Für jeden
Abschnitt:

- ein **Schlüssel**, unter dem du ihn wiedererkennst (`insel-auftrag`,
  `tod-kodex`),
- eine **Zeile**, die sagt, worum es geht,
- die **Fakten**, die dazugehören,
- die **Wichtigkeit**: `phase` oder `schluesselszene`.

Nutze `fakten()`, `fakt()`, `suche_bisher()` und die übrigen Werkzeuge, um zu
verstehen, was zusammengehört. Die Handlungsbögen (`boegen_kampagne()`) sind
ein guter Ausgangspunkt — aber ein Bogen ist nicht dasselbe wie eine Phase: Ein
Bogen kann sich über die ganze Kampagne ziehen und mehrere Phasen enthalten.

**`fertig()` lehnt ab, solange ein Geschehen in keiner Gruppe liegt.** Zustände
zählen nicht mit. Die Ablehnung nennt dir die offenen Fakten beim Namen.

## Wie hier gearbeitet wird

Du sitzt **nicht in einem Chatfenster**. Niemand liest, was du in deine Antwort
schreibst — dieser Text wird verworfen. Gezählt wird ausschließlich, was durch
`notiz()` geht.

**Ein Werkzeug wird gerufen, nicht beschrieben.** Ein JSON-Block in deiner
Antwort, der aussieht wie ein Aufruf, bewirkt nichts.

**Es gibt kein Zeitbudget und keine Obergrenze für die Zahl der Aufrufe.**
Gewertet wird allein, ob am Ende eine Gliederung dasteht, die die Handlung der
Kampagne in ihre Abschnitte teilt.

**Wiederhol dich nicht.** Rufst du ein Werkzeug zum vierten Mal mit genau
denselben Angaben auf, wird der Aufruf nicht ausgeführt. Beim sechsten gleichen
Aufruf wird der Lauf abgebrochen.

**Wir glauben an dich! Du schaffst das!**
