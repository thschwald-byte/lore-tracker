defmodule Worker.Jack.Chronik.Werkzeuge do
  @moduledoc """
  Die Werkzeuge des Chronik-Jack als `Worker.Agent.Werkzeug`, je Lauf
  (J7, #1211).

    * **Überblick** (nur im vollen Aufbau): die Lesebasis, `chronik`,
      `notiz`/`notizen_lesen` und `fertig`. Geschrieben wird hier nichts —
      der Lauf gruppiert. `notiz` ist das **eigene** der Chronik
      (`Worker.Jack.Chronik.Notizen`, Abschnitte PHASEN, SCHLUESSELSZENEN,
      OFFEN); bis #1211 stand hier das des Resümee-Jack, und der Überblick
      konnte deshalb nie abschließen.
    * **Schreiben** (voller Aufbau) und **Verfeinerung** (Normalbetrieb):
      dieselben Werkzeuge. Der Unterschied liegt im Auftrag und im Bestand,
      nicht im Werkzeugkasten — die Verfeinerung findet Einträge vor und
      schreibt sie fort, der Aufbau legt sie an. `notiz` gibt es hier nur für
      NICHT_ZEITLEISTE (und OFFEN); die Gruppen stammen aus dem Überblick,
      und die Verfeinerung hat keinen.
    * **Durchsicht**: die Lesebasis, `chronik`, `durchsicht`,
      `eintrag_bestaetigen`, `eintrag_ersetzen` und `fertig`. Kein
      `chronik_eintrag` — angelegt wird hier nichts mehr.

  **Die Lesebasis ist die des Resümee-Jack, ohne die Sitzungsgrenze.** Alle
  anderen Jacks sehen nur ihre Sitzung und frühere; der Chronik-Jack sieht
  die ganze Kampagne (`Worker.Jack.Chronik.Eingabe`). Die Werkzeuge sind
  dieselben, die Menge dahinter ist größer.

  Streng wie bei den anderen (`Worker.Agent.Werkzeug.neu/1`): jedes Feld ist
  Pflicht, außer es steht in `optional:`.
  """

  alias Worker.Jack.Chronik.{Abschluss, Durchsicht, Entwurf, Lesen, Notizen}
  alias Worker.Jack.Resuemee.{Halter, Stand}
  alias Worker.Jack.Resuemee.Lesen, as: Basis
  alias Worker.Jack.Resuemee.Werkzeuge, as: Gemeinsam

  @eigen_ueberblick ~w(chronik offen zahlen notiz fakt_umhaengen notizen_lesen fertig)
  # `notiz` auch im Schreiben und in der Verfeinerung: dort nur, um Geschehen
  # begründet aus der Zeitleiste herauszuhalten (NICHT_ZEITLEISTE) — sonst
  # zwänge `fertig()` es in eine Phase. Die Verfeinerung hat keinen Überblick,
  # aus dem so ein Ausschluss sonst käme.
  @eigen_schreiben ~w(chronik offen zahlen notiz notizen_lesen chronik_eintrag
                      eintrag_ergaenzen fakt_umhaengen eintrag_einordnen eintrag_streichen
                      fertig)
  @eigen_durchsicht ~w(chronik offen zahlen notizen_lesen durchsicht
                       eintrag_bestaetigen eintrag_ersetzen eintrag_ergaenzen fakt_umhaengen
                       eintrag_einordnen fertig)

  @doc "Die Namen der Werkzeuge eines Laufs, in der Reihenfolge der Werkzeugliste."
  @spec namen(Stand.t()) :: [String.t()]
  def namen(%Stand{lauf: :ueberblick}), do: Gemeinsam.lesend() ++ @eigen_ueberblick
  def namen(%Stand{lauf: :durchsicht}), do: Gemeinsam.lesend() ++ @eigen_durchsicht
  def namen(%Stand{}), do: Gemeinsam.lesend() ++ @eigen_schreiben

  @doc "Alle Definitionen für einen Stand, ungefiltert."
  @spec definitionen(Stand.t()) :: [map()]
  def definitionen(%Stand{lauf: :ueberblick} = s),
    do: Basis.werkzeuge(s) ++ Lesen.werkzeuge(s) ++ Notizen.werkzeuge(s) ++ Abschluss.werkzeuge(s)

  def definitionen(%Stand{lauf: :durchsicht} = s),
    do:
      Basis.werkzeuge(s) ++
        Lesen.werkzeuge(s) ++
        Notizen.werkzeuge(s) ++
        Durchsicht.werkzeuge(s) ++ Entwurf.werkzeuge(s) ++ Abschluss.werkzeuge(s)

  def definitionen(%Stand{} = s),
    do:
      Basis.werkzeuge(s) ++
        Lesen.werkzeuge(s) ++
        Notizen.werkzeuge(s) ++ Entwurf.werkzeuge(s) ++ Abschluss.werkzeuge(s)

  @doc "Die Werkzeuge für den Stand im Halter; jedes ruft den Halter."
  @spec fuer(pid()) :: [Worker.Agent.Werkzeug.t()]
  def fuer(halter) do
    s = Halter.stand(halter)
    Gemeinsam.aus(definitionen(s), namen(s), halter)
  end
end
