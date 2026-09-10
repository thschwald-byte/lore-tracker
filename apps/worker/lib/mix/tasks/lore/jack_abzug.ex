defmodule Mix.Tasks.Lore.Jack.Abzug do
  @shortdoc "Zieht eine Prod-Sitzung als Testdaten für Jack, lesend per RPC"
  @moduledoc """
  Zieht eine Sitzung aus dem laufenden `worker_prod` als Arbeitsmaterial für
  Jack und legt sie außerhalb des Repos ab (`Worker.Jack.Abzug`).

      mix lore.jack.abzug --sitzung <session_id> --namen <namensdatei>
                          [--nach <verzeichnis>] [--knoten worker_prod@<host>]

  Nur lesend: `get_session`, `get_campaign`, `get_smoothed_blocks`,
  `character_names_for`, `character_roster_for`, `campaign_threads`,
  `get_session_facts` — als `:rpc.call` mit Modul, Funktion und Argumenten,
  nie mit einer anonymen Funktion (die gibt es im anderen BEAM nicht). Die
  Verbindung ist verdeckt (`hidden_connect_node`), wie beim Seeding über die
  RPC-Brücke.

  Die Namensdatei bildet Discord-IDs und Handles auf Figurennamen ab und liegt
  ebenfalls außerhalb des Repos. Fehlt für einen Sprecher ein Name oder steht
  ein Handle im Roster, bricht der Abzug ab.

  Default für `--nach`: `~/.local/share/lore-jack/testdaten/<session_id>`.
  """

  use Mix.Task

  alias Worker.Jack.Abzug

  @aufruf "Aufruf: mix lore.jack.abzug --sitzung <id> --namen <datei> [--nach <dir>] [--knoten <node>]"

  @impl Mix.Task
  def run(args) do
    opts = optionen!(args)
    Mix.Task.run("compile")
    namen = namen!(opts[:namen])
    rpc = verbinden!(opts[:knoten])
    sitzung = opts[:sitzung]

    case Abzug.aufbereiten(abfragen(rpc, sitzung), namen) do
      {:ok, daten} ->
        ablegen(
          opts[:nach] || Path.expand("~/.local/share/lore-jack/testdaten/#{sitzung}"),
          daten
        )

      {:error, grund} ->
        Mix.raise(meldung(grund))
    end
  end

  defp optionen!(args) do
    case OptionParser.parse(args,
           strict: [sitzung: :string, namen: :string, nach: :string, knoten: :string]
         ) do
      {opts, [], []} -> if opts[:sitzung] && opts[:namen], do: opts, else: Mix.raise(@aufruf)
      _ -> Mix.raise(@aufruf)
    end
  end

  defp abfragen(rpc, sitzung) do
    s =
      rpc.(Worker.Repo.Recording, :get_session, [sitzung]) ||
        Mix.raise("Sitzung #{sitzung} gibt es nicht.")

    cid = s.campaign_id

    snap =
      rpc.(Worker.Repo.Artifacts, :get_smoothed_blocks, [sitzung]) ||
        Mix.raise("Keine geglätteten Blöcke.")

    %{
      bloecke: snap.blocks,
      spielleiter: (rpc.(Worker.Repo, :get_campaign, [cid]) || %{})[:owner_discord_id],
      figuren: rpc.(Worker.Repo, :character_names_for, [cid]),
      roster: rpc.(Worker.Repo, :character_roster_for, [cid]),
      straenge: rpc.(Worker.Repo.Threads, :campaign_threads, [cid]) |> Enum.map(& &1.canonical),
      fakten: fakten(rpc.(Worker.Repo.Artifacts, :get_session_facts, [sitzung])),
      meta: %{
        "campaign_id" => cid,
        "session_id" => sitzung,
        "sitzung_nummer" => s.number,
        "rules_version" => snap.rules_version,
        "smoothed_at" => to_string(snap.smoothed_at),
        "abgezogen_am" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "quelle" => "worker_prod"
      }
    }
  end

  defp fakten(%{facts: facts}), do: facts
  defp fakten(_), do: []

  defp ablegen(dir, daten) do
    Abzug.schreiben(dir, daten)
    m = daten["meta"]

    Mix.shell().info(
      "Abzug in #{dir}: #{m["bloecke"]} Blöcke, Sprecher #{Enum.join(m["sprecher"], ", ")}, " <>
        "#{length(daten["cast"])} im Cast, #{length(daten["straenge"])} Stränge, " <>
        "#{length(daten["fakten"])} Fakten."
    )
  end

  defp meldung({:sprecher_ohne_namen, ids}),
    do:
      "Diese Sprecher haben keinen Namen — in die Namensdatei eintragen: #{Enum.join(ids, ", ")}"

  defp meldung({:roster_handles, handles}),
    do:
      "Im Roster stehen Handles ohne Figurennamen — in die Namensdatei eintragen: " <>
        Enum.join(handles, ", ")

  defp namen!(pfad) do
    with {:ok, text} <- File.read(pfad),
         {:ok, namen} <- Abzug.namen_aus_text(text) do
      namen
    else
      {:error, grund} -> Mix.raise("Namensdatei #{pfad}: #{inspect(grund)}")
    end
  end

  defp verbinden!(knoten) do
    {:ok, host} = :inet.gethostname()
    ziel = String.to_atom(knoten || "worker_prod@#{host}")
    name = :"jackabzug#{System.unique_integer([:positive])}"

    # :net_kernel.start/2 mit Map statt Node.start/2: dessen Signatur ist
    # zwischen Elixir-Versionen gewandert, die Erlang-Form trägt OTP 27 und 29.
    case :net_kernel.start(name, %{name_domain: :shortnames}) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, grund} -> Mix.raise("Verteilung startet nicht (läuft epmd?): #{inspect(grund)}")
    end

    unless :net_kernel.hidden_connect_node(ziel), do: Mix.raise("#{ziel} ist nicht erreichbar.")

    fn m, f, a ->
      case :rpc.call(ziel, m, f, a, 60_000) do
        {:badrpc, grund} -> Mix.raise("RPC #{inspect(m)}.#{f}: #{inspect(grund)}")
        wert -> wert
      end
    end
  end
end
