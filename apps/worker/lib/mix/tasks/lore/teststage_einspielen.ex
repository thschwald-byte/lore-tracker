defmodule Mix.Tasks.Lore.Teststage.Einspielen do
  @shortdoc "Spielt den Teststage-Abzug in eine frische Teststage ein"
  @moduledoc """
  Wendet die Ereignisse eines Abzugs (#1260) auf den Worker einer Teststage an.

      mix lore.teststage.einspielen --nach <knoten> [--von <verzeichnis>] [--trocken]

  Angewandt wird über `Worker.Materializer.apply_batch/1`, also den kanonischen
  Weg: Die Artefakte — Glättung, Fakten, Chronik, Resümees, Epos — **entstehen
  dabei aus den Ereignissen**, statt Tabellen roh zu kopieren. Deshalb ist das
  auch der einzige Weg, der über einen Knotenwechsel hinweg funktioniert: Ein
  Mnesia-Archiv hängt am Knotennamen, ein Ereignis nicht.

  Was am Ziel schon liegt, wird **übersprungen** — Ereignisse sind
  unveränderliche Fakten mit eigener `event_id`. Der Task ist damit
  wiederholbar; ein abgebrochener Lauf lässt sich fortsetzen.

  **Niemals nach Prod** (`Worker.Teststage.prod_knoten?/1`): Die Ereignisse
  eines Teststands würden sich dort mit den echten mischen, und es gibt keinen
  Weg zurück.

  Ohne `--trocken` wird wirklich geschrieben; mit `--trocken` nur gezählt und
  aufgelistet.
  """

  use Mix.Task

  alias Worker.Teststage

  @aufruf "Aufruf: mix lore.teststage.einspielen --nach <knoten> [--von <dir>] [--trocken]"
  @stapel 200

  @impl Mix.Task
  def run(args) do
    if Mix.env() == :prod, do: Mix.raise("lore.teststage.einspielen läuft nicht mit MIX_ENV=prod")

    opts = optionen!(args)
    Mix.Task.run("compile")

    quelle = opts[:von] || Teststage.standard_verzeichnis()

    ereignisse =
      case Teststage.ereignisse(quelle) do
        {:ok, liste} ->
          liste

        {:error, :kein_abzug} ->
          Mix.raise("""
          Kein Abzug in #{quelle}

          Der Teststage-Default liegt außerhalb des Repos und ist nicht
          eingecheckt (er trägt die echten Namen der Runde). Einen Abzug
          erzeugen: mix lore.teststage.abzug
          """)
      end

    Mix.shell().info("#{length(ereignisse)} Ereignisse aus #{quelle}")
    for {art, n} <- Teststage.arten(ereignisse), do: Mix.shell().info("  #{pad(n)}  #{art}")

    if opts[:trocken] do
      Mix.shell().info("\nTrockenlauf — nichts geschrieben. Ohne --trocken wird angewandt.")
    else
      knoten = ziel!(opts[:nach])
      anwenden(knoten, ereignisse)
    end
  end

  defp anwenden(knoten, ereignisse) do
    Mix.shell().info("\nZiel: #{knoten}")

    gesamt = length(ereignisse)

    ereignisse
    |> Enum.map(&Teststage.zum_anwenden/1)
    |> Enum.chunk_every(@stapel)
    |> Enum.reduce(0, fn stapel, getan ->
      case :rpc.call(knoten, Worker.Materializer, :apply_batch, [stapel], 300_000) do
        {:badrpc, grund} ->
          # Laut abbrechen: Ein halb eingespielter Stand ist schlimmer als
          # keiner, und der Grund steht hier, nicht in einem Log.
          Mix.raise("Abbruch nach #{getan}/#{gesamt}: #{inspect(grund, limit: 4)}")

        _ ->
          fertig = getan + length(stapel)
          Mix.shell().info("  #{fertig}/#{gesamt}")
          fertig
      end
    end)

    Mix.shell().info("\nFertig. Die Artefakte entstehen aus den Ereignissen — das kann dauern.")
  end

  defp ziel!(nil), do: Mix.raise(@aufruf)

  defp ziel!(name) do
    if Teststage.prod_knoten?(name) do
      Mix.raise("""
      #{name} sieht nach einem Produktions-Worker aus.

      Der Abzug ist ein Teststand; seine Ereignisse würden sich dort mit den
      echten mischen, und es gibt keinen Weg zurück.
      """)
    end

    verbinden!(name)
  end

  # Siehe `lore.jack.abzug`: `:net_kernel.start/2` mit Map statt `Node.start/2`
  # — dessen Signatur ist zwischen Elixir-Versionen gewandert (unter OTP 29
  # bricht `Node.start(name, :shortnames)` den Vertrag), die Erlang-Form trägt
  # OTP 27 und 29. Verdeckt verbinden, damit dieser kurzlebige Knoten nicht
  # Teil des Clusters wird.
  defp verbinden!(name) do
    ziel = String.to_atom(to_string(name))
    eigener = :"teststageimport#{System.unique_integer([:positive])}"

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
    case File.read(Path.expand("~/.erlang.cookie")) do
      {:ok, inhalt} -> inhalt |> String.trim() |> String.to_atom()
      {:error, _} -> Mix.raise("Keine ~/.erlang.cookie — ohne sie keine Verbindung zum Worker.")
    end
  end

  defp pad(n), do: String.pad_leading("#{n}", 6)

  defp optionen!(args) do
    case OptionParser.parse(args, strict: [nach: :string, von: :string, trocken: :boolean]) do
      {opts, [], []} -> opts
      _ -> Mix.raise(@aufruf)
    end
  end
end
