defmodule Mix.Tasks.Lore.Jack.Schauen do
  @shortdoc "Zeigt einen Jack-Lauf aus seinem Verzeichnis in der Laufsicht (#1202)"
  @moduledoc """
  Zeigt einen Jack-Lauf aus seinem Laufverzeichnis in der lokalen Laufsicht
  (`Worker.Jack.Sicht`). Gelesen werden das Protokoll der Laufzeit
  (`protokoll.jsonl`) und das Abbild des Halters (`stand.json`).

      mix lore.jack.schauen <laufverzeichnis> [--port 8098]

  Startet nur die Seite, nicht den Worker: kein Mnesia, keine
  Hub-Verbindung. Die Dateien werden beim Start gelesen. Live, mit Denken
  Token für Token, zeigt die Seite einen Lauf nur, wenn sie im selben BEAM
  läuft wie er (siehe `Worker.Jack.Sicht`).
  """

  use Mix.Task

  alias Worker.Jack.Sicht

  @impl Mix.Task
  def run(args) do
    case OptionParser.parse(args, strict: [port: :integer]) do
      {opts, [dir], []} -> schauen(dir, opts)
      _ -> Mix.raise("Aufruf: mix lore.jack.schauen <laufverzeichnis> [--port 8098]")
    end
  end

  defp schauen(dir, opts) do
    unless File.dir?(dir), do: Mix.raise("Kein Verzeichnis: #{dir}")

    Mix.Task.run("compile")
    {:ok, _} = Application.ensure_all_started(:plug_cowboy)

    case Sicht.start_link(
           port: Keyword.get(opts, :port, 8098),
           protokoll: Path.join(dir, "protokoll.jsonl"),
           ablage: dir
         ) do
      {:ok, sicht} ->
        Mix.shell().info("Laufsicht: http://127.0.0.1:#{Sicht.port(sicht)}  (Strg-C beendet)")

        Process.sleep(:infinity)

      {:error, grund} ->
        Mix.raise("Laufsicht startet nicht: #{inspect(grund)}")
    end
  end
end
