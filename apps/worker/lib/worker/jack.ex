defmodule Worker.Jack do
  @moduledoc """
  Jack: die Werkzeuge des Werkzeug-Agenten aus dem Spike #1174, nach Elixir
  portiert (Epic #1195, J1 = #1196). Sie laufen auf der generischen Laufzeit
  `Worker.Agent` (#1197).

  Der Teil, der zählt, ist die Prüfung beim Eintragen: der Beleg muss
  wörtlich in den genannten Blöcken stehen, und eine Aussage, die mit dem
  Bestand kollidiert, wird vorgelegt statt still eingetragen. Das ist
  mechanisch, kein Modellurteil.

    * `Worker.Jack.Stand` — der Stand eines Auftrags: Blöcke, Cast,
      Gedächtnis, Bestand, GUIDs, Journal. Reine Daten.
    * `Worker.Jack.Beleg` — die Belegprüfung.
    * `Worker.Jack.Tor` — das Verifikationstor: ähnliche Aussagen finden,
      GUIDs ausgeben und einlösen.
    * `Worker.Jack.Aussage` — `aussage` (einreichen) und
      `aussage_entscheiden` (nach einer Kollision), pur.
    * `Worker.Jack.Antwort` — die einheitliche Antwortform und ihre Texte.
    * `Worker.Jack.Felder` — Schemas und erlaubte Werte.

  **Kein Schreibzugriff auf Mnesia.** Aussagen sammeln sich im Stand; das
  `SessionFactsExtracted` baut später J4.

  Vorlage ist `werkzeuge.ts` im Stand für Lauf 6 der Reihe C (sha256
  `f79a359a…ff421f1`). Wo der Port bewusst abweicht, steht es am Modul;
  zusammengefasst in #1196.
  """
end
