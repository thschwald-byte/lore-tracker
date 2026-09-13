# Jacks Aufträge im Betrieb (J4, #1207)

`phase1.md` (Gedächtnis anlegen), `phase2.md` (Aussagen sammeln) und
`folgelauf.md` (Iteration: verifizieren) sind die Aufträge, die Jack in der
Pipeline bekommt (`Worker.Jack.Pipeline.auftraege/2`). Diese Datei selbst wird
nicht geladen.

**Herkunft:** die gemessene Fassung aus dem Spike #1174 (Werkzeugstand
`7ecc9ea8`), mit der die Messläufe J3 und der Fable-Referenzlauf liefen. Zwei
Änderungen, sonst wortgleich:

- **Blockzahlen sind Platzhalter:** `{{letzter_block}}` und
  `{{anzahl_bloecke}}` setzt `Worker.Jack.Pipeline.fuellen/2` je Sitzung ein.
- **Die Beispiele stammen aus der Demo** (`Worker.Jack.Demo`: die Werkstatt am
  Hafen, der verschwundene Uhrmacher, Mira, Brann, Tess). Die gemessene
  Fassung enthielt Beispiele aus einer echten Sitzung; die bleibt lokal und
  kommt nicht ins Repo (Tom, 11.09.2026). `auftragsvorlagen_test.exs` hält
  fest, dass keine Begriffe von dort hier auftauchen.

Wer die Texte ändert, ändert, was gemessen wurde: eine neue Fassung braucht
einen neuen Messlauf gegen die Referenzlinie (#1195).

## Resümee (J5, #1209)

`resuemee_ueberblick.md` ist der Auftrag für den ersten Lauf des Resümee-Jack
(`Worker.Jack.Resuemee.auftrag/2`): alle Fakten der Sitzung lesen, die FORM aus
der Überschrift der Resümee-Spalte ableiten, danach die GLIEDERUNG anlegen.
Platzhalter: `{{sitzung}}`, `{{ueberschrift}}`, `{{anzahl_fakten}}`,
`{{letzter_block}}`, `{{fruehere}}` (`Worker.Jack.Resuemee.fuellen/2`). Neu
geschrieben, nicht gemessen; die Beispiele stammen ebenfalls aus der Demo-Welt.

`resuemee_schreiben.md` ist der Auftrag für den zweiten Lauf, das Schreiben
(`Worker.Jack.Resuemee.auftrag_schreiben/3`, B2). Jack beginnt ihn ohne
Erinnerung an den Überblick; der Auftrag bringt deshalb in dieser Reihenfolge
zuerst den **Ton** (`{{ton}}`: Grundton und Resümee-Ton aus „Stil setzen“, sonst
ein neutraler Satz), dann seine **Notizen** (`{{notizen}}`: die Ablage des
Überblicks, FORM zuerst), dann die Aufgabe und die Werkzeuge. Übrige
Platzhalter wie oben (`Worker.Jack.Resuemee.fuellen_schreiben/3`, eingesetzt in
einem Durchgang, damit Ton und Notizen nicht selbst als Vorlage gelesen
werden). Das Beispiel zeigt je einen Satz mit Fakt, einen Übergang und einen
Rückblick, wieder aus der Demo-Welt. Ebenfalls neu und nicht gemessen.

`resuemee_durchsicht.md` ist der Auftrag für den dritten Lauf, die Durchsicht
(`Worker.Jack.Resuemee.auftrag_durchsicht/4`, B3). Wieder ein frischer Lauf:
der Auftrag bringt den **Ton**, die **Notizen** und den **Entwurf** aus dem
Schreiben (`{{entwurf}}`, in der Form von `entwurf()`), dazu
`{{anzahl_absaetze}}` und `{{max_durchgaenge}}`
(`Worker.Jack.Resuemee.fuellen_durchsicht/4`). Die Durchsicht ist gnädig: sie
benennt die groben Schnitzer, die zu beheben sind, und sagt ausdrücklich, dass
Stil und Wortwahl bleiben. Das Beispiel aus der Demo-Welt zeigt einen holprigen,
aber stimmigen Satz, der bleibt, und einen Satz mit falscher Figur, der ersetzt
wird — samt dem Hinweis, dass eine falsche Figur aus dem Cast in den Hinweisen
nicht auftaucht. Neu und nicht gemessen.

**Länge und Weg (#1209, nach dem ersten echten Lauf: 1272 Wörter, 107 von 114
Fakten erzählt; danach ein Lauf mit 73 Wörtern, in dem der Ablauf der Sitzung
nur bruchstückhaft erkennbar war).** Alle drei Vorlagen bekommen
`{{max_woerter}}` — das **Ziel** aus „Stil setzen“, Standard 150
(`Shared.ResuemeeLaenge`) — und `{{obergrenze}}`, das Doppelte; der Überblick
dazu `{{max_gliederung}}` (höchstens so viele Stationen,
`max(3, round(2 * max_woerter / 25))`, beim Standard also 12 — gegriffen).
Maintainer: „Der Weg, den die Gruppe genommen hat, muss aus dem Resümee
ersichtlich sein.“ Der Überblick beschreibt die GLIEDERUNG deshalb als **Weg der
Gruppe**, Station für Station vom Anfang bis zum Ende; das Beispiel zeigt sechs
Stationen (Ankunft, Hindernis, in der Werkstatt, Ziel, Konfrontation,
Abschluss). Das Schreiben erzählt diesen Weg — jede Station mit mindestens
einem Satz, ein Satz nennt die Fakten der Ereignisse, die er erzählt —, zielt
auf `{{max_woerter}}` Wörter und geht bis `{{obergrenze}}` nur mit
`laenge_begruendung`. Die Durchsicht nennt die Obergrenze und dass der Weg
vollständig bleibt. Die Pflicht der Handlungsbögen bleibt beim Schreiben
(erzählen oder in `ausgelassen` begründen). Die Werkzeuge prüfen all das hart
(`Worker.Jack.Resuemee.Notizen`, `.Abschluss`, `.Durchsicht`, `.Laenge`,
`.Weg`); die Vorlagen erklären es nur. Ebenfalls nicht gemessen.

**Gemeinsame Lesebasis (E0, #1210 — zuerst für den Resümee-Jack, danach für
den Epos-Jack).** Alle drei Resümee-Vorlagen nennen statt `suche(begriff)`
die zwei Suchen `suche_sitzung(begriff)` (Fakten, Mitschnitt und Bögen dieser
Sitzung) und `suche_bisher(begriff)` (alles bis einschließlich dieser Sitzung:
Fakten, Mitschnitte, Resümees, Epos-Kapitel, Notizen der Jacks, Bögen,
Chronik), beide mit höchstens 20 Treffern je Quelle und Blättern über
`weiter: true`; dazu `bloecke`/`block` mit `sitzung` für den Mitschnitt
früherer Sitzungen, `boegen_kampagne()` und `vorige_kapitel(von?, bis?)`. Die
Texte sind kurz und bejahend; das Beispiel (`suche_bisher(begriff:
"Spieldose")`) stammt aus der Demo-Welt. Die Regeln — Deckel, Blättern, Laden
beim Zugriff — stehen in den Werkzeugen (`Worker.Jack.Resuemee.Suche`,
`.Mitschnitte`, `.Bisher`). Nicht gemessen.
