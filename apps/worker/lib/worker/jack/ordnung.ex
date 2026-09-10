defmodule Worker.Jack.Ordnung do
  @moduledoc """
  Der Zustand von Phase 3, dem Ordnen des Bestands, und was sich daraus
  ableitet. Er liegt im `Worker.Jack.Stand` (Feld `ordnung`) als eigenes
  Struct, weil Phase 3 eine eigene Buchhaltung braucht.

  Drei Rollen wechseln sich ab, jede in einer eigenen Sitzung mit eigenen
  Werkzeugen (Spike, `S1_ROLLE`):

    * `"a"` ordnet den ganzen Bestand einmal und begründet jeden Schritt;
    * `"b"` prüft die Schritte gegen den Mitschnitt und kann einen
      zurückrollen;
    * `"c"` bessert nur nach, was `b` zurückgerollt hat.

  Die Runde kommt von außen, vom Treiber. Abgeleitet wäre sie brüchig: zwei
  Sitzungen derselben Rolle hintereinander müssen dieselbe Runde behalten.

  Felder:

    * `verlauf` — jeder Schritt mit Kennung (`"r1"`, `"r2"` …), Runde, Rolle
      und dem vollständigen vorherigen Stand jeder berührten Aussage. Die
      prüfende Rolle braucht ihn zum Zurückrollen; der Claim allein reicht
      dafür nicht. Journal: `aussagen_verlauf.jsonl`.
    * `kandidaten` — die angebotenen Dublettenpaare, in der Reihenfolge ihres
      Angebots; `getrennt` — die als verschieden erklärten. Beide überdauern
      Sitzungen: ein übergangenes Paar ist eine Unterlassung, und die sieht
      keine Prüfung. Im ersten Wechsellauf des Spikes blieben 10 von 18
      Paaren liegen, ohne dass es jemand merken konnte. Journal:
      `kandidaten.jsonl`.
    * `getrennt_neu` — die in dieser Sitzung getrennten Paare; der Abschluss
      fragt nach der Sitzung, nicht nach der Summe aller Runden.
    * `gesehen` — die angesehenen Bereiche, `"v-b"` aus `aussagen`, `"pv-b"`
      aus `aenderungen`. Journal: `bereiche.jsonl`.
  """

  # Kein Struct-Muster auf `Stand`: der trägt `Ordnung` als Feld, beides
  # zusammen wäre ein Zyklus beim Kompilieren. Nur Aufrufe, keine Muster.
  alias Worker.Jack.Stand

  # Fenster 200, Schritt 150, also 50 Überlappung. Zwei Aussagen an einer
  # Grenze (eine bei 199, eine bei 201) wären sonst nie zusammen sichtbar —
  # und genau dort sitzen Dubletten und Widersprüche.
  @fenster 200
  @schritt 150
  @stufen ~w(kritisch schwer mittel leicht unschoen)
  @keine_schritte ~w(abgelehnt angenommen erledigt)

  defstruct rolle: "a",
            runde: 1,
            verlauf: [],
            verlauf_lfd: 0,
            kandidaten: [],
            getrennt: MapSet.new(),
            getrennt_neu: 0,
            gesehen: MapSet.new()

  @type t :: %__MODULE__{}

  @doc "Die Stufen einer Ablehnung, von der schwersten zur mildesten."
  @spec stufen() :: [String.t()]
  def stufen, do: @stufen

  @doc """
  Die Stufen, die in Runde `n` zum Zurückrollen führen: in Runde 1 alle fünf,
  mit jeder Runde fällt die mildeste weg, ab Runde 6 keine mehr. Der Abbruch
  des Wechsels ist damit gerechnet statt geraten.
  """
  @spec stufen_der_runde(pos_integer()) :: [String.t()]
  def stufen_der_runde(n), do: Enum.take(@stufen, max(0, 6 - n))

  @doc "Das Raster der Bereiche über `0..max_block`, als `{von, bis}`."
  @spec raster(integer()) :: [{non_neg_integer(), non_neg_integer()}]
  def raster(max_block) when max_block < 0, do: []
  def raster(max_block), do: raster(0, max_block, [])

  defp raster(v, max, acc) when v > max, do: Enum.reverse(acc)

  defp raster(v, max, acc) do
    acc = [{v, min(v + @fenster, max)} | acc]
    if v + @fenster >= max, do: Enum.reverse(acc), else: raster(v + @schritt, max, acc)
  end

  @doc "Der Schlüssel eines Paars, unabhängig von der Reihenfolge."
  @spec paar_key(integer(), integer()) :: String.t()
  def paar_key(a, b) when is_integer(a) and is_integer(b), do: "#{min(a, b)}-#{max(a, b)}"

  @doc "Die Zahl hinter einer Kennung (`\"r12\"` → 12), zum Ordnen der Schritte."
  @spec id_nummer(term()) :: integer()
  def id_nummer("r" <> n) do
    case Integer.parse(n) do
      {i, ""} -> i
      _ -> 0
    end
  end

  def id_nummer(_), do: 0

  @doc """
  Einen Eintrag in den Verlauf schreiben; er bekommt Kennung, Runde und
  Rolle. Liefert den neuen Stand und die Kennung.
  """
  @spec verlauf_schreiben(Stand.t(), map()) :: {Stand.t(), String.t()}
  def verlauf_schreiben(s, eintrag) do
    o = s.ordnung
    n = o.verlauf_lfd + 1
    id = "r#{n}"
    voll = Map.merge(%{"id" => id, "runde" => o.runde, "rolle" => o.rolle}, eintrag)

    s =
      %{s | ordnung: %{o | verlauf: o.verlauf ++ [voll], verlauf_lfd: n}}
      |> Stand.journal("aussagen_verlauf.jsonl", voll)

    {s, id}
  end

  @doc "Die redaktionellen Schritte (nicht: Annahmen, Ablehnungen, Abhaken), die zurückrollbar sind."
  @spec schritte(t()) :: [map()]
  def schritte(%__MODULE__{verlauf: v}),
    do: Enum.filter(v, &(&1["id"] && &1["was"] not in @keine_schritte && is_list(&1["vorher"])))

  @doc "Die Kennungen der Schritte, die angenommen oder zurückgerollt sind."
  @spec erledigte_schritte(t()) :: MapSet.t()
  def erledigte_schritte(%__MODULE__{verlauf: v}) do
    for e <- v, e["was"] in ~w(abgelehnt angenommen), into: MapSet.new(), do: e["ref_id"]
  end

  @doc "Die Schritte, über die die prüfende Rolle noch nicht entschieden hat."
  @spec offene_schritte(t()) :: [map()]
  def offene_schritte(%__MODULE__{} = o) do
    durch = erledigte_schritte(o)
    Enum.reject(schritte(o), &MapSet.member?(durch, &1["id"]))
  end

  @doc "Die Aussagen, die ein Schritt berührt hat."
  @spec beruehrt(map()) :: [integer()]
  def beruehrt(%{"was" => "zusammengefuehrt"} = e), do: [e["behalten"], e["aufgegeben"]]
  def beruehrt(%{"nummer" => n}) when is_integer(n), do: [n]
  def beruehrt(_), do: []

  @doc """
  Die Blöcke eines Schritts — nach dem Stand vor der Änderung, sonst wanderte
  ein Schritt, der die Fundstellen verändert hat, aus dem Bereich heraus, in
  dem er zu prüfen wäre.
  """
  @spec schritt_refs(map()) :: [integer()]
  def schritt_refs(e), do: for(v <- e["vorher"] || [], r <- v["source_refs"] || [], do: r)

  @doc "Die Schritte dieser Rolle in dieser Runde."
  @spec eigene_schritte(t()) :: [map()]
  def eigene_schritte(%__MODULE__{} = o),
    do: Enum.filter(o.verlauf, &(&1["runde"] == o.runde and &1["rolle"] == o.rolle))

  @doc """
  Die Kandidatenpaare, die noch offen sind: weder getrennt noch dadurch
  erledigt, dass eine der beiden Aussagen fehlt oder verworfen ist.
  """
  @spec offene_kandidaten(Stand.t()) :: [map()]
  def offene_kandidaten(s) do
    o = s.ordnung

    Enum.reject(o.kandidaten, fn k ->
      MapSet.member?(o.getrennt, k.key) or
        Enum.any?(k.paar, fn n ->
          (Stand.bestand_von(s, n) || %{"_verworfen" => true})["_verworfen"]
        end)
    end)
  end

  @doc "Die Bereiche des Rasters, die diese Rolle noch nicht angesehen hat."
  @spec bereiche_offen(Stand.t()) :: [{integer(), integer()}]
  def bereiche_offen(s) do
    o = s.ordnung
    praefix = if o.rolle == "b", do: "p", else: ""

    Enum.reject(raster(s.max_block), fn {v, b} ->
      MapSet.member?(o.gesehen, "#{praefix}#{v}-#{b}")
    end)
  end

  @doc "Was noch offen ist — reist bei jeder Antwort mit, statt dass der Agent es sich merken muss."
  @spec offene_arbeit(Stand.t()) :: map()
  def offene_arbeit(s) do
    alle = raster(s.max_block)
    offen = bereiche_offen(s)

    %{
      "bereiche" => "#{length(alle) - length(offen)} von #{length(alle)}",
      "bereiche_offen" => Enum.map(offen, fn {v, b} -> "#{v}-#{b}" end),
      "kandidaten_offen" => Enum.map(offene_kandidaten(s), & &1.paar)
    }
  end

  @doc """
  Was die prüfende Rolle zurückgerollt hat, mit beiden Begründungen und dem
  Stand, wie er jetzt wieder dasteht — die Arbeitsliste der nachbessernden
  Rolle.
  """
  @spec ablehnungen_liste(Stand.t()) :: [map()]
  def ablehnungen_liste(s) do
    o = s.ordnung
    erledigt = for e <- o.verlauf, e["was"] == "erledigt", into: MapSet.new(), do: e["ref_id"]

    for e <- o.verlauf, e["was"] == "abgelehnt" do
      urspr = Enum.find(o.verlauf, %{}, &(&1["id"] == e["ref_id"]))
      nummern = for v <- urspr["vorher"] || [], is_integer(v["nummer"]), do: v["nummer"]

      %{
        "id" => e["ref_id"],
        "ablehnung_id" => e["id"],
        "erledigt" => MapSet.member?(erledigt, e["ref_id"]),
        "was_a_tat" => e["betraf"],
        "stufe" => e["stufe"],
        "runde" => e["runde"],
        "grund_a" => urspr["grund"],
        "ergebnis_von_a" => urspr["nachher"],
        "grund_b" => e["grund"],
        "stand_jetzt" =>
          for n <- nummern, v = Stand.bestand_von(s, n), v != nil do
            %{
              "nummer" => n,
              "claim" => v["claim"],
              "beleg" => v["beleg"],
              "source_refs" => v["source_refs"],
              "verworfen" => v["_verworfen"] == true
            }
          end
      }
    end
  end
end
