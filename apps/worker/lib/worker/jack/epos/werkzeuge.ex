defmodule Worker.Jack.Epos.Werkzeuge do
  @moduledoc """
  Die Werkzeuge des Epos-Jack als `Worker.Agent.Werkzeug`, je Lauf (#1210).

    * **Überblick (E1):** die ganze Lesebasis des Resümee-Jack
      (`Worker.Jack.Resuemee.Werkzeuge.lesend/0` — `fakten`, `fakt`,
      `boegen`, `boegen_kampagne`, `vorige_resuemees`, `vorige_kapitel`,
      `vorige_gedanken`, `bloecke`, `block`, `suche_sitzung`, `suche_bisher`,
      `cast`, `straenge`; beim Epos-Jack durchsucht `suche_sitzung` auch das
      Resümee dieser Sitzung), dazu `resuemee` (`Worker.Jack.Epos.Weg`),
      `notiz` und `notizen_lesen` (`Worker.Jack.Epos.Notizen`) und `fertig`
      (`Worker.Jack.Epos.Abschluss`).
    * **Schreiben (E2):** dieselbe Lesebasis, `resuemee`, `notizen_lesen`
      (nur lesend — `notiz` gibt es hier nicht, die Notizen stammen aus dem
      Überblick), `entwurf`, `absatz`, `absatz_ersetzen`, `absatz_streichen`
      (`Worker.Jack.Epos.Entwurf`) und `fertig` in der Fassung des
      Schreibens.
    * **Durchsicht (E3):** dieselbe Lesebasis, `resuemee`, `notizen_lesen`,
      `entwurf`, dazu `durchsicht`, `absatz_bestaetigen`, `absatz_ersetzen`
      (mit `grund`) und `absatz_streichen` (mit `grund`) aus
      `Worker.Jack.Epos.Durchsicht` und `fertig` in der Fassung der
      Durchsicht. Kein `absatz` — angehängt wird hier nichts.

  Streng wie beim Resümee-Jack (`Worker.Agent.Werkzeug.neu/1`): jedes Feld
  ist Pflicht, außer es steht in `optional:` — hier die optionalen Felder der
  Lesebasis (`sitzung` in `fakten`, `bloecke`, `block`; `von`/`bis` in
  `vorige_resuemees` und `vorige_kapitel`; `weiter` in den Suchen) und in
  Schreiben und Durchsicht `titel` und `szene` in `absatz` und
  `absatz_ersetzen`. In `notiz` ist jedes Feld eines Eintrags Pflicht
  (`abschnitt`, `schluessel`, `zeile` — `null` streicht —, `fakten`,
  `boegen`); `fertig` verlangt im Überblick `fakten`, `szenen` und
  `offen_geblieben`, im Schreiben `absaetze` und `offen_geblieben`, in der
  Durchsicht `bestaetigt`, `ersetzt` und `offen_geblieben`; `absatz`
  verlangt `text`, `absatz_ersetzen` dazu `nummer` (in der Durchsicht auch
  `grund`); `durchsicht` und `absatz_bestaetigen` verlangen `nummer`,
  `absatz_streichen` `nummer` (in der Durchsicht auch `grund`); `resuemee`,
  `notizen_lesen` und `entwurf` haben keine Felder. Frei von der
  Wiederholungssperre sind `resuemee`, `notizen_lesen`, `entwurf` und
  `fertig` neben den freien Lesewerkzeugen; `durchsicht` zählt nur, solange
  sich nichts geändert hat (`:bis_aenderung`).

  Gebaut über `Worker.Jack.Resuemee.Werkzeuge.aus/3`; jedes Werkzeug ruft den
  `Worker.Jack.Resuemee.Halter` des Laufs.
  """

  alias Worker.Agent.Werkzeug
  alias Worker.Jack.Epos.{Abschluss, Durchsicht, Entwurf, Notizen, Weg}
  alias Worker.Jack.Resuemee.{Halter, Lesen, Stand}
  alias Worker.Jack.Resuemee.Werkzeuge, as: Gemeinsam

  @eigen_ueberblick ~w(resuemee notiz notizen_lesen fertig)
  @eigen_schreiben ~w(resuemee notizen_lesen entwurf absatz absatz_ersetzen absatz_streichen
                      fertig)
  @eigen_durchsicht ~w(resuemee notizen_lesen entwurf durchsicht absatz_bestaetigen
                       absatz_ersetzen absatz_streichen fertig)

  @doc "Die Namen der Werkzeuge eines Laufs, in der Reihenfolge der Werkzeugliste."
  @spec namen(Stand.t()) :: [String.t()]
  def namen(%Stand{lauf: :ueberblick}), do: Gemeinsam.lesend() ++ @eigen_ueberblick
  def namen(%Stand{lauf: :schreiben}), do: Gemeinsam.lesend() ++ @eigen_schreiben
  def namen(%Stand{lauf: :durchsicht}), do: Gemeinsam.lesend() ++ @eigen_durchsicht

  @doc """
  Alle Definitionen für einen Stand, ungefiltert. In der Durchsicht kommen
  `entwurf`, `absatz_ersetzen` und `absatz_streichen` aus
  `Worker.Jack.Epos.Durchsicht` (mit `grund`), nicht aus dem Schreiben — jeder
  Name genau einmal.
  """
  @spec definitionen(Stand.t()) :: [map()]
  def definitionen(%Stand{lauf: :durchsicht} = s),
    do:
      Lesen.werkzeuge(s) ++
        Weg.werkzeuge(s) ++
        Notizen.werkzeuge(s) ++ Durchsicht.werkzeuge(s) ++ Abschluss.werkzeuge(s)

  def definitionen(%Stand{} = s),
    do:
      Lesen.werkzeuge(s) ++
        Weg.werkzeuge(s) ++ Notizen.werkzeuge(s) ++ Entwurf.werkzeuge(s) ++ Abschluss.werkzeuge(s)

  @doc "Die Werkzeuge für den Stand im Halter; jedes ruft den Halter."
  @spec fuer(pid()) :: [Werkzeug.t()]
  def fuer(halter) do
    s = Halter.stand(halter)
    Gemeinsam.aus(definitionen(s), namen(s), halter)
  end
end
