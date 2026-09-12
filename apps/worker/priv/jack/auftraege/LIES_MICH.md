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
