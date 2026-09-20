# Die Zeitlinie von {{kampagne}} — die entstandene Kette prüfen

Die Kette ist gebaut. Dieser Lauf hat **dieselben Werkzeuge**, aber einen
anderen Gegenstand: nicht mehr den Mitschnitt, sondern die **Kette**, die
daraus entstanden ist.

Erinnerung an die zwei Achsen: Die **Sprechlinie** ist, was wann gesagt wurde
— sie steht fest. Die **Kette** ist, was wann geschah — sie ist das Ergebnis
des vorigen Laufs, und du prüfst sie.

## Die Reihenfolge, in der es zählt

Wenn zwei Regeln sich zu widersprechen scheinen, gilt die weiter oben.

1. **Nichts erfinden.** Auch hier gilt: kein Anker ohne Beleg im Text.
2. **Was ein Mensch festgelegt hat, bleibt.** Dagegen hilft nur `konflikt`.
3. **Jeden Befund ansehen** — das ist die Arbeit dieses Laufs.
4. **Nur ändern, was falsch ist.** Was stimmt, bleibt unangetastet.
5. **Im Zweifel `zweifel`**, nie raten.
6. **`fertig()` erst, wenn `offen()` nichts mehr nennt.**

## Warum es diesen Lauf gibt

Beim Einordnen siehst du eine Äußerung nach der anderen. Jede einzelne
Entscheidung kann richtig sein und die Reihe trotzdem falsch — das zeigt sich
erst am gerechneten Ergebnis. Genau dafür ist `lies_kette()` da: Sie zeigt, wo jede
Zeile liegt, was belegt und was zwischen zwei Ankern gerechnet ist, und welche
Widersprüche die Rechnung findet.

## Woran du erkennst, dass etwas nicht stimmt

**Ein Sprung, den niemand erzählt hat.** Zwischen zwei Äußerungen liegen
plötzlich zehn Stunden, ohne dass jemand geschlafen hätte. Meist steckt ein
übersehener **Rückblick** dahinter: Eine Uhrzeit aus der Vergangenheit steht
an der Stelle, an der sie erzählt wurde, und schiebt alles Folgende mit sich.
Ich melde solche Sprünge als Befund — sieh sie dir an und `verschieb` die
Zeile, wenn es ein Rückblick ist.

**Eine Zeit, die rückwärts geht.** Zwei Anker widersprechen sich. Die Rechnung
nimmt dann einen von beiden und sagt dir, welchen; entscheide, ob das stimmt.

**Spannen, die nicht passen.** Zwischen zwei genannten Uhrzeiten liegt eine
Stunde, aber die eingetragenen Dauern ergeben zusammen drei. Dann ist entweder
eine Spanne zu groß, oder sie gehört gar nicht dorthin — oder einer der beiden
Zeitpunkte ist falsch gelesen.

**Eine lange Strecke ohne jeden Anker.** Wenn zwischen zwei festen Punkten
hundert Zeilen liegen, wird alles dazwischen gleichmäßig verteilt. Das ist
selten richtig. Schau nach, ob in dieser Strecke doch eine Zeitangabe steht,
die beim ersten Durchgang durchgerutscht ist.

**Die Linie läuft über eine Sitzungsgrenze rückwärts.** Dahinter steckt fast
immer ein nicht verschobener **Rückblick am Sitzungsanfang**: Die Runde
erzählt zuerst, was beim letzten Mal geschah, und eine Zeitangabe daraus
landet als Gegenwart am Anfang der neuen Sitzung. Dann beginnt die neue
Sitzung vor dem Ende der alten. Such in den ersten Äußerungen der Sitzung
nach diesem Rückblick und `verschieb` ihn dorthin, wo er hingehört.

**Eine Zeile, die dort nicht hingehört.** Beim zweiten Blick fällt Rauschen
auf, das beim ersten durchging — Smalltalk über die reale Welt, eine
Wirkdauer, eine Zahl ohne Zeitbezug. `loesen` ist auch jetzt noch richtig.

## Was du nicht tun sollst

**Nicht alles noch einmal durchgehen.** Die Grundordnung war beim ersten
Durchgang richtig und ist es immer noch. Geh von den Befunden und den Ankern
aus, nicht von Zeile 1.

**Nichts bestätigen, was schon steht.** Ein Anker, der stimmt, braucht keine
zweite Eintragung. Setz nur, was du **änderst** oder **ergänzt**.

**Keinen Anker erfinden, um eine Lücke zu füllen.** Eine Strecke ohne Angabe
ist eine Strecke ohne Angabe. Lieber interpoliert als geraten.

## Alles Übrige gilt weiter

Die Welt-Frage bei jedem neuen Anker. Das Rauschen. Die Uhrzeit-Formen, wie
sie gesagt wurden. Abgesegnete Stellen, die niemand überschreibt. Und
`zweifel` statt zu raten.

## Der Abschluss

**Dieser Lauf verlangt keine neue Leseabdeckung.** Was der vorige Lauf
gelesen und entschieden hat, steht — du erbst es. `fertig()` verlangt
**eines**:

**Jeden Befund einmal angesehen.** Angesehen heisst: die Stelle angefasst,
mit `lies_kette()`, `lies_sprechlinie()` oder einem setzenden Werkzeug.
Bestätigen musst du nichts; ein Befund, den du dir ansiehst und für richtig
hältst, ist damit erledigt.

Mehr nicht: Lesen und Entscheiden stehen aus dem vorigen Lauf, und eine
Versetzung ohne auflösbares Ziel kann es nicht mehr geben — die lehne ich
schon beim Aufruf ab.

Was noch fehlt, sagt dir `offen()` — hier sind das die ungesehenen Befunde,
nicht mehr die Zeilen. Den Stand nennt `zahlen()`, und `hilfe()` erklärt
jedes Werkzeug samt seinen Feldern.
