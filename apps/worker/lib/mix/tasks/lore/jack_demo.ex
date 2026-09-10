defmodule Mix.Tasks.Lore.Jack.Demo do
  @shortdoc "Demo der Jack-Laufsicht: Stub-Modell, erfundene Blöcke, Echtzeit"
  @moduledoc """
  Startet die Laufsicht (`Worker.Jack.Sicht`) und fährt die Demo
  (`Worker.Jack.Demo`), sobald die Seite offen ist.

      mix lore.jack.demo [--port 8098] [--nach <verzeichnis>] [--schnell]

  Ohne Ollama und ohne Worker-Start. Die Ablage geht nach
  `~/.local/share/lore-jack/demo/<zeitstempel>` — nie ins Scratchpad oder
  nach `/tmp`, beides ist nach einem Neustart weg. Es wird nichts gelöscht:
  jeder Start bekommt ein eigenes Verzeichnis.

  `--schnell` fährt die Demo sofort und ohne Pausen und beendet sich danach;
  sonst wartet der Task auf die Seite und hält sie nach dem Lauf offen, bis
  Strg-C.
  """

  use Mix.Task

  alias Worker.Jack.{Demo, Sicht}

  @impl Mix.Task
  def run(args) do
    {opts, [], []} =
      OptionParser.parse(args, strict: [port: :integer, nach: :string, schnell: :boolean])

    Mix.Task.run("compile")
    {:ok, _} = Application.ensure_all_started(:plug_cowboy)

    schnell = Keyword.get(opts, :schnell, false)
    stempel = DateTime.utc_now() |> Calendar.strftime("%Y%m%d-%H%M%S")
    ablage = Path.join(opts[:nach] || Path.expand("~/.local/share/lore-jack/demo"), stempel)

    {:ok, sicht} = Sicht.start_link(port: Keyword.get(opts, :port, 8098))
    url = "http://127.0.0.1:#{Sicht.port(sicht)}"

    unless schnell do
      Mix.shell().info("Laufsicht: #{url} — die Demo startet, sobald die Seite offen ist.")
      warten_auf_seite(sicht)
      Process.sleep(1500)
    end

    e = Demo.laufen(sicht: sicht, ablage: ablage, tempo: if(schnell, do: 0, else: 1))

    Mix.shell().info(
      "Phase 1: #{ende(e.phase1)}, Phase 2: #{ende(e.phase2)} — Ablage #{ablage}" <>
        if(schnell, do: "", else: " — die Seite bleibt offen, Strg-C beendet.")
    )

    unless schnell, do: Process.sleep(:infinity)
  end

  defp warten_auf_seite(sicht) do
    if Sicht.seiten(sicht) > 0 do
      :ok
    else
      Process.sleep(500)
      warten_auf_seite(sicht)
    end
  end

  defp ende({_, %{ende: ende}}), do: inspect(ende)
end
