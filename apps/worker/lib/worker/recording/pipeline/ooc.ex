defmodule Worker.Recording.Pipeline.Ooc do
  @moduledoc """
  Issue #680: Out-of-Game-Heuristik für die Fakt-Extraktion. Erkennt **klare**
  Würfel-/Regel-/Wert-Turns und filtert sie aus dem Transkript, BEVOR der
  Extraktor es sieht — damit er sie nicht als `source_refs` zitieren kann
  (der schwache Extraktor ignoriert die „zitiere kein OOC"-Prompt-Regel).

  **Bewusst konservativ**: nur STARKE OOC-Signale (Würfel-Notation, numerische
  Proben „X gegen/auf Y", explizite Würfel-/Wert-/Schadens-Marker). Mehrdeutige
  Wörter allein (`Probe`, `geschafft`, `Vorteil`) lösen NICHT aus — die kommen
  auch in Narration vor, ein zu aggressiver Filter würde echte Erzähl-Turns
  verwerfen. Lieber etwas OOC durchlassen als Inhalt verlieren. Der echte
  Qualitätssprung (starker Extraktor) ist #426; das hier nimmt die gröbsten
  Würfel-Refs sofort raus.
  """

  # Würfel-Notation: W4/W6/W20/W100, „würfel/würfle/gewürfelt".
  @dice ~r/\bw\d+\b|würfel|würfl|gewürfelt/iu

  # Numerische Probe/Wert: „38 gegen 55", „22 auf 60", „mein Wert/Glück",
  # „Wert von/steht", „Schadenspunkt". Die Zahlen-gegen-Zahlen-Form ist das
  # stärkste Signal (kommt in Narration praktisch nie vor).
  @check ~r/\d+\s*(gegen|auf)\s*\d+|mein (wert|glück)|wert (von|steht)|schadenspunkt/iu

  @doc "True, wenn der Text ein klarer OOC-/Würfel-/Wert-Turn ist."
  @spec ooc?(String.t() | nil) :: boolean()
  def ooc?(text) when is_binary(text) do
    Regex.match?(@dice, text) or Regex.match?(@check, text)
  end

  def ooc?(_), do: false

  @doc """
  Entfernt klare OOC-Turns aus der Utterance-Liste. Reihenfolge bleibt erhalten;
  der Aufrufer muss dieselbe gefilterte Liste für Prompt-Rendering UND
  `source_refs`-Auflösung verwenden, damit die `[uN]`-Indizes übereinstimmen.
  """
  @spec filter([map()]) :: [map()]
  def filter(utterances) when is_list(utterances) do
    Enum.reject(utterances, fn u -> ooc?(utterance_text(u)) end)
  end

  defp utterance_text(u) when is_map(u), do: Map.get(u, :text) || Map.get(u, "text") || ""
  defp utterance_text(_), do: ""
end
