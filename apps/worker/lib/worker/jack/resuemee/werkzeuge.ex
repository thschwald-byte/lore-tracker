defmodule Worker.Jack.Resuemee.Werkzeuge do
  @moduledoc """
  Die Werkzeuge des Resümee-Jack als `Worker.Agent.Werkzeug`, je Lauf.

    * **Überblick (B1):** `fakten`, `fakt`, `boegen`, `vorige_resuemees`,
      `vorige_gedanken` (`Worker.Jack.Resuemee.Lesen`), die gemeinsame
      Lesebasis (E0, #1210) mit `boegen_kampagne`, `vorige_kapitel`
      (`Worker.Jack.Resuemee.Bisher`), `suche_sitzung`, `suche_bisher`
      (`Worker.Jack.Resuemee.Suche`), der Mitschnitt mit `bloecke`, `block`
      (auch früherer Sitzungen, `Worker.Jack.Resuemee.Mitschnitte`), `cast`,
      `straenge` (aus `Worker.Jack.Lesen`), `notiz`, `notizen_lesen`
      (`Worker.Jack.Resuemee.Notizen`) und `fertig`
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
  `bloecke` und `block`, `von`/`bis` in `vorige_resuemees` und
  `vorige_kapitel`, `weiter` in `suche_sitzung` und `suche_bisher`, und in
  `absatz` und `absatz_ersetzen` der `titel` und je Satz
  `uebergang`/`rueckblick`. Frei von der Wiederholungssperre sind `boegen`,
  `boegen_kampagne`, `cast`, `straenge`, `notizen_lesen`, `entwurf` und
  `fertig`, wie beim Fakten-Jack; `durchsicht` zählt nur, solange sich nichts
  geändert hat (`:bis_aenderung`). Die zwei Suchen zählen mit ihrer Position
  als `wiederholung_merkmal`: Blättern mit `weiter: true` ist erst dann ein
  gleicher Aufruf, wenn es nichts Neues mehr bringt
  (`Worker.Jack.Resuemee.Suche`). Die Definition trägt das Merkmal als
  `fn stand, argumente -> term end`; `fuer/1` liest es über
  `Worker.Jack.Resuemee.Halter.lesen/2`, ohne den Stand zu kopieren.

  Jedes Werkzeug ruft den `Worker.Jack.Resuemee.Halter` des Laufs.
  """

  alias Worker.Agent.Werkzeug
  alias Worker.Jack.Resuemee.{Abschluss, Durchsicht, Entwurf, Halter, Lesen, Notizen, Stand}

  @lesend ~w(fakten fakt boegen boegen_kampagne vorige_resuemees vorige_kapitel vorige_gedanken
             bloecke block suche_sitzung suche_bisher cast straenge)
  @ueberblick @lesend ++ ~w(notiz notizen_lesen fertig)
  @schreiben @lesend ++
               ~w(notizen_lesen entwurf absatz absatz_ersetzen absatz_streichen fertig)
  @durchsicht @lesend ++
                ~w(notizen_lesen entwurf durchsicht absatz_bestaetigen absatz_ersetzen
                   absatz_streichen fertig)

  @doc "Die Namen der lesenden Werkzeuge — dieselben beim Epos-Jack (#1210)."
  @spec lesend() :: [String.t()]
  def lesend, do: @lesend

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
    aus(definitionen(s), namen(s), halter)
  end

  @doc """
  Die Werkzeuge `namen` aus `definitionen`, in dieser Reihenfolge, jedes über
  den Halter — auch für einen Jack mit eigenen Definitionen (Epos-Jack,
  #1210, `Worker.Jack.Epos.Werkzeuge`).
  """
  @spec aus([map()], [String.t()], pid()) :: [Werkzeug.t()]
  def aus(definitionen, namen, halter) do
    defs = Map.new(definitionen, &{&1.name, &1})
    for name <- namen, do: werkzeug(Map.fetch!(defs, name), halter)
  end

  defp werkzeug(d, halter) do
    Werkzeug.neu(
      name: d.name,
      beschreibung: d.beschreibung,
      parameter: d.parameter,
      optional: Map.get(d, :optional, []),
      wiederholung: Map.get(d, :wiederholung, :zaehlt),
      aendert_bestand: Map.get(d, :aendert_bestand, false),
      wiederholung_merkmal: merkmal(d, halter),
      ausfuehren: fn argumente -> Halter.aufrufen(halter, d.ausfuehren, argumente) end
    )
  end

  # Das Merkmal liest den Stand im Halter (`fn stand, argumente -> term end`
  # in der Definition); zurück kommt nur das Merkmal, nicht der Stand.
  defp merkmal(%{wiederholung_merkmal: f}, halter) when is_function(f, 2),
    do: fn argumente -> Halter.lesen(halter, &f.(&1, argumente)) end

  defp merkmal(_d, _halter), do: nil
end
