defmodule Worker.Jack.Epos.Werkzeuge do
  @moduledoc """
  Die Werkzeuge des Epos-Jack als `Worker.Agent.Werkzeug`, je Lauf (E1,
  #1210: der Überblick).

    * **Überblick:** die ganze Lesebasis des Resümee-Jack
      (`Worker.Jack.Resuemee.Werkzeuge.lesend/0` — `fakten`, `fakt`,
      `boegen`, `boegen_kampagne`, `vorige_resuemees`, `vorige_kapitel`,
      `vorige_gedanken`, `bloecke`, `block`, `suche_sitzung`, `suche_bisher`,
      `cast`, `straenge`; beim Epos-Jack durchsucht `suche_sitzung` auch das
      Resümee dieser Sitzung), dazu `resuemee` (`Worker.Jack.Epos.Weg`),
      `notiz` und `notizen_lesen` (`Worker.Jack.Epos.Notizen`) und `fertig`
      (`Worker.Jack.Epos.Abschluss`).

  Streng wie beim Resümee-Jack (`Worker.Agent.Werkzeug.neu/1`): jedes Feld
  ist Pflicht, außer es steht in `optional:` — hier nur die optionalen Felder
  der Lesebasis (`sitzung` in `fakten`, `bloecke`, `block`; `von`/`bis` in
  `vorige_resuemees` und `vorige_kapitel`; `weiter` in den Suchen). In
  `notiz` ist jedes Feld eines Eintrags Pflicht (`abschnitt`, `schluessel`,
  `zeile` — `null` streicht —, `fakten`, `boegen`), in `fertig` `fakten`,
  `szenen` und `offen_geblieben`; `resuemee` und `notizen_lesen` haben keine
  Felder. Frei von der Wiederholungssperre sind `resuemee`, `notizen_lesen`
  und `fertig` neben den freien Lesewerkzeugen.

  Gebaut über `Worker.Jack.Resuemee.Werkzeuge.aus/3`; jedes Werkzeug ruft den
  `Worker.Jack.Resuemee.Halter` des Laufs.
  """

  alias Worker.Agent.Werkzeug
  alias Worker.Jack.Epos.{Abschluss, Notizen, Weg}
  alias Worker.Jack.Resuemee.{Halter, Lesen, Stand}
  alias Worker.Jack.Resuemee.Werkzeuge, as: Gemeinsam

  @eigen_ueberblick ~w(resuemee notiz notizen_lesen fertig)

  @doc "Die Namen der Werkzeuge eines Laufs, in der Reihenfolge der Werkzeugliste."
  @spec namen(Stand.t()) :: [String.t()]
  def namen(%Stand{lauf: :ueberblick}), do: Gemeinsam.lesend() ++ @eigen_ueberblick

  @doc "Alle Definitionen für einen Stand, ungefiltert."
  @spec definitionen(Stand.t()) :: [map()]
  def definitionen(%Stand{} = s),
    do: Lesen.werkzeuge(s) ++ Weg.werkzeuge(s) ++ Notizen.werkzeuge(s) ++ Abschluss.werkzeuge(s)

  @doc "Die Werkzeuge für den Stand im Halter; jedes ruft den Halter."
  @spec fuer(pid()) :: [Werkzeug.t()]
  def fuer(halter) do
    s = Halter.stand(halter)
    Gemeinsam.aus(definitionen(s), namen(s), halter)
  end
end
