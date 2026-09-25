defmodule Worker.Jack.Frage.Abbild do
  @moduledoc """
  Das Abbild des Frage-Jack für Beobachter (#850) — die Laufsicht und der
  Melder des Laufbands lesen es.

  **Jeder Jack braucht sein eigenes Abbild.** Der Chronik-Jack hatte am
  18.09.2026 keins, fiel auf das des Resümee-Jack zurück, und die Laufsicht
  zeigte `jack: "resuemee"` mit Wörtern und Gliederung, die es dort nicht
  gibt — in der Durchsicht wurde daraus ein Absturz (`{:badmap, nil}`), der
  die ganze Arbeit des Laufs vernichtete. Dieselbe Auffangzweig-Klasse wie
  `Stand.abschnitte/1`.
  """

  alias Worker.Jack.Resuemee.Stand

  @doc "Das Abbild eines Stands."
  @spec abbild(Stand.t()) :: map()
  def abbild(%Stand{} = s) do
    %{
      "jack" => "frage",
      "frage" => s.frage,
      "gelesen" => MapSet.size(s.gelesen),
      "fakten" => length(s.fakten),
      "beantwortet" => not is_nil(s.antwort),
      "belege" => belege(s.antwort)
    }
  end

  defp belege(nil), do: 0
  defp belege(a), do: length(Map.get(a, :fakt_ids, []))
end
