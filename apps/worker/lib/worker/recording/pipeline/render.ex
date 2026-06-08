defmodule Worker.Recording.Pipeline.Render do
  @moduledoc """
  Issue #651 (Wahrheitsbild, Phase B): die Geschwister-Render-Schicht. Resümee,
  Timeline und Epos rendern aus den **verifizierten** Fakten (statt aus der Prosa
  der jeweils anderen Stufe) — das bricht das Halluzinations-Laundering der
  Prosa-Kette.

  Dieser Slice: die **DETERMINISTISCHE Timeline** (`timeline/1`) — kein LLM.
  Datierte, verifizierte Fakten werden chronologisch sortiert zu Timeline-/
  Chronik-Einträgen gerendert. Damit wird der Zeitstrahl reproduzierbar (kein
  Modell-Verdrehen mehr, vgl. #650/#75-Klasse).

  Prosa-Renders (Resümee/Epos) + Render-Gating sind Folge-Slices.
  """

  alias Worker.Repo

  @doc """
  Rendert die datierten, verifizierten Fakten zu chronologischen Timeline-
  Einträgen — deterministisch, kein LLM.

  - **Nur verifizierte Fakten** (`verified? == true`) speisen den Render
    (Phase-B-Vertrag: Unverifiziertes geht nicht in den Output, nur ins
    Claims-UI). Flag-statt-Drop heißt: die unverifizierten bleiben in der
    Fakt-Tabelle, fließen aber hier nicht ein.
  - **Nur datierte Fakten** (`in_game_date` gesetzt) — die Timeline ist der
    Zeitstrahl; undatierte Fakten gehören ins Resümee/Epos, nicht hierher.
  - Sortiert über `Repo.derive_chronik_sort_tuple/1` (dieselbe Familie-Logik
    wie die Chronik, #135/#650). `Enum.sort_by` ist stabil → bei gleichem
    Datum bleibt die Eingabe-Reihenfolge (z.B. session.number-Vorsortierung aus
    `Repo.list_campaign_facts/1`) als Tie-Break erhalten.

  Eintrag-Shape (Chronik-kompatibel für den späteren Cutover):
  `%{in_game_date, label, summary, source_refs, session_id, character}`.
  """
  @spec timeline([map()]) :: [map()]
  def timeline(facts) when is_list(facts) do
    facts
    |> Enum.filter(&renderable?/1)
    |> Enum.sort_by(fn f -> Repo.derive_chronik_sort_tuple(f["in_game_date"]) end)
    |> Enum.map(&to_entry/1)
  end

  defp renderable?(f) when is_map(f), do: verified?(f) and dated?(f)
  defp renderable?(_), do: false

  defp verified?(f), do: Map.get(f, "verified?") == true

  defp dated?(f) do
    case Map.get(f, "in_game_date") do
      d when is_binary(d) -> String.trim(d) != ""
      _ -> false
    end
  end

  defp to_entry(f) do
    %{
      in_game_date: f["in_game_date"],
      # Label = die Figur (falls vorhanden) — kompakter Anker im Zeitstrahl;
      # der eigentliche Inhalt ist der Claim als summary.
      label: Map.get(f, "character_alias") || "",
      summary: f["claim"],
      source_refs: Map.get(f, "source_refs") || [],
      session_id: Map.get(f, "session_id"),
      character: Map.get(f, "character_alias") || ""
    }
  end
end
