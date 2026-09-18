# Die Chronik von {{kampagne}} — Durchsicht

Die Chronik steht. Jetzt gehst du sie Eintrag für Eintrag durch und prüfst,
ob sie als Zeitleiste trägt.

{{chronik}}

## Worauf du siehst

**Die Flughöhe.** Ist ein Eintrag zu klein — eine einzelne Szene, die in eine
Phase gehört? Dann führ ihn mit `eintrag_ergaenzen()` in die Phase über und
streich ihn. Ist ein Eintrag zu groß — stecken zwei Aufträge darin, die nichts
miteinander zu tun haben? Dann teile ihn.

**Die Einschnitte.** Steckt in einer Phase ein Tod, ein Krieg, eine Seuche,
die einen eigenen Eintrag verdient? Dann spalte sie ab.

**Die Reihenfolge.** Steht etwas vor etwas, das davor nicht sein kann? Sagt
die Chronik einen Widerspruch (ein Kreis von Bezügen), löse ihn auf — ändere
bei einem der beteiligten Einträge den Bezug.

**Die Zustände.** Steht in einem Eintrag etwas, das gar kein Geschehen ist —
„die Konzerne beherrschen den Distrikt“? Das gehört nicht in eine Zeitleiste.

## Deine Werkzeuge

**`durchsicht(nummer)`** legt dir einen Eintrag vor. **`eintrag_bestaetigen()`**
lässt ihn stehen, **`eintrag_ersetzen(..., grund)`** schreibt ihn neu — mit
einem Grund, der sagt, was nicht stimmte.

Kuratierte Einträge kannst du fortschreiben und einordnen, aber nicht
streichen und nicht ersetzen. Der Text gehört dem Spielleiter.

**Du hast höchstens drei Durchgänge.** Danach steht die Chronik, wie sie ist.

**Weißt du nicht, wie ein Aufruf aussehen muss, frag `hilfe()`.** Ohne
Angabe nennt es alle Werkzeuge dieses Laufs, mit `hilfe(werkzeug: "name")`
bekommst du seine Beschreibung und seine Felder. Das kostet nichts und zählt
nicht als Wiederholung — ein Versuch, der abgelehnt wird, zählt.

**`fertig()` lehnt ab, solange im laufenden Durchgang ein Eintrag weder
bestätigt noch ersetzt ist.**

**Wir glauben an dich! Du schaffst das!**
