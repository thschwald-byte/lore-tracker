defmodule Mix.Tasks.Lore.Teststage.Abzug do
  @shortdoc "Zieht die Ereignisse eines Workers als Teststage-Abzug (JSONL)"
  @moduledoc """
  Schreibt die Ereignisse eines laufenden Workers als JSONL-Abzug außerhalb des
  Repos (#1260) — der Stand, mit dem `mix lore.teststage.einspielen` eine
  frische Teststage befüllt.

      mix lore.teststage.abzug [--von <knoten>] [--nach <verzeichnis>]

  Ohne `--nach` das Standardverzeichnis (`Worker.Teststage.standard_verzeichnis/0`).
  Ein bestehender Abzug dort wird **ersetzt**, nicht ergänzt: Zwei Stände
  gemischt wären ein Abzug, dem niemand ansieht, was er enthält.

  **Nur lesend**, per `:rpc.call` mit Modul, Funktion und Argumenten — nie mit
  einer anonymen Funktion, die es im anderen BEAM nicht gibt (die Falle steht
  seit längerem in der Memory dieses Projekts). Die Verbindung ist verdeckt.

  **Der Abzug trägt echte Namen** und darf nicht ins Repo: Ein Ziel im
  Arbeitsbaum wird abgewiesen (`Worker.Teststage.pfad_erlaubt?/2`).
  """

  use Mix.Task

  alias Worker.Teststage

  @aufruf "Aufruf: mix lore.teststage.abzug [--von <knoten>] [--nach <verzeichnis>]"

  @impl Mix.Task
  def run(args) do
    if Mix.env() == :prod, do: Mix.raise("lore.teststage.abzug läuft nicht mit MIX_ENV=prod")

    opts = optionen!(args)
    Mix.Task.run("compile")

    ziel = opts[:nach] || Teststage.standard_verzeichnis()

    unless Teststage.pfad_erlaubt?(ziel, Teststage.arbeitsbaum()) do
      Mix.raise("""
      Das Ziel liegt im Arbeitsbaum: #{ziel}

      Der Abzug trägt die echten Namen und Gespräche der Runde, und das Repo ist
      öffentlich. Wähle ein Ziel außerhalb — ohne --nach nimmt der Task
      #{Teststage.standard_verzeichnis()}.
      """)
    end

    knoten = verbinden!(opts[:von] || standard_knoten())
    schreiben(knoten, ziel)
  end

  defp schreiben(knoten, ziel) do
    File.rm_rf!(ziel)
    File.mkdir_p!(ziel)

    tabellen =
      knoten
      |> rpc!(:mnesia, :system_info, [:tables])
      |> Enum.filter(&ereignis_tabelle?/1)
      |> Enum.sort()

    if tabellen == [], do: Mix.raise("Auf #{knoten} gibt es keine Ereignis-Tabellen.")

    gesamt =
      for tabelle <- tabellen, reduce: 0 do
        summe ->
          rows = rpc!(knoten, :mnesia, :dirty_match_object, [{tabelle, :_, :_, :_, :_}])
          datei = Path.join(ziel, "#{tabelle}.jsonl")

          # Kodiert wird auf dem WORKER: Dieser Task hat Jason, aber die
          # Payloads können Structs enthalten, die nur dort definiert sind.
          zeilen =
            for {_t, event_id, hub_seq, payload, ts} <- rows do
              rpc!(knoten, Jason, :encode!, [
                %{
                  "event_id" => event_id,
                  "hub_seq" => hub_seq,
                  "payload" => payload,
                  "ts" => to_string(ts)
                }
              ])
            end

          File.write!(datei, Enum.map(zeilen, &[&1, "\n"]))
          Mix.shell().info("  #{tabelle}: #{length(rows)}")
          summe + length(rows)
      end

    Mix.shell().info("\n#{gesamt} Ereignisse → #{ziel}")
    Mix.shell().info("Einspielen: mix lore.teststage.einspielen --nach <knoten>")
  end

  defp ereignis_tabelle?(tabelle) do
    s = to_string(tabelle)
    String.starts_with?(s, "worker_campaign_events") or s == "worker_events_global"
  end

  defp rpc!(knoten, modul, fun, args) do
    case :rpc.call(knoten, modul, fun, args, 120_000) do
      {:badrpc, grund} -> Mix.raise("RPC an #{knoten} gescheitert: #{inspect(grund)}")
      ergebnis -> ergebnis
    end
  end

  # `:net_kernel.start/2` mit Map statt `Node.start/2`: Dessen Signatur ist
  # zwischen Elixir-Versionen gewandert (unter OTP 29 bricht
  # `Node.start(name, :shortnames)` den Vertrag), die Erlang-Form trägt OTP 27
  # und 29. Derselbe Weg wie in `lore.jack.abzug`, wo der Kommentar schon stand.
  #
  # Verdeckt verbinden (`hidden_connect_node`), damit dieser kurzlebige Knoten
  # nicht Teil des Clusters wird.
  defp verbinden!(name) do
    ziel = String.to_atom(to_string(name))
    eigener = :"teststageabzug#{System.unique_integer([:positive])}"

    case :net_kernel.start(eigener, %{name_domain: :shortnames}) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, grund} -> Mix.raise("Verteilung startet nicht (läuft epmd?): #{inspect(grund)}")
    end

    Node.set_cookie(cookie!())

    unless :net_kernel.hidden_connect_node(ziel),
      do: Mix.raise("#{ziel} ist nicht erreichbar — läuft der Worker?")

    ziel
  end

  defp cookie! do
    pfad = Path.expand("~/.erlang.cookie")

    case File.read(pfad) do
      {:ok, inhalt} -> inhalt |> String.trim() |> String.to_atom()
      {:error, _} -> Mix.raise("Keine ~/.erlang.cookie — ohne sie keine Verbindung zum Worker.")
    end
  end

  defp standard_knoten do
    {host, 0} = System.cmd("hostname", ["-s"])
    "worker_prod@#{String.trim(host)}"
  end

  defp optionen!(args) do
    case OptionParser.parse(args, strict: [von: :string, nach: :string]) do
      {opts, [], []} -> opts
      _ -> Mix.raise(@aufruf)
    end
  end
end
