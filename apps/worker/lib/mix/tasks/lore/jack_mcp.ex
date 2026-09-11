defmodule Mix.Tasks.Lore.Jack.Mcp do
  @shortdoc "Jacks Werkzeuge als MCP-Server über stdio (Referenzlauf mit Claude Code, #1195)"
  @moduledoc """
  Startet Jacks Werkzeuge als MCP-Server (`Worker.Jack.Mcp`) über stdio. Claude
  Code startet ihn selbst, der Treiber (`mix lore.jack.referenz`) schreibt ihn
  in die `--mcp-config`.

      mix lore.jack.mcp --konfig <datei.json>

  Die Konfiguration nennt: `daten` (Spike-Daten), `namen` (Namensdatei),
  `phase` (1 oder 2), `von` (Ablage, aus der der Stand kommt, oder `null` für
  einen frischen Stand), `nach` (Ablage dieser Phase), optional `beispiele`
  (Beispielsatz).

  **stdout gehört dem Protokoll:** dort steht nur JSON-RPC, eine Nachricht je
  Zeile; Logs gehen nach stderr. Der Task kompiliert deshalb nicht selbst
  (`Compiling …` stünde auf stdout) — der Treiber kompiliert vorher. Er startet
  den Worker nicht (kein Mnesia, kein Hub). Stirbt stdin, endet er; die Ablage
  hat der Halter bis dahin laufend geschrieben.
  """

  use Mix.Task

  alias Worker.Jack.{Abzug, Beispiele, Fortsetzung, Halter, Mcp, Stand, Werkzeuge}

  @impl Mix.Task
  def run(args) do
    logs_nach_stderr()

    konfig =
      case OptionParser.parse(args, strict: [konfig: :string]) do
        {[konfig: pfad], [], []} -> pfad |> File.read!() |> Jason.decode!()
        _ -> Mix.raise("Aufruf: mix lore.jack.mcp --konfig <datei.json>")
      end

    {:ok, _} = Application.ensure_all_started(:jason)
    zustand = Mcp.neu(werkzeuge(konfig), journal: Path.join(konfig["nach"], "werkzeuge.jsonl"))
    schleife(zustand)
  end

  defp werkzeuge(k) do
    {:ok, namen} = Abzug.namen_aus_text(File.read!(k["namen"]))
    {:ok, e} = Abzug.spike_laden(k["daten"], namen)
    basis = [bloecke: e.bloecke, cast: e.cast, straenge: e.straenge, phase: k["phase"]]

    s =
      case k["von"] do
        nil ->
          Stand.neu(basis)

        von ->
          {:ok, s} = Fortsetzung.laden(von, basis)
          s
      end

    File.mkdir_p!(k["nach"])
    {:ok, halter} = Halter.start_link(s, ablage: k["nach"])

    beispiele =
      case k["beispiele"] do
        nil ->
          nil

        pfad ->
          {:ok, b} = Beispiele.laden(pfad)
          b
      end

    Werkzeuge.fuer(halter, beispiele: beispiele)
  end

  defp schleife(z) do
    case IO.binread(:stdio, :line) do
      zeile when is_binary(zeile) ->
        z =
          case Jason.decode(zeile) do
            {:ok, %{} = nachricht} ->
              {antworten, z} = Mcp.behandeln(nachricht, z)
              Enum.each(antworten, &IO.binwrite(:stdio, [Jason.encode_to_iodata!(&1), ?\n]))
              z

            _ ->
              IO.binwrite(:stderr, "mcp: keine JSON-Zeile: #{String.slice(zeile, 0, 200)}\n")
              z
          end

        schleife(z)

      _eof_oder_fehler ->
        :ok
    end
  end

  defp logs_nach_stderr do
    :logger.update_handler_config(:default, :config, %{type: :standard_error})
  rescue
    _ -> :ok
  end
end
