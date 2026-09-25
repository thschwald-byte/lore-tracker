defmodule HubWeb.CampaignLive.FragFenster.Warten do
  @moduledoc """
  Issue #850: was das Fenster zeigt, während gerechnet wird.

  Eine Antwort darf dauern, solange sichtbar ist, was passiert (Maintainer,
  25.09.2026) — und „arbeitet…" ist dafür zu wenig: Ein Text, der sich nicht
  ändert, ist von einem hängenden Lauf nicht zu unterscheiden. Die Sprüche
  wechseln deshalb, und ihr Wechsel ist selbst das Lebenszeichen.

  **Die Settings sind bunt gemischt, nicht je Kampagne gewählt.** Der Reiz
  liegt im Sprung zwischen den Welten: „Wälze Folianten …" gefolgt von
  „Checke die Konzernarchive …". Ein Filter auf das Genre der eigenen Runde
  wäre stimmiger und ließe vier Sprüche übrig.

  **Alle sagen dasselbe** — „ich schlage gerade nach" —, nur in verschiedenen
  Welten. Keiner behauptet etwas über das Ergebnis; das wäre eine Zusage, die
  erst die Antwort einlösen kann.

  Gedreht wird **im Browser** (`frag_warten.js`): Ein Server-Diff je Wechsel
  wäre bei zwei Minuten Laufzeit rund fünfzig Diffs für nichts (#1200-Klasse).
  """

  @sprueche [
    # Fantasy / Mittelalter
    "Wälze Folianten …",
    "Entziffere Runen …",
    "Wecke den Archivar der Gilde …",
    "Blättere im Grimoire …",
    "Konsultiere die Ahnentafeln …",
    "Frage den Hofchronisten …",
    "Schlage in der Sagensammlung nach …",
    # Antike / Schriftrollen
    "Rolle den Papyrus aus …",
    "Prüfe die Tontafeln …",
    "Durchsuche die Bibliothek …",
    "Puste den Staub von den Schriftrollen …",
    # Cyberpunk
    "Durchsuche die Matrix …",
    "Frage den Host …",
    "Grase die Nodes ab …",
    "Checke die Konzernarchive …",
    "Zapfe den Datenstrom an …",
    "Warte auf den Decker …",
    # Steampunk
    "Kurbele den Rechenapparat an …",
    "Lege die Lochkarten ein …",
    "Heize die Differenzmaschine …",
    "Ziehe die Messingregister …",
    "Warte auf den Fernschreiber …",
    # Horror / Mythos
    "Blättere im verbotenen Band …",
    "Durchsuche das Institutsarchiv …",
    "Lese die Notizen des Verschollenen …",
    "Prüfe die Feldaufzeichnungen der Expedition …",
    "Zünde eine zweite Kerze an …",
    # Western / Weird West
    "Gehe die Steckbriefe durch …",
    "Frage im Telegrafenamt nach …",
    "Durchwühle das Sheriffbüro …",
    "Blättere im Kirchenbuch …",
    # Science-Fiction
    "Frage den Bordcomputer …",
    "Durchsuche die Logbücher …",
    "Rufe die Sternenkarten ab …",
    "Warte auf die Antwort der Schiffs-KI …",
    "Gleiche mit dem Flottenarchiv ab …",
    # Post-Apokalypse
    "Durchwühle die Trümmer …",
    "Kurble den Feldfunk an …",
    "Entziffere verblasste Schilder …",
    # Piraten / Seefahrt
    "Studiere die Seekarten …",
    "Frage im Hafenkontor nach …",
    "Durchsuche das Logbuch der Prise …",
    # Noir / Krimi
    "Blättere in den Akten …",
    "Befrage die Registratur …",
    "Gehe die Zeugenaussagen durch …",
    "Ziehe die Mikrofilme …",
    # Superhelden / Modern
    "Frage das Hauptquartier …",
    "Öffne die Falldatei …",
    # Neutral
    "Suche die Stelle im Protokoll …",
    "Prüfe die Randnotizen …"
  ]

  @doc "Alle Sprüche, in der Reihenfolge der Quelle. Der Browser mischt."
  @spec sprueche() :: [String.t()]
  def sprueche, do: @sprueche

  @doc "Wie lange ein Spruch steht, in ms. Lang genug zum Lesen, kurz genug als Lebenszeichen."
  @spec wechsel_ms() :: pos_integer()
  def wechsel_ms, do: 2_500
end
