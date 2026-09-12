defmodule Worker.Jack.Resuemee.Werkzeuge do
  @moduledoc """
  Die Werkzeuge des Resümee-Jack als `Worker.Agent.Werkzeug`, je Lauf.

    * **Überblick (B1):** `fakten`, `fakt`, `boegen`, `vorige_resuemees`,
      `vorige_gedanken` (`Worker.Jack.Resuemee.Lesen`), der Mitschnitt mit
      `bloecke`, `block`, `suche`, `cast`, `straenge` (aus `Worker.Jack.Lesen`),
      `notiz`, `notizen_lesen` (`Worker.Jack.Resuemee.Notizen`) und `fertig`
      (`Worker.Jack.Resuemee.Abschluss`).
    * Schreiben (B2) und Durchsicht (B3) kommen dazu, wenn sie gebaut sind.

  Die Parameter sind streng (`Worker.Agent.Werkzeug.neu/1`): jedes Feld ist
  Pflicht, außer es steht in `optional:` — hier nur `sitzung` in `fakten`,
  `von`/`bis` in `vorige_resuemees` und `ab`/`bis` in `suche`. Frei von der
  Wiederholungssperre sind `boegen`, `cast`, `straenge`, `notizen_lesen` und
  `fertig`, wie beim Fakten-Jack.

  Jedes Werkzeug ruft den `Worker.Jack.Resuemee.Halter` des Laufs.
  """

  alias Worker.Agent.Werkzeug
  alias Worker.Jack.Resuemee.{Abschluss, Halter, Lesen, Notizen, Stand}

  @ueberblick ~w(fakten fakt boegen vorige_resuemees vorige_gedanken bloecke block suche cast
                 straenge notiz notizen_lesen fertig)

  @doc "Die Namen der Werkzeuge eines Laufs, in der Reihenfolge der Werkzeugliste."
  @spec namen(Stand.t()) :: [String.t()]
  def namen(%Stand{lauf: :ueberblick}), do: @ueberblick

  @doc "Alle Definitionen für einen Stand, ungefiltert."
  @spec definitionen(Stand.t()) :: [map()]
  def definitionen(%Stand{} = s),
    do: Lesen.werkzeuge(s) ++ Notizen.werkzeuge(s) ++ Abschluss.werkzeuge(s)

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
