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
