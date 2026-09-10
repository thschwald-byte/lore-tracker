defmodule Worker.Agent.Modell.Strom do
  @moduledoc """
  Setzt eine gestreamte Antwort von `/v1/chat/completions` zusammen. Rein,
  ohne Netz testbar; `Worker.Agent.Modell.Ollama` füttert es mit den Bytes,
  wie sie ankommen.

  Der Strom besteht aus Server-Sent Events: je Stück eine Zeile
  `data: {json}`, am Ende `data: [DONE]`. Ein Stück trägt in
  `choices[0].delta` Text (`content`), Denken (`reasoning`, bei manchen
  Servern `reasoning_content`) oder Teile von Werkzeugaufrufen, in
  `choices[0].finish_reason` den Stoppgrund. Mit
  `stream_options.include_usage` kommt die Nutzung in einem letzten Stück
  ohne `choices`.

  Werkzeugaufrufe kommen wie bei OpenAI in Teilen, je `index` einer: `id`
  und `function.name` im ersten Teil, `function.arguments` als Text in
  Stücken, die aneinandergehängt werden. Ollama schickt einen Aufruf meist in
  einem Stück; beides geht denselben Weg. Fehlt der Index, ist jeder Teil ein
  eigener Aufruf.

  Bytes kommen, wie das Netz sie schneidet: mitten in einer Zeile oder mitten
  in einem UTF-8-Zeichen. `einlesen/2` hält den Rest bis zum nächsten
  Zeilenende zurück.

  Ein Strom, der weder `[DONE]` noch einen Stoppgrund gebracht hat, ist
  abgebrochen und wird zum Fehler — nie zu einer halben Antwort, die wie eine
  ganze aussieht.
  """

  defstruct rest: "",
            text: [],
            denken: [],
            aufrufe: %{},
            grund: nil,
            nutzung: nil,
            fertig: false,
            fehler: nil,
            roh: ""

  @type delta :: {:denken | :text, String.t()}
  @type t :: %__MODULE__{}

  # So viel vom Anfang des Stroms wird für Fehlermeldungen aufgehoben.
  @roh_max 2000

  @doc "Ein leerer Zustand."
  @spec neu() :: t()
  def neu, do: %__MODULE__{}

  @doc "Neue Bytes einlesen. Liefert den Zustand und die Deltas in Reihenfolge."
  @spec einlesen(t(), binary()) :: {t(), [delta()]}
  def einlesen(%__MODULE__{} = s, bytes) do
    s = %{s | roh: roh(s.roh, bytes)}
    {zeilen, [rest]} = (s.rest <> bytes) |> String.split("\n") |> Enum.split(-1)

    {s, deltas} =
      Enum.reduce(zeilen, {%{s | rest: rest}, []}, fn z, {s, acc} ->
        {s, d} = zeile(s, String.trim_trailing(z, "\r"))
        {s, [d | acc]}
      end)

    {s, deltas |> Enum.reverse() |> Enum.concat()}
  end

  @doc """
  Die zusammengesetzte Antwort in der Form eines nicht gestreamten Bodys
  (`choices`, `usage`), damit `Worker.Agent.Modell.Ollama.antwort/1` sie
  auslegt wie sonst auch.
  """
  @spec ergebnis(t()) :: {:ok, map()} | {:error, term()}
  def ergebnis(%__MODULE__{fehler: fehler}) when fehler != nil, do: {:error, fehler}

  def ergebnis(%__MODULE__{fertig: false, grund: nil} = s),
    do: {:error, {:strom_unvollstaendig, s.roh}}

  def ergebnis(%__MODULE__{} = s) do
    aufrufe =
      s.aufrufe
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {_, a} ->
        %{
          "id" => a.id,
          "type" => "function",
          "function" => %{"name" => a.name, "arguments" => text(a.argumente)}
        }
      end)

    nachricht = %{"content" => text(s.text), "reasoning" => text(s.denken)}
    nachricht = if aufrufe == [], do: nachricht, else: Map.put(nachricht, "tool_calls", aufrufe)

    {:ok,
     %{"choices" => [%{"message" => nachricht, "finish_reason" => s.grund}], "usage" => s.nutzung}}
  end

  # ─── Zeilen ───────────────────────────────────────────────────────────

  defp zeile(s, "data:" <> json) do
    json = String.trim(json)

    if json == "[DONE]" do
      {%{s | fertig: true}, []}
    else
      case Jason.decode(json) do
        {:ok, %{"error" => fehler}} -> {%{s | fehler: {:strom, fehler}}, []}
        {:ok, %{} = stueck} -> stueck(s, stueck)
        _ -> {%{s | fehler: s.fehler || {:antwortform, String.slice(json, 0, 200)}}, []}
      end
    end
  end

  # Leerzeilen trennen Ereignisse, `: …` sind Kommentare (Keep-alive).
  defp zeile(s, _anderes), do: {s, []}

  defp stueck(s, stueck) do
    s = if is_map(stueck["usage"]), do: %{s | nutzung: stueck["usage"]}, else: s

    case stueck["choices"] do
      [%{} = wahl | _] -> wahl_anwenden(s, wahl)
      _ -> {s, []}
    end
  end

  defp wahl_anwenden(s, wahl) do
    delta = wahl["delta"] || %{}
    denken = nicht_leer(delta["reasoning"] || delta["reasoning_content"])
    text = nicht_leer(delta["content"])

    s = %{
      s
      | grund: wahl["finish_reason"] || s.grund,
        denken: anhaengen(s.denken, denken),
        text: anhaengen(s.text, text),
        aufrufe: delta["tool_calls"] |> List.wrap() |> Enum.reduce(s.aufrufe, &aufruf_teil/2)
    }

    {s, delta_liste(:denken, denken) ++ delta_liste(:text, text)}
  end

  defp aufruf_teil(%{} = teil, acc) do
    i = teil["index"] || map_size(acc)
    funktion = teil["function"] || %{}
    alt = Map.get(acc, i, %{id: nil, name: nil, argumente: []})

    Map.put(acc, i, %{
      alt
      | id: alt.id || teil["id"],
        name: alt.name || funktion["name"],
        argumente: anhaengen(alt.argumente, argumente(funktion["arguments"]))
    })
  end

  defp aufruf_teil(_anderes, acc), do: acc

  defp argumente(%{} = map), do: Jason.encode!(map)
  defp argumente(text) when is_binary(text) and text != "", do: text
  defp argumente(_), do: nil

  defp delta_liste(_art, nil), do: []
  defp delta_liste(art, text), do: [{art, text}]

  defp anhaengen(liste, nil), do: liste
  defp anhaengen(liste, stueck), do: [stueck | liste]

  defp text(liste), do: liste |> Enum.reverse() |> IO.iodata_to_binary()

  defp nicht_leer(text) when is_binary(text) and text != "", do: text
  defp nicht_leer(_), do: nil

  defp roh(roh, _bytes) when byte_size(roh) >= @roh_max, do: roh

  defp roh(roh, bytes) do
    alles = roh <> bytes
    binary_part(alles, 0, min(byte_size(alles), @roh_max))
  end
end
