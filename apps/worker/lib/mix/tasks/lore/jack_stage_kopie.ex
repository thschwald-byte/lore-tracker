defmodule Mix.Tasks.Lore.Jack.StageKopie do
  @shortdoc "Kopiert eine Prod-Sitzung samt Spielern auf eine Teststage (nur Utterances)"
  @moduledoc """
  Legt eine Sitzung aus dem laufenden `worker_prod` auf dem Worker einer
  Teststage neu an: die Kampagne mit ihren Spielern und Aliasen, die Vorgaben
  und Töne aus „Stil setzen“, die Sitzung und ihre Roh-Utterances
  (`Worker.Jack.StageKopie`). Glättung, Fakten und Resümee baut danach die
  Pipeline der Stage selbst (J5, #1209, B5).

      mix lore.jack.stage_kopie --sitzung <session_id> --ziel <stage-worker-knoten>
                                [--quelle worker_prod@<host>]

  **Aus Prod nur lesend:** `get_session`, `get_campaign`, `list_members`,
  `list_utterances` per `:rpc.call` mit Modul, Funktion und Argumenten über
  eine verdeckte Verbindung, wie `mix lore.jack.abzug`. Geschrieben wird nur
  auf dem Ziel, über `Worker.Intents.publish_batch/1` (gechunkt, #702).

  **Schutz:** Ziel und Quelle müssen verschieden sein, das Ziel darf nicht
  `worker_prod` heißen, und gibt es die Kampagne auf dem Ziel schon, bricht
  der Task ab, statt Ereignisse doppelt zu schreiben.

  **`--weitere` ergänzt eine Sitzung** in einer Kampagne, die schon auf dem
  Ziel liegt (#1211): Die Chronik spannt über Sitzungsgrenzen, und mit einer
  einzigen Sitzung lässt sich weder eine Phase über zwei Sitzungen noch die
  Verfeinerung prüfen. Der Schutz bleibt dabei bestehen, nur enger gefasst —
  liegt die **Sitzung** selbst schon dort, bricht der Task weiterhin ab.

  Die Pipeline startet der Task nicht. Danach auf der Stage die Einstellungen
  setzen (etwa `gapfill_model`) und die Sitzung in der Oberfläche neu
  generieren oder `Worker.Recording.Pipeline.run_for_session/1` aufrufen.
  """

  use Mix.Task

  alias Mix.Tasks.Lore.Jack.Abzug
  alias Worker.Jack.StageKopie

  @aufruf "Aufruf: mix lore.jack.stage_kopie --sitzung <id> --ziel <knoten> " <>
            "[--quelle <knoten>] [--weitere]"

  @impl Mix.Task
  def run(args) do
    opts = optionen!(args)
    Mix.Task.run("compile")
    {:ok, host} = :inet.gethostname()
    quelle = opts[:quelle] || "worker_prod@#{host}"
    ziel = opts[:ziel]
    ziel_pruefen!(ziel, quelle)

    von = Abzug.verbinden!(quelle)
    nach = Abzug.verbinden!(ziel)
    roh = abfragen(von, opts[:sitzung])

    vorhanden? = nach.(Worker.Repo, :get_campaign, [roh.kampagne.id]) != nil

    cond do
      vorhanden? and not opts[:weitere] ->
        Mix.raise(
          "Die Kampagne „#{roh.kampagne.name}“ gibt es auf #{ziel} schon — nichts " <>
            "geschrieben. Mit --weitere wird die Sitzung ergänzt (für eine Chronik über " <>
            "mehrere Sitzungen, #1211)."
        )

      vorhanden? and nach.(Worker.Repo, :get_session, [roh.sitzung.id]) != nil ->
        Mix.raise("Die Sitzung #{roh.sitzung.id} liegt auf #{ziel} bereits — nichts geschrieben.")

      true ->
        :ok
    end

    case StageKopie.ereignisse(roh) do
      {:ok, payloads} -> veroeffentlichen(nach, payloads, roh, ziel)
      {:error, grund} -> Mix.raise("Nicht kopiert: #{inspect(grund)}")
    end
  end

  defp optionen!(args) do
    case OptionParser.parse(args,
           strict: [sitzung: :string, ziel: :string, quelle: :string, weitere: :boolean]
         ) do
      {opts, [], []} ->
        if opts[:sitzung] && opts[:ziel],
          do: Keyword.put_new(opts, :weitere, false),
          else: Mix.raise(@aufruf)

      _ ->
        Mix.raise(@aufruf)
    end
  end

  defp ziel_pruefen!(ziel, quelle) do
    cond do
      ziel == quelle ->
        Mix.raise("Ziel und Quelle sind derselbe Knoten (#{ziel}).")

      String.starts_with?(ziel, "worker_prod") ->
        Mix.raise("Das Ziel ist ein Prod-Worker: #{ziel}")

      true ->
        :ok
    end
  end

  defp abfragen(rpc, sitzung) do
    s =
      rpc.(Worker.Repo, :get_session, [sitzung]) || Mix.raise("Sitzung #{sitzung} gibt es nicht.")

    c = rpc.(Worker.Repo, :get_campaign, [s.campaign_id]) || Mix.raise("Keine Kampagne.")

    %{
      kampagne: c,
      mitglieder: rpc.(Worker.Repo, :list_members, [c.id]),
      sitzung: s,
      utterances: rpc.(Worker.Repo, :list_utterances, [sitzung, [limit: :all]])
    }
  end

  defp veroeffentlichen(nach, payloads, roh, ziel) do
    {:ok, z} = nach.(Worker.Intents, :publish_batch, [payloads])

    Mix.shell().info(
      "Auf #{ziel}: Kampagne „#{roh.kampagne.name}“, Sitzung #{roh.sitzung.number} " <>
        "(#{roh.sitzung.id}), #{length(roh.utterances)} Utterances, Spieler " <>
        "#{roh.mitglieder |> Enum.map(& &1.character_name) |> Enum.join(", ")} — " <>
        "#{length(payloads)} Ereignisse, #{z.synced} beim Hub, #{z.pending} ausstehend."
    )
  end
end
