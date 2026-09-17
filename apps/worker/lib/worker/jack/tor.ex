defmodule Worker.Jack.Tor do
  @moduledoc """
  Das Verifikationstor: findet Aussagen im Bestand, die einer neuen ähneln,
  und verwaltet die GUIDs, mit denen Jack über eine Kollision entscheidet.

  Portiert aus dem Spike (`aehnlicheZu`, `istBestaetigung`, `ausgeben`,
  `verbrauchen`, GUID-Verfall). Jack sieht den Bestand nicht; eine bestehende
  Aussage bekommt er nur zu sehen, wenn er mit ihr kollidiert (Toms
  Entscheidung, keine Bestandssicht beim Sammeln).

  **Ähnlich** ist eine bestehende, nicht verworfene Aussage, wenn einer von
  drei Wegen trägt, mit Rang für die Reihenfolge:

    * gleiche Fundstellen und gleicher Wortlaut — Rang 100;
    * überlappende Fundstellen oder gleicher Beleg — Rang 50 (gleiche
      Fundstellen), 40 (gleicher Beleg) oder 20 (Überlappung);
    * sonst, bei mindestens drei langen Wörtern, eine Wortdeckung ab 0,75 — Rang 30.

  Zum Rang kommt die Wortdeckung als Nachkomma. Vorgelegt werden höchstens
  acht, die nächstliegende zuerst. Ein Fehlalarm kostet wenig — Jack
  entscheidet selbst —, einer zu wenig kostet eine Dublette.

  **GUIDs** gelten genau einmal und nur für den nächsten Aufruf: was dort
  nicht genannt wird, verfällt. Eine GUID ist an die Fundstellen des Aufrufs
  gebunden, der die Vorlage ausgelöst hat. Ihr Schicksal wird gemerkt, damit
  „erfunden“ (`fraud`) von „abgelaufen“ (`expired`) unterscheidbar bleibt.
  """

  alias Worker.Jack.{Beleg, Stand}

  @deckel 8

  @type treffer :: %{nr: integer(), voll: map(), rang: float()}

  @doc "Ähnliche Aussagen im Bestand, die nächstliegende zuerst, höchstens acht."
  @spec aehnliche(Stand.t(), term(), term(), term()) :: [treffer()]
  def aehnliche(%Stand{} = s, claim, refs, beleg) do
    neu = Beleg.woerter(claim || "")
    r = refs |> List.wrap() |> Enum.filter(&is_integer/1) |> MapSet.new()
    rk = r |> Enum.sort() |> Enum.join(",")
    beleg_neu = Beleg.norm(beleg || "")
    claim_n = Beleg.norm(claim || "")

    s.eingetragen
    |> Enum.reject(& &1.voll["_verworfen"])
    |> Enum.flat_map(fn alt ->
      case rang(alt, neu, r, rk, claim_n, beleg_neu) do
        nil -> []
        rang -> [%{nr: alt.nr, voll: alt.voll, rang: rang}]
      end
    end)
    |> Enum.sort_by(& &1.rang, :desc)
    |> Enum.take(@deckel)
  end

  defp rang(alt, neu, r, rk, claim_n, beleg_neu) do
    ar = alt.voll |> Map.get("source_refs") |> List.wrap() |> Enum.filter(&is_integer/1)
    gleiche_refs = rk != "" and ar |> Enum.uniq() |> Enum.sort() |> Enum.join(",") == rk
    gleiche_stelle = Enum.any?(ar, &MapSet.member?(r, &1))
    treffer = Enum.count(neu, &MapSet.member?(alt.woerter, &1))

    deckung =
      if MapSet.size(neu) > 0,
        do: treffer / max(MapSet.size(neu), MapSet.size(alt.woerter)),
        else: 0

    beleg_alt = Beleg.norm(alt.voll["beleg"] || "")

    cond do
      gleiche_refs and Beleg.norm(alt.voll["claim"] || "") == claim_n ->
        100 + deckung

      gleiche_stelle or (beleg_neu != "" and beleg_neu == beleg_alt) ->
        weg(gleiche_refs, beleg_neu == beleg_alt) + deckung

      MapSet.size(neu) < 3 ->
        nil

      deckung >= 0.75 ->
        30 + deckung

      true ->
        nil
    end
  end

  defp weg(true, _gleicher_beleg), do: 50
  defp weg(false, true), do: 40
  defp weg(false, false), do: 20

  @doc """
  Hat ein späterer Versuch diese Aussage unabhängig wiedergefunden? Nur bei
  gleichen Fundstellen und hoher Wortdeckung (ab 0,6) — eine Vorlage allein
  zählt nicht, das Tor legt auch zwei verschiedene Aussagen aus demselben
  Block vor.
  """
  @spec bestaetigung?(map(), term(), term()) :: boolean()
  def bestaetigung?(alt, claim, refs) do
    ar = alt |> Map.get("source_refs") |> refs_schluessel()
    nr = refs_schluessel(refs)

    cond do
      ar == "" or ar != nr ->
        false

      true ->
        a = Beleg.woerter(alt["claim"] || "")
        b = Beleg.woerter(claim || "")

        if MapSet.size(a) == 0 or MapSet.size(b) == 0 do
          Beleg.norm(alt["claim"] || "") == Beleg.norm(claim || "")
        else
          Enum.count(b, &MapSet.member?(a, &1)) / max(MapSet.size(a), MapSet.size(b)) >= 0.6
        end
    end
  end

  @doc "Der Schlüssel einer Fundstellenmenge: sortiert, eindeutig, kommagetrennt."
  @spec refs_schluessel(term()) :: String.t()
  def refs_schluessel(refs),
    do:
      refs
      |> List.wrap()
      |> Enum.filter(&is_integer/1)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.join(",")

  @doc "Eine GUID ausgeben, gebunden an die Aussage `nr` und die Fundstellen `refs`."
  @spec ausgeben(Stand.t(), String.t(), %{nr: integer(), refs: [integer()]}) :: Stand.t()
  def ausgeben(%Stand{} = s, guid, offen),
    do: %{
      s
      | offene: Map.put(s.offene, guid, offen),
        ausgegeben: Map.put(s.ausgegeben, guid, :offen)
    }

  @doc "Eine GUID einlösen."
  @spec verbrauchen(Stand.t(), String.t()) :: Stand.t()
  def verbrauchen(%Stand{} = s, guid) do
    ausgegeben =
      if Map.get(s.ausgegeben, guid) == :offen,
        do: Map.put(s.ausgegeben, guid, :eingeloest),
        else: s.ausgegeben

    %{s | offene: Map.delete(s.offene, guid), ausgegeben: ausgegeben}
  end

  @doc "Alle offenen GUIDs verfallen lassen, außer den genannten."
  @spec verfallen_ausser(Stand.t(), MapSet.t() | [String.t()]) :: Stand.t()
  def verfallen_ausser(%Stand{} = s, genannt) do
    genannt = MapSet.new(genannt)

    Enum.reduce(Map.keys(s.offene), s, fn g, s ->
      if MapSet.member?(genannt, g),
        do: s,
        else: %{
          s
          | offene: Map.delete(s.offene, g),
            ausgegeben: Map.put(s.ausgegeben, g, :verfallen)
        }
    end)
  end

  @doc "Die offene Vorlage hinter einer GUID, oder `nil`."
  @spec offen(Stand.t(), term()) :: %{nr: integer(), refs: [integer()]} | nil
  def offen(%Stand{offene: o}, guid), do: Map.get(o, guid)

  @doc "Das Schicksal einer GUID: `:offen`, `:eingeloest`, `:verfallen`, oder `nil` (nie ausgegeben)."
  @spec schicksal(Stand.t(), term()) :: :offen | :eingeloest | :verfallen | nil
  def schicksal(%Stand{ausgegeben: a}, guid), do: Map.get(a, guid)
end
