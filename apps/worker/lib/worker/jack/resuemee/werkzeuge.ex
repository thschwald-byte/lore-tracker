defmodule Worker.Jack.Resuemee.Werkzeuge do
  @moduledoc """
  Die Werkzeuge des Resümee-Jack als `Worker.Agent.Werkzeug`, je Lauf.

    * **Überblick (B1):** `fakten`, `fakt`, `boegen`, `vorige_resuemees`,
      `vorige_gedanken` (`Worker.Jack.Resuemee.Lesen`), der Mitschnitt mit
      `bloecke`, `block`, `suche`, `cast`, `straenge` (aus `Worker.Jack.Lesen`),
      `notiz`, `notizen_lesen` (`Worker.Jack.Resuemee.Notizen`) und `fertig`
      (`Worker.Jack.Resuemee.Abschluss`).
    * **Schreiben (B2):** dieselben Lesewerkzeuge, `notizen_lesen` (nur
      lesend — `notiz` gibt es hier nicht, die Notizen stammen aus dem
      Überblick), `entwurf`, `absatz`, `absatz_ersetzen`, `absatz_streichen`
      (`Worker.Jack.Resuemee.Entwurf`) und `fertig` in der Fassung des
      Schreibens.
    * **Durchsicht (B3):** dieselben Lesewerkzeuge, `notizen_lesen`,
      `entwurf`, dazu `durchsicht`, `absatz_bestaetigen`, `absatz_ersetzen`
      (mit `grund`) und `absatz_streichen` (mit `grund`) aus
      `Worker.Jack.Resuemee.Durchsicht` und `fertig` in der Fassung der
      Durchsicht. Kein `absatz` — angehängt wird hier nichts.

  Die Parameter sind streng (`Worker.Agent.Werkzeug.neu/1`): jedes Feld ist
  Pflicht, außer es steht in `optional:` — hier nur `sitzung` in `fakten`,
  `von`/`bis` in `vorige_resuemees`, `ab`/`bis` in `suche`, und in `absatz`
  und `absatz_ersetzen` der `titel` und je Satz `uebergang`/`rueckblick`.
  Frei von der Wiederholungssperre sind `boegen`, `cast`, `straenge`,
  `notizen_lesen`, `entwurf` und `fertig`, wie beim Fakten-Jack; `durchsicht`
  zählt nur, solange sich nichts geändert hat (`:bis_aenderung`).

  Jedes Werkzeug ruft den `Worker.Jack.Resuemee.Halter` des Laufs.
  """

  alias Worker.Agent.Werkzeug
  alias Worker.Jack.Resuemee.{Abschluss, Durchsicht, Entwurf, Halter, Lesen, Notizen, Stand}

  @lesend ~w(fakten fakt boegen vorige_resuemees vorige_gedanken bloecke block suche cast straenge)
  @ueberblick @lesend ++ ~w(notiz notizen_lesen fertig)
  @schreiben @lesend ++
               ~w(notizen_lesen entwurf absatz absatz_ersetzen absatz_streichen fertig)
  @durchsicht @lesend ++
                ~w(notizen_lesen entwurf durchsicht absatz_bestaetigen absatz_ersetzen
                   absatz_streichen fertig)

  @doc "Die Namen der Werkzeuge eines Laufs, in der Reihenfolge der Werkzeugliste."
  @spec namen(Stand.t()) :: [String.t()]
  def namen(%Stand{lauf: :ueberblick}), do: @ueberblick
  def namen(%Stand{lauf: :schreiben}), do: @schreiben
  def namen(%Stand{lauf: :durchsicht}), do: @durchsicht

  @doc """
  Alle Definitionen für einen Stand, ungefiltert. In der Durchsicht kommen
  `absatz_ersetzen` und `absatz_streichen` aus `Worker.Jack.Resuemee.Durchsicht`
  (mit `grund`), nicht aus dem Schreiben — jeder Name genau einmal.
  """
  @spec definitionen(Stand.t()) :: [map()]
  def definitionen(%Stand{lauf: :durchsicht} = s),
    do:
      Lesen.werkzeuge(s) ++
        Notizen.werkzeuge(s) ++ Durchsicht.werkzeuge(s) ++ Abschluss.werkzeuge(s)

  def definitionen(%Stand{} = s),
    do:
      Lesen.werkzeuge(s) ++
        Notizen.werkzeuge(s) ++ Entwurf.werkzeuge(s) ++ Abschluss.werkzeuge(s)

  @doc "Die Werkzeuge für den Stand im Halter; jedes ruft den Halter."
  @spec fuer(pid()) :: [Werkzeug.t()]
  def fuer(halter) do
    s = Halter.stand(halter)
    defs = Map.new(definitionen(s), &{&1.name, &1})
    for name <- namen(s), do: werkzeug(Map.fetch!(defs, name), halter)
  end

  defp werkzeug(d, halter) do
    Werkzeug.neu(
      name: d.name,
      beschreibung: d.beschreibung,
      parameter: d.parameter,
      optional: Map.get(d, :optional, []),
      wiederholung: Map.get(d, :wiederholung, :zaehlt),
      aendert_bestand: Map.get(d, :aendert_bestand, false),
      ausfuehren: fn argumente -> Halter.aufrufen(halter, d.ausfuehren, argumente) end
    )
  end
end
