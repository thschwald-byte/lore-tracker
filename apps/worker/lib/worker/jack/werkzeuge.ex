defmodule Worker.Jack.Werkzeuge do
  @moduledoc """
  Jacks Werkzeuge als `Worker.Agent.Werkzeug`: je Phase die Liste des Spikes
  (`WERKZEUGE_LESEN`, `WERKZEUGE_SAMMELN`), in dessen Reihenfolge, mit den
  Markierungen für die Wiederholungssperre aus #1196 (Tabelle vom 10.09.).

    * **Phase 1, Lesen:** `bloecke` (im Beppo-Modus `weiter`), `block`,
      `suche`, `cast`, `straenge`, `notiz`, `notizen_lesen`, `fertig`.
    * **Phase 2, Sammeln:** dazu `aussage` und `aussage_entscheiden`. Ein
      Lesewerkzeug für den Bestand gibt es hier nicht (Toms Entscheidung,
      #1196): eine Kollision mit dem Bestand ist die Verifikation. Die
      Verifizierungsdurchgänge danach laufen mit denselben Werkzeugen.

  Eine Phase 3 mit den Werkzeugen zum Ordnen des Bestands gibt es nicht mehr
  (Toms Entscheidung, 10.09.).

  Frei von der Wiederholungssperre sind `weiter`, `notizen_lesen`, `cast`,
  `straenge` und `fertig`; die schreibenden Werkzeuge ändern bei Erfolg den
  Bestand.

  Jedes Werkzeug ruft den `Worker.Jack.Halter` des Laufs mit seinem Namen
  (für `Worker.Jack.Probieren`); die Antwort geht über
  `Worker.Jack.Antwort.fuer_modell/1`, also mit `outcome` als erstem
  Schlüssel.
  """

  alias Worker.Agent.Werkzeug

  alias Worker.Jack.{
    Abschluss,
    Antwort,
    Aussage,
    Felder,
    Gedaechtnis,
    Halter,
    Lesen,
    Stand
  }

  @aussage "Traegt eine fertige Aussage ein. Antwortet immer gleich aufgebaut: outcome, " <>
             "aussagen, fehler, hinweis, bestand, themen. Bei Erfolg (outcome written) nennt " <>
             "sie die bisher verwendeten Themen — nutze sie, damit du nicht spaeter andere " <>
             "Bezeichnungen fuer dasselbe waehlst. Stimmt ein Feld nicht (outcome fix), " <>
             "steht in fehler, welches und warum; dann ist nichts eingetragen — korrigiere " <>
             "und rufe erneut auf. Der `beleg` muss woertlich in den Bloecken aus " <>
             "source_refs stehen, sonst ist das ein solcher Fehler. Zeigt dein claim mit " <>
             "einem Wort nach hinten (\"vorhin\", \"wieder\", \"wie besprochen\") und nennst " <>
             "du nur einen Block, weist die Antwort darauf hin — dann fehlt vermutlich " <>
             "die Nummer der frueheren Stelle."

  # Kein Spike-Text: dort steckte dieser Weg als sechs optionale Felder in
  # `aussage` (Toms Entscheidung, das Werkzeug zu teilen).
  @entscheiden "Entscheidet ueber eine Vorlage aus dem Bestand — nur nach einer Antwort " <>
                 "von aussage() mit outcome verify. Dieselben Felder wie dort, dazu " <>
                 "verifikations_guid aus jener Antwort, entscheidung (\"neu\" oder " <>
                 "\"ersetzt\"), begruendung und weitere_guids. Antwortet gleich aufgebaut " <>
                 "wie aussage()."

  @doc "Die Namen der Werkzeuge einer Phase, in der Reihenfolge des Spikes."
  @spec namen(Stand.t()) :: [String.t()]
  def namen(%Stand{phase: 1, beppo: beppo}), do: lesen(beppo)
  def namen(%Stand{phase: 2, beppo: beppo}), do: lesen(beppo) ++ ~w(aussage aussage_entscheiden)

  defp lesen(beppo),
    do: [
      if(beppo, do: "weiter", else: "bloecke")
      | ~w(block suche cast straenge notiz notizen_lesen fertig)
    ]

  @doc "Die Werkzeuge für den Stand im Halter; jedes ruft den Halter."
  @spec fuer(pid()) :: [Werkzeug.t()]
  def fuer(halter) do
    s = Halter.stand(halter)
    defs = Map.new(definitionen(s), &{&1.name, &1})
    for name <- namen(s), do: werkzeug(Map.fetch!(defs, name), halter)
  end

  @doc "Alle Definitionen für einen Stand, ungefiltert."
  @spec definitionen(Stand.t()) :: [map()]
  def definitionen(%Stand{} = s),
    do: Lesen.werkzeuge(s) ++ Gedaechtnis.werkzeuge(s) ++ Abschluss.werkzeuge(s) ++ aussage()

  defp aussage do
    [
      %{
        name: "aussage",
        beschreibung: @aussage,
        parameter: Felder.einreichen_schema(),
        optional: Felder.optional(),
        aendert_bestand: true,
        ausfuehren: &Aussage.einreichen/2,
        formfehler: &Aussage.formfehler(&1, &2, "aussage", &3)
      },
      %{
        name: "aussage_entscheiden",
        beschreibung: @entscheiden,
        parameter: Felder.entscheiden_schema(),
        optional: Felder.optional(),
        aendert_bestand: true,
        ausfuehren: &Aussage.entscheiden/2,
        formfehler: &Aussage.formfehler(&1, &2, "aussage_entscheiden", &3)
      }
    ]
  end

  defp werkzeug(d, halter) do
    Werkzeug.neu(
      name: d.name,
      beschreibung: d.beschreibung,
      parameter: d.parameter,
      optional: Map.get(d, :optional, []),
      wiederholung: Map.get(d, :wiederholung, :zaehlt),
      aendert_bestand: Map.get(d, :aendert_bestand, false),
      ausfuehren: fn argumente ->
        {art, inhalt} = Halter.aufrufen(halter, d.ausfuehren, argumente, d.name)
        {art, Antwort.fuer_modell(inhalt)}
      end,
      bei_formfehler: formfehler(d, halter),
      bei_wiederholung: wiederholung(d, halter)
    )
  end

  # Die Sperre führt aussage/aussage_entscheiden nicht aus: die Antwort ist die
  # einheitliche mit outcome repeat/aborted, wie im Spike. Ohne Werkzeugnamen
  # an den Halter: Probieren sieht gesperrte Aufrufe nicht (im Spike ebenso).
  defp wiederholung(%{name: name}, halter) when name in ["aussage", "aussage_entscheiden"] do
    fn argumente, folge, fehler, hinweis ->
      halter
      |> Halter.aufrufen(
        fn s, a -> {s, Aussage.wiederholung(s, a, folge, fehler, hinweis)} end,
        argumente
      )
      |> Antwort.fuer_modell()
    end
  end

  defp wiederholung(_d, _halter), do: nil

  # Ein Formfehler bei aussage/aussage_entscheiden wird wie im Spike vom
  # Werkzeug beantwortet (Toms Entscheidung zu B2), über denselben Halter.
  defp formfehler(%{formfehler: f} = d, halter) do
    fn argumente, verstoesse ->
      {art, inhalt} =
        Halter.aufrufen(halter, fn s, a -> f.(s, a, verstoesse) end, argumente, d.name)

      {art, Antwort.fuer_modell(inhalt)}
    end
  end

  defp formfehler(_d, _halter), do: nil
end
