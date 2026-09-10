defmodule Worker.Agent.Modell.Ollama do
  @moduledoc """
  Ollama über die OpenAI-kompatible Schnittstelle `/v1/chat/completions` mit
  `tools` — derselbe Pfad, über den der Spike #1174 gemessen wurde (pi spricht
  Ollama so an). `Worker.LLM.Local` spricht `/api/chat` für die Pipeline und
  bleibt davon unberührt.

  Optionen:

    * `:endpunkt` (Pflicht) — z.B. `"http://localhost:11434"`
    * `:modell` (Pflicht) — z.B. `"qwen3.8:27b"`
    * `:temperatur` → `temperature`
    * `:max_ausgabe` → `max_tokens`
    * `:timeout_ms` — HTTP-Frist, Default 600 000 (wie `http_timeout_ms`);
      beim Streaming je Stück, sonst für die ganze Antwort
    * `:extra` — Map, wird unverändert in den Anfrage-Body gemischt
    * `:bei_delta` — `fn art, text -> … end`, `art` ist `:denken` oder `:text`;
      schaltet Streaming ein (siehe unten)

  **Streaming**, wenn `:bei_delta` gesetzt ist: die Anfrage geht mit
  `stream: true` und `stream_options.include_usage`, Denken und Text gehen
  Stück für Stück an `bei_delta`, sobald sie ankommen, und
  `Worker.Agent.Modell.Strom` setzt die Antwort zusammen. Die Frist wirkt dann
  je Stück (Finch: „for each chunk“): eine lange Antwort, die fließt, läuft
  nicht in sie hinein, eine, die stockt, schon. Ohne `:bei_delta` kommt die
  Antwort als Ganzes. Beide Wege liefern dieselbe Antwortform. **Gegen das
  echte Ollama noch nicht geprüft**, namentlich Werkzeugaufrufe in Stücken
  und die Nutzung im letzten Stück; die Tests laufen gegen einen Stub-Server.

  Das Kontextfenster des Servers setzt dieser Client nicht — es muss zu
  `kontext: [fenster: …]` des Laufs passen (siehe `Worker.Agent.Kontext`).

  Die Nachrichtenform folgt pi (`openai-completions.js`, `convertMessages`):
  Werkzeugergebnisse gehen als `role: "tool"` mit `tool_call_id`, Argumente
  einer früheren Antwort als JSON-Text. Die Denkspur geht nicht zurück.
  """

  @behaviour Worker.Agent.Modell

  alias Worker.Agent.Modell.Strom
  alias Worker.Agent.Werkzeug

  @pfad "/v1/chat/completions"
  @timeout_ms 600_000

  @impl true
  def antworten(nachrichten, werkzeuge, opts) do
    case Keyword.get(opts, :bei_delta) do
      nil -> ganz(nachrichten, werkzeuge, opts)
      melden -> gestreamt(nachrichten, werkzeuge, opts, melden)
    end
  end

  defp ganz(nachrichten, werkzeuge, opts) do
    opts
    |> url()
    |> Req.post(
      json: anfrage(nachrichten, werkzeuge, opts),
      receive_timeout: Keyword.get(opts, :timeout_ms, @timeout_ms),
      retry: false
    )
    |> case do
      {:ok, %Req.Response{status: 200, body: %{} = body}} -> antwort(body)
      {:ok, %Req.Response{status: 200, body: body}} -> {:error, {:antwortform, body}}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:http, status, body}}
      {:error, fehler} -> {:error, {:netz, Exception.message(fehler)}}
    end
  end

  defp gestreamt(nachrichten, werkzeuge, opts, melden) do
    body =
      nachrichten
      |> anfrage(werkzeuge, opts)
      |> Map.merge(%{"stream" => true, "stream_options" => %{"include_usage" => true}})

    # Der Zustand des Stroms reist im Response mit; gemeldet wird nur, was
    # zu einer erfolgreichen Antwort gehört.
    into = fn {:data, bytes}, {req, resp} ->
      {strom, deltas} =
        resp |> Req.Response.get_private(:strom, Strom.neu()) |> Strom.einlesen(bytes)

      if resp.status == 200, do: Enum.each(deltas, &melden_eins(melden, &1))
      {:cont, {req, Req.Response.put_private(resp, :strom, strom)}}
    end

    opts
    |> url()
    |> Req.post(
      json: body,
      into: into,
      receive_timeout: Keyword.get(opts, :timeout_ms, @timeout_ms),
      retry: false
    )
    |> case do
      {:ok, %Req.Response{status: 200} = resp} ->
        with {:ok, ganz} <-
               resp |> Req.Response.get_private(:strom, Strom.neu()) |> Strom.ergebnis(),
             do: antwort(ganz)

      {:ok, %Req.Response{status: status} = resp} ->
        {:error, {:http, status, fehler_body(resp)}}

      {:error, fehler} ->
        {:error, {:netz, Exception.message(fehler)}}
    end
  end

  defp url(opts), do: String.trim_trailing(Keyword.fetch!(opts, :endpunkt), "/") <> @pfad

  defp melden_eins(melden, {art, text}), do: melden.(art, text)

  # Bei einem Fehlerstatus steht der Body entweder im Strom (wenn Req auch ihn
  # durch `into` geschickt hat) oder im Response.
  defp fehler_body(resp) do
    case Req.Response.get_private(resp, :strom) do
      %Strom{roh: roh} when roh != "" -> roh
      _ -> resp.body
    end
  end

  @doc false
  @spec anfrage([map()], [Werkzeug.t()], keyword()) :: map()
  def anfrage(nachrichten, werkzeuge, opts) do
    %{
      "model" => Keyword.fetch!(opts, :modell),
      "messages" => Enum.map(nachrichten, &nachricht/1),
      "stream" => false
    }
    |> setzen("tools", werkzeuge != [] && Enum.map(werkzeuge, &Werkzeug.als_json/1))
    |> setzen("temperature", opts[:temperatur])
    |> setzen("max_tokens", opts[:max_ausgabe])
    |> Map.merge(Keyword.get(opts, :extra, %{}))
  end

  @doc false
  @spec antwort(map()) :: {:ok, Worker.Agent.Modell.antwort()} | {:error, term()}
  def antwort(%{"choices" => [%{"message" => %{} = m} = wahl | _]} = body) do
    aufrufe = m |> Map.get("tool_calls") |> List.wrap() |> Enum.map(&aufruf/1)

    with {:ok, stopp} <- stopp(wahl["finish_reason"], aufrufe) do
      {:ok,
       %{
         text: nicht_leer(m["content"]),
         denken: nicht_leer(m["reasoning"] || m["reasoning_content"]),
         aufrufe: aufrufe,
         stopp: stopp,
         nutzung: nutzung(body["usage"])
       }}
    end
  end

  def antwort(anderes), do: {:error, {:antwortform, anderes}}

  # ─── Nachrichten hinaus ───────────────────────────────────────────────

  defp nachricht(%{role: :assistant} = n) do
    %{"role" => "assistant", "content" => n[:content] || ""}
    |> setzen(
      "tool_calls",
      (n[:tool_calls] || []) != [] && Enum.map(n.tool_calls, &aufruf_json/1)
    )
  end

  defp nachricht(%{role: :tool} = n),
    do: %{"role" => "tool", "tool_call_id" => n.tool_call_id, "content" => n.content}

  defp nachricht(%{role: role, content: text}) when role in [:system, :user],
    do: %{"role" => Atom.to_string(role), "content" => text}

  defp aufruf_json(%{id: id, name: name, argumente: argumente}) do
    %{
      "id" => id,
      "type" => "function",
      "function" => %{"name" => name, "arguments" => argumente_text(argumente)}
    }
  end

  defp argumente_text({:ok, map}), do: Jason.encode!(map)
  defp argumente_text({:error, roh}), do: roh

  # ─── Antwort herein ───────────────────────────────────────────────────

  # Ollama vergibt IDs selbst; fehlt eine, braucht das Ergebnis trotzdem eine
  # eindeutige, sonst ordnet der Server es beim nächsten Aufruf falsch zu.
  defp aufruf(%{} = a) do
    funktion = Map.get(a, "function") || %{}

    %{
      id: a["id"] || "aufruf_#{System.unique_integer([:positive])}",
      name: funktion["name"] || "",
      argumente: argumente(funktion["arguments"])
    }
  end

  defp argumente(nil), do: {:ok, %{}}
  defp argumente(%{} = map), do: {:ok, map}

  defp argumente(text) when is_binary(text) do
    if String.trim(text) == "" do
      {:ok, %{}}
    else
      case Jason.decode(text) do
        {:ok, %{} = map} -> {:ok, map}
        _ -> {:error, text}
      end
    end
  end

  defp argumente(anderes), do: {:error, inspect(anderes)}

  # pi: mapStopReason. Ein Stopp mit Aufrufen ist ein Werkzeug-Stopp, egal
  # welchen Grund der Server meldet.
  defp stopp("length", _aufrufe), do: {:ok, :laenge}
  defp stopp(grund, [_ | _]) when grund in [nil, "stop", "tool_calls"], do: {:ok, :werkzeuge}
  defp stopp(grund, []) when grund in [nil, "stop", "tool_calls"], do: {:ok, :stop}
  defp stopp(grund, _aufrufe), do: {:error, {:stoppgrund, grund}}

  defp nutzung(%{"prompt_tokens" => e, "completion_tokens" => a})
       when is_integer(e) and is_integer(a),
       do: %{eingabe: e, ausgabe: a}

  defp nutzung(_), do: nil

  defp nicht_leer(text) when is_binary(text) and text != "", do: text
  defp nicht_leer(_), do: nil

  defp setzen(map, _schluessel, wert) when wert in [nil, false], do: map
  defp setzen(map, schluessel, wert), do: Map.put(map, schluessel, wert)
end
