defmodule Mix.Tasks.Lore.Jack.Denkprobe do
  @shortdoc "Prüft am echten Ollama, ob eine zurückgeschickte Denkspur im Prompt ankommt (#1195)"
  @moduledoc """
  Prüft am echten Ollama, ob eine zurückgeschickte Denkspur (Feld
  `reasoning` an einer früheren Modellantwort, Laufoption `denken_zurueck`)
  im Prompt ankommt. Ollama verwirft unbekannte Felder kommentarlos — ein
  Fehler wäre also unsichtbar, der Lauf liefe einfach ohne.

      mix lore.jack.denkprobe [--endpunkt http://localhost:11434] [--modell qwen3.8:27b]

  Dreimal derselbe kurze Verlauf (Auftrag, eine Modellantwort mit
  Werkzeugaufruf, dessen Ergebnis) mit `max_tokens` 1: ohne Denkspur, mit
  Denkspur, noch einmal ohne. Verglichen wird `prompt_tokens` aus der
  Antwort des Servers. Kommt die Denkspur an, liegt die Differenz etwa bei
  ihrer Tokenzahl (Zeichen durch drei bis vier), sonst bei null. Die beiden
  Aufrufe ohne müssen gleich zählen — sonst rechnet der Server den Cache
  heraus, und die Differenz sagt nichts.

  **Belegt die Karte kurz** (drei Aufrufe mit Prompt-Auswertung, Sampling
  wie Reihe C). Nicht neben einem laufenden Messlauf starten; ob, entscheidet
  Tom.
  """

  use Mix.Task

  alias Worker.Agent.Modell.Ollama
  alias Worker.Agent.Werkzeug
  alias Worker.Jack.Messlauf

  @denken Enum.map_join(1..40, " ", fn i ->
            "Step #{i}: I compare block #{i * 7} with my notes before I call the next tool."
          end)

  @impl Mix.Task
  def run(args) do
    opts =
      case OptionParser.parse(args, strict: [endpunkt: :string, modell: :string]) do
        {opts, [], []} -> opts
        _ -> Mix.raise("Aufruf: mix lore.jack.denkprobe [--endpunkt url] [--modell name]")
      end

    Mix.Task.run("compile")
    {:ok, _} = Application.ensure_all_started(:req)

    {Ollama, modell_opts} =
      Messlauf.modell_reihe_c(
        Enum.reject([endpunkt: opts[:endpunkt], modell_name: opts[:modell]], fn {_, v} ->
          is_nil(v)
        end)
      )

    modell_opts = Keyword.put(modell_opts, :max_ausgabe, 1)

    ohne1 = messen(verlauf(nil), modell_opts)
    mit = messen(verlauf(@denken), modell_opts)
    ohne2 = messen(verlauf(nil), modell_opts)

    zeichen = String.length(@denken)
    differenz = mit - ohne1

    Mix.shell().info("""
    prompt_tokens ohne Denkspur: #{ohne1}, noch einmal: #{ohne2}
    prompt_tokens mit Denkspur:  #{mit}
    Differenz: #{differenz} Token für #{zeichen} Zeichen Denkspur \
    (erwartet etwa #{div(zeichen, 4)} bis #{div(zeichen, 3)})
    """)

    cond do
      ohne1 != ohne2 ->
        Mix.shell().error(
          "Unklar: die beiden Aufrufe ohne Denkspur zählen verschieden — der Server rechnet vermutlich den Cache heraus."
        )

      differenz > div(zeichen, 8) ->
        Mix.shell().info("Ergebnis: die Denkspur kommt im Prompt an.")

      true ->
        Mix.shell().error("Ergebnis: die Denkspur kommt NICHT im Prompt an.")
    end
  end

  defp verlauf(denken) do
    antwort = %{
      role: :assistant,
      content: nil,
      tool_calls: [%{id: "probe_1", name: "echo", argumente: {:ok, %{"text" => "hallo"}}}]
    }

    antwort = if denken, do: Map.put(antwort, :denken, denken), else: antwort

    [
      %{role: :system, content: "Du prüfst ein Werkzeug."},
      %{role: :user, content: "Ruf echo mit hallo auf und sag dann, was zurückkam."},
      antwort,
      %{role: :tool, tool_call_id: "probe_1", name: "echo", content: "hallo", fehler: false}
    ]
  end

  defp messen(nachrichten, modell_opts) do
    case Ollama.antworten(nachrichten, [echo()], modell_opts) do
      {:ok, %{nutzung: %{eingabe: eingabe}}} -> eingabe
      {:ok, antwort} -> Mix.raise("Keine Nutzung in der Antwort: #{inspect(antwort)}")
      {:error, grund} -> Mix.raise("Ollama: #{inspect(grund, printable_limit: 500)}")
    end
  end

  defp echo do
    Werkzeug.neu(
      name: "echo",
      beschreibung: "Gibt den Text zurück.",
      parameter: %{
        "type" => "object",
        "properties" => %{"text" => %{"type" => "string"}},
        "required" => ["text"]
      },
      ausfuehren: fn %{"text" => t} -> {:ok, t} end
    )
  end
end
