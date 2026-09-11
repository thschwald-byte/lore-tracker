defmodule Worker.Jack.Pipeline do
  @moduledoc """
  Jack in der Pipeline (J4, #1207): was Jack von einer Sitzung zu lesen
  bekommt und wie aus seinem Bestand die Fakten werden, die bisher die
  Extraktion geliefert hat — ein `SessionFactsExtracted` mit `facts` und
  `extraction_saw`, damit alles dahinter (Kuration, Dirty-Weiche,
  Fakt-Overlays, Render) unberührt bleibt.

  **Dieselbe Blockliste wie die Extraktion.** `eingabe/4` und `fakten/2`
  bekommen die Kontextliste, die `Worker.Recording.Pipeline.Stages` an den
  Extraktor gibt: `Smoothing.to_context/3` (wirksamer Text, `unbrauchbar`
  entfernt), danach der OOC-Filter (`kontext/1`). Jacks Blocknummer n ist die
  Position n in genau dieser Liste — nur so zeigt eine Nummer auf die richtige
  Block-ID, und `extraction_saw` beschreibt, was Jack wirklich gesehen hat.
  `Worker.Jack.Abzug` nimmt dagegen den rohen Text aller Blöcke; das taugt für
  Messläufe, nicht für den Betrieb.

  **Übersetzung über den Parser der Pipeline.** `fakten/2` bildet die
  Blocknummern auf Block-IDs ab, lässt verworfene Aussagen weg und schickt den
  Rest durch `Parsing.parse_facts_json/2`. Inhaltsbasierte Fakt-IDs,
  Normalisierung, Zeit-Grounding und Dedup kommen von dort, nicht aus einer
  zweiten Implementierung. Jacks `beleg` und seine internen Felder fallen
  dabei weg — die Feldliste des Parsers ist fest.
  """

  alias Worker.Recording.Pipeline.{Ooc, Parsing, Smoothing}

  @doc "Die Kontextliste, die Jack sieht: wie bei der Extraktion ohne OOC-Blöcke."
  @spec kontext([map()]) :: [map()]
  def kontext(bloecke), do: Ooc.filter(bloecke)

  @doc """
  Jacks Eingabe (`%{bloecke:, cast:, straenge:}`, wie `Worker.Jack.Stand.neu/1`
  sie erwartet) aus der Kontextliste. `sprecher` bildet Discord-IDs auf Namen
  ab (`Prompts.resolve_speaker_names/1`). Ein Block ohne Namen ist ein Fehler:
  Jack bekäme sonst eine Discord-ID als Sprecher.
  """
  @spec eingabe([map()], %{String.t() => String.t()}, [String.t()], [String.t()]) ::
          {:ok, map()} | {:error, term()}
  def eingabe(kontext, sprecher, cast, straenge) do
    case kontext
         |> Enum.map(& &1.discord_id)
         |> Enum.uniq()
         |> Enum.reject(&Map.has_key?(sprecher, &1)) do
      [] ->
        {:ok,
         %{
           bloecke:
             Enum.map(kontext, fn b ->
               %{text: b.text || "", sprecher: Map.fetch!(sprecher, b.discord_id), block_id: b.id}
             end),
           cast: ohne_leere(cast),
           straenge: ohne_leere(straenge)
         }}

      ohne ->
        {:error, {:sprecher_ohne_namen, ohne}}
    end
  end

  @doc """
  Aus Jacks Bestand (die Zeilen von `aussagen.jsonl`, also `voll` der
  eingetragenen Aussagen) die Fakten der Pipeline und die Zeit-Adresse
  `extraction_saw`. `kontext` ist dieselbe Liste wie für `eingabe/4`. Ein
  Bestand ohne gültige Aussage ist `{:error, {:extraction, :empty}}`, wie bei
  der Extraktion.
  """
  @spec fakten([map()], [map()]) ::
          {:ok, [map()], %{String.t() => String.t()}} | {:error, term()}
  def fakten(aussagen, kontext) do
    ids = kontext |> Enum.map(& &1.id) |> List.to_tuple()

    liste =
      for %{"nummer" => n} = a <- aussagen, is_integer(n), a["_verworfen"] != true do
        Map.put(a, "source_refs", block_ids(a["source_refs"], ids))
      end

    case Parsing.parse_facts_json(Jason.encode!(%{"facts" => liste}), kontext) do
      {:ok, [_ | _] = facts} -> {:ok, facts, extraction_saw(kontext)}
      {:ok, []} -> {:error, {:extraction, :empty}}
      {:error, grund} -> {:error, {:extraction, grund}}
    end
  end

  @doc """
  Welchen Text Jack je Block gesehen hat (Block-ID → `Smoothing.text_hash/1`)
  — genau wie die Extraktion (`Stages.extract_facts_raw/3`), damit die
  Dirty-Weiche nach einer Kuration dieselbe Adresse vorfindet.
  """
  @spec extraction_saw([map()]) :: %{String.t() => String.t()}
  def extraction_saw(kontext),
    do: Map.new(kontext, fn b -> {b.id, Smoothing.text_hash(b.text || "")} end)

  # Nummern außerhalb der Liste kann Jack nicht belegt haben — die Belegprüfung
  # kennt nur Blöcke der Eingabe; sie fallen still weg wie ein erfundener Ref
  # bei der Extraktion.
  defp block_ids(refs, ids) when is_list(refs) do
    for n <- refs, is_integer(n), n >= 0, n < tuple_size(ids), uniq: true, do: elem(ids, n)
  end

  defp block_ids(_refs, _ids), do: []

  defp ohne_leere(liste), do: liste |> Enum.reject(&(&1 in [nil, ""])) |> Enum.uniq()
end
