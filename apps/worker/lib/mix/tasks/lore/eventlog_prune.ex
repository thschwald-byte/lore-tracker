defmodule Mix.Tasks.Lore.EventlogPrune do
  use Mix.Task

  @shortdoc "Prunt alte Events aus dem worker-lokalen EventLog (#97 Cut 1)"

  @moduledoc """
  Issue #97 (Cut 1): Retention/Pruning für den worker-lokalen EventLog.

  Löscht Event-Rows mit `ts < --before-date` aus `worker_events_global` + allen
  per-Campaign-Stores (oder nur `--campaign <id>`). Die materialisierte Lese-
  State (campaigns/sessions/utterances/… als disc_copies) bleibt unangetastet —
  sie wird beim Boot NICHT aus dem Log rekonstruiert. Der EventLog dient nur
  Gossip-Pull + Disaster-Recovery; der Pull-Cursor (jüngstes Event) bleibt beim
  Prunen alter Events unberührt.

  ## Verwendung (gestoppter Worker / Dev)

      LORE_MNESIA_DIR=/pfad/zur/worker-mnesia mix lore.eventlog.prune --before-date 2026-01-01
      mix lore.eventlog.prune --before-date 2026-01-01 --dry-run
      mix lore.eventlog.prune --before-date 2026-01-01 --campaign <uuid>

  Startet den Worker gegen `LORE_MNESIA_DIR` und ruft `Worker.EventLog.prune_before/2`.
  `--dry-run` zählt nur. Akzeptiert volles ISO8601 oder ein nacktes Datum
  (`YYYY-MM-DD` → 00:00:00Z).

  ## Achtung: laufender Daemon

  Gegen einen **laufenden** `worker_prod`-Daemon geht das NICHT (Mnesia ist
  schema-/pfad-exklusiv). Dort per RPC in den Daemon:

      {:ok, cutoff, _} = DateTime.from_iso8601("2026-01-01T00:00:00Z")
      :rpc.call(:"worker_prod@<host>", Worker.EventLog, :prune_before, [cutoff, [dry_run: true]])

  ## DESTRUKTIV + Single-Worker

  Prune ist destruktiv für die Disaster-Recovery der geprunten Events — vorher
  ein Backup ziehen (siehe docs/Backup-Recovery.md). Single-Worker-scoped: bei
  Multi-Worker-Gossip (#131) braucht es einen signierten Prune-Event (Folge-Issue),
  sonst drücken andere Worker die geprunten Events wieder ein.
  """

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [before_date: :string, campaign: :string, dry_run: :boolean]
      )

    cutoff = parse_cutoff!(opts[:before_date])
    prune_opts = build_prune_opts(opts)

    Application.put_env(:worker, :no_browser, true)

    case Application.ensure_all_started(:worker) do
      {:ok, _apps} ->
        result = Worker.EventLog.prune_before(cutoff, prune_opts)

        Mix.shell().info(
          "eventlog.prune#{if result.dry_run, do: " [DRY-RUN]", else: ""} " <>
            "vor #{DateTime.to_iso8601(cutoff)}: global=#{result.global}, " <>
            "campaigns=#{map_size(result.campaigns)} (#{result.campaigns |> Map.values() |> Enum.sum()} rows), " <>
            "total=#{result.total} Event(s)#{if result.dry_run, do: " würden gelöscht", else: " gelöscht"}."
        )

      {:error, reason} ->
        Mix.raise(
          "Worker-App konnte nicht starten (#{inspect(reason)}). Läuft der Daemon auf " <>
            "demselben Mnesia-Dir? Dann per RPC prunen — siehe @moduledoc."
        )
    end
  end

  defp parse_cutoff!(nil), do: Mix.raise("--before-date <iso8601|YYYY-MM-DD> ist erforderlich")

  defp parse_cutoff!(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} ->
        dt

      _ ->
        # Nacktes Datum → Tagesanfang UTC.
        case Date.from_iso8601(str) do
          {:ok, date} ->
            DateTime.new!(date, ~T[00:00:00], "Etc/UTC")

          _ ->
            Mix.raise(
              "--before-date ungültig: #{inspect(str)} (erwartet ISO8601 oder YYYY-MM-DD)"
            )
        end
    end
  end

  defp build_prune_opts(opts) do
    [dry_run: opts[:dry_run] || false]
    |> then(fn o ->
      if opts[:campaign], do: Keyword.put(o, :campaign_id, opts[:campaign]), else: o
    end)
  end
end
