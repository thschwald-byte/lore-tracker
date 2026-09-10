defmodule Worker.Agent.Kontext do
  @moduledoc """
  Kompaktierung: wann der Verlauf zu groß ist, wo er geschnitten wird und was
  an die Stelle des Weggeschnittenen tritt.

  Optionen des Laufs (`kontext:` in `Worker.Agent.Lauf`):

    * `:fenster` — das Kontextfenster in Token, wie es der Server wirklich hat.
      **Es muss zum Server passen**: der Client setzt es nicht. Ist das Fenster
      am Server kleiner, kompaktiert der Lauf zu spät, und Ollama schneidet
      vorher still ab (#889).
    * `:reserve` — so viel bleibt für die nächste Antwort frei.
    * `:behalten` — so viele Token der jüngsten Nachrichten bleiben nach einem
      Schnitt mindestens stehen.
    * `:zusammenfassen` — `fn %{weggefallen: [nachricht], vorherige: text | nil} -> text end`.
      Der Text ersetzt alles Weggeschnittene als **eine** Nachricht. Gedacht
      ist ein deterministischer Aufbau aus dem Stand der Werkzeuge, kein
      zweiter Modellaufruf — die Form, die der Spike per Hook benutzt.
      `vorherige` ist die Zusammenfassung des letzten Schnitts, die jetzt
      selbst wegfällt. Default: `standard_zusammenfassung/1`.

  Gerechnet wird wie bei pi (`compaction.js`): geschätzt wird mit vier Zeichen
  je Token; gemessen ist, was die letzte Antwort in `usage` meldet, plus die
  Schätzung für alles, was seitdem angehängt wurde. Kompaktiert wird, sobald
  `Token > fenster − reserve`.

  **Der Schnitt trennt nie einen Werkzeugaufruf von seinem Ergebnis.**
  Geschnitten wird nur vor einer Nachricht des Nutzers oder des Modells, nie
  vor einem Werkzeugergebnis; schneidet er vor einer Modellantwort mit
  Aufrufen, bleiben deren Ergebnisse dahinter stehen. Die angehefteten
  Nachrichten (Auftrag) und der Systemprompt sind nicht Teil des Verlaufs, den
  diese Funktionen sehen, und werden deshalb nie geschnitten.
  """

  @type nachricht :: map()

  @doc "Grobe Token-Schätzung: Zeichen von Text, Werkzeugnamen und Argumenten, durch vier."
  @spec schaetzen(nachricht() | [nachricht()]) :: non_neg_integer()
  def schaetzen(nachrichten) when is_list(nachrichten),
    do: Enum.reduce(nachrichten, 0, &(schaetzen(&1) + &2))

  def schaetzen(%{} = n) do
    aufrufe = Enum.reduce(Map.get(n, :tool_calls) || [], 0, &(aufruf_zeichen(&1) + &2))
    div(zeichen(Map.get(n, :content)) + aufrufe + 3, 4)
  end

  @doc """
  Die Größe des Kontexts. `basis` ist `{gemessene_token, verlauf_laenge}` aus
  der letzten Antwort oder `nil`, wenn es keine Messung gibt (dann wird alles
  geschätzt, auch `fest` — Systemprompt, Auftrag, Zusammenfassung).
  """
  @spec tokens([nachricht()], [nachricht()], {non_neg_integer(), non_neg_integer()} | nil) ::
          non_neg_integer()
  def tokens(fest, verlauf, nil), do: schaetzen(fest) + schaetzen(verlauf)
  def tokens(_fest, verlauf, {gemessen, bis}), do: gemessen + schaetzen(Enum.drop(verlauf, bis))

  @doc "Muss kompaktiert werden?"
  @spec voll?(non_neg_integer(), pos_integer(), non_neg_integer()) :: boolean()
  def voll?(tokens, fenster, reserve), do: tokens > fenster - reserve

  @doc """
  Index der ersten Nachricht im Verlauf, die nach einem Schnitt stehen bleibt;
  `0` heißt: nichts zu schneiden.

  Wie pi (`findCutPoint`): von hinten Token aufsummieren, bis `behalten`
  erreicht ist, dann am nächsten gültigen Schnittpunkt **ab** dieser Stelle
  schneiden. **Abweichung:** gibt es dort keinen (typisch: ein einzelnes
  riesiges Werkzeugergebnis ganz hinten), behält pi den ganzen Verlauf und
  kompaktiert damit gar nichts. Hier wird stattdessen am letzten gültigen
  Punkt **davor** geschnitten — es bleibt mehr als `behalten` stehen, aber
  das Ältere fällt weg.
  """
  @spec schnitt([nachricht()], pos_integer()) :: non_neg_integer()
  def schnitt(verlauf, behalten) do
    indiziert = Enum.with_index(verlauf)
    punkte = for {%{role: role}, i} <- indiziert, role in [:user, :assistant], do: i

    case {punkte, grenze(indiziert, behalten)} do
      {[], _} -> 0
      {_, nil} -> 0
      {punkte, i} -> Enum.find(punkte, &(&1 >= i)) || List.last(punkte)
    end
  end

  @doc """
  Die Zusammenfassung ohne Rückruf des Aufrufers: ein Vermerk, wie viel
  weggefallen ist und welche Werkzeuge darin aufgerufen wurden. Er erhält den
  Inhalt nicht — wer den Stand braucht, gibt `zusammenfassen:` mit.
  """
  @spec standard_zusammenfassung(%{weggefallen: [nachricht()], vorherige: String.t() | nil}) ::
          String.t()
  def standard_zusammenfassung(%{weggefallen: weg, vorherige: vorherige}) do
    namen = for %{role: :assistant, tool_calls: aufrufe} <- weg, a <- aufrufe || [], do: a.name

    zaehlung =
      namen
      |> Enum.frequencies()
      |> Enum.sort()
      |> Enum.map_join(", ", fn {name, n} -> "#{name} ×#{n}" end)

    vermerk =
      "[Gekürzt: #{length(weg)} ältere Nachrichten, #{length(namen)} Werkzeugaufrufe" <>
        if(zaehlung == "", do: "", else: " (#{zaehlung})") <> ".]"

    if vorherige, do: vorherige <> "\n\n" <> vermerk, else: vermerk
  end

  defp grenze(indiziert, behalten) do
    indiziert
    |> Enum.reverse()
    |> Enum.reduce_while(0, fn {n, i}, summe ->
      summe = summe + schaetzen(n)
      if summe >= behalten, do: {:halt, {:bei, i}}, else: {:cont, summe}
    end)
    |> case do
      {:bei, i} -> i
      _summe -> nil
    end
  end

  defp zeichen(nil), do: 0
  defp zeichen(text) when is_binary(text), do: String.length(text)

  defp aufruf_zeichen(%{name: name, argumente: {:ok, argumente}}),
    do: String.length(name) + String.length(Jason.encode!(argumente))

  defp aufruf_zeichen(%{name: name, argumente: {:error, roh}}),
    do: String.length(name) + String.length(roh)
end
