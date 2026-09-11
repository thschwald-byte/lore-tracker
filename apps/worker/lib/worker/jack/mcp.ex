defmodule Worker.Jack.Mcp do
  @moduledoc """
  Jacks Werkzeuge als MCP-Server (stdio, JSON-RPC 2.0, eine Nachricht je
  Zeile) — für den Referenzlauf über Claude Code headless (Tom, 11.09.2026:
  S3 darf zu Anthropic, Max-Abo). Claude Code ist dann die Agenten-Schleife;
  Werkzeuge, Halter, Ablage und die Regeln je Aufruf (`Worker.Agent.Aufruf`:
  Wiederholungssperre, Schema, Formfehler) sind dieselben wie im Port.

  Pur: `behandeln/2` nimmt eine dekodierte Nachricht und den Zustand und
  liefert die Antworten und den neuen Zustand. Ein- und Ausgabe macht
  `mix lore.jack.mcp`.

  Verstanden werden `initialize`, `tools/list`, `tools/call` und `ping`;
  Benachrichtigungen (ohne `id`) werden übergangen, eine unbekannte Methode
  ist ein JSON-RPC-Fehler. Ein Werkzeugergebnis geht als Text zurück,
  `isError` bei `error` und `abbruch`.

  **Ende einer Phase:** Hat `fertig()` die Phase beendet (`halt`) oder die
  Sperre den Lauf abgebrochen, führt der Server nichts mehr aus; jeder weitere
  Aufruf bekommt eine Antwort, die das sagt. Den Prozess beendet der Treiber
  (`mix lore.jack.referenz`), der dafür `werkzeuge.jsonl` liest: jeder Aufruf
  mit Name, Argumenten, Art und Text.
  """

  alias Worker.Agent.{Aufruf, Schema, Werkzeug}

  @version_standard "2025-06-18"

  defstruct [:liste, :aufruf, :journal, ende: nil]

  @type t :: %__MODULE__{}

  @doc "Optionen: `:journal` (Pfad von `werkzeuge.jsonl`), `:wiederholungen` wie in `Worker.Agent.Lauf`."
  @spec neu([Werkzeug.t()], keyword()) :: t()
  def neu(werkzeuge, opts \\ []) do
    %__MODULE__{
      liste: werkzeuge,
      aufruf: Aufruf.zustand(werkzeuge, Keyword.get(opts, :wiederholungen, [])),
      journal: opts[:journal]
    }
  end

  @doc "Eine Nachricht behandeln; liefert die Antworten (0 oder 1) und den neuen Zustand."
  @spec behandeln(map(), t()) :: {[map()], t()}
  def behandeln(%{"method" => "initialize", "id" => id} = m, z) do
    version = get_in(m, ["params", "protocolVersion"]) || @version_standard

    {[
       antwort(id, %{
         "protocolVersion" => version,
         "capabilities" => %{"tools" => %{"listChanged" => false}},
         "serverInfo" => %{"name" => "jack", "version" => "1"}
       })
     ], z}
  end

  def behandeln(%{"method" => "tools/list", "id" => id}, z),
    do: {[antwort(id, %{"tools" => Enum.map(z.liste, &beschreibung/1)})], z}

  def behandeln(%{"method" => "tools/call", "id" => id, "params" => %{"name" => name} = p}, z) do
    args = Map.get(p, "arguments") || %{}
    {{art, text}, z} = aufrufen(z, id, name, args)
    journal(z, name, args, art, text)

    {[
       antwort(id, %{
         "content" => [%{"type" => "text", "text" => text}],
         "isError" => art in [:error, :abbruch]
       })
     ], z}
  end

  def behandeln(%{"method" => "ping", "id" => id}, z), do: {[antwort(id, %{})], z}

  def behandeln(%{"method" => methode, "id" => id}, z),
    do: {[fehler(id, -32_601, "Methode #{methode} gibt es nicht.")], z}

  def behandeln(_benachrichtigung, z), do: {[], z}

  defp aufrufen(%{ende: :halt} = z, _id, _name, _args),
    do: {{:error, "Nicht ausgeführt: die Phase ist mit fertig() abgeschlossen."}, z}

  defp aufrufen(z, id, name, args) do
    argumente = if is_map(args), do: {:ok, args}, else: {:error, Jason.encode!(args)}
    aufruf = %{id: to_string(id), name: name, argumente: argumente}
    {{art, text}, a, _sperre} = Aufruf.beobachtet(z.aufruf, aufruf)
    z = %{z | aufruf: a, ende: z.ende || ende(art, a)}
    {{art, text}, z}
  end

  defp ende(:halt, _a), do: :halt
  defp ende(_art, %{abbruch: grund}) when grund != nil, do: :abbruch
  defp ende(_art, _a), do: nil

  defp beschreibung(%Werkzeug{} = w) do
    %{
      "name" => w.name,
      "description" => w.beschreibung,
      "inputSchema" => Schema.normalisieren(w.parameter)
    }
  end

  defp antwort(id, ergebnis), do: %{"jsonrpc" => "2.0", "id" => id, "result" => ergebnis}

  defp fehler(id, code, text),
    do: %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => text}}

  defp journal(%{journal: nil}, _name, _args, _art, _text), do: :ok

  defp journal(%{journal: pfad}, name, args, art, text) do
    zeile =
      Jason.encode_to_iodata!(%{
        "t" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "name" => name,
        "argumente" => args,
        "art" => Atom.to_string(art),
        "text" => text
      })

    File.write!(pfad, [zeile, ?\n], [:append])
  end
end
