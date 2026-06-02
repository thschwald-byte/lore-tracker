defmodule Mix.Tasks.Lore.PurgeLive do
  use Mix.Task

  @shortdoc "Tilgt Alt-Live-Utterances (status:live) — nur Sessions mit Batch-Pendant (#418)"

  @moduledoc """
  Einmalige Daten-Migration nach dem Live-Removal (#418): entfernt
  `status: :live`-Utterances, die neben den `confirmed`-Batch-Rows liegen
  geblieben sind. Pro Session mit live+batch wird ein `LiveUtterancesCleared`-
  Event publisht (event-sourced, replay-durabel); Sessions mit nur live-Rows
  werden zum Schutz vor Datenverlust übersprungen + geloggt.

  ## Verwendung

      LORE_MNESIA_DIR=/pfad/zur/worker-mnesia mix lore.purge_live

  Startet den Worker (gegen das via `LORE_MNESIA_DIR` gewählte Mnesia-Dir) und
  ruft `Worker.Maintenance.purge_live/0`.

  ## Achtung: laufender Daemon

  Gegen einen **laufenden** `worker_prod`-Daemon geht das NICHT (Mnesia ist
  schema-/pfad-exklusiv — der Task-BEAM kollidiert beim Schema-Lock). Dort
  stattdessen per RPC in den Daemon:

      :rpc.call(:"worker_prod@<host>", Worker.Maintenance, :purge_live, [])
  """

  @impl Mix.Task
  def run(_args) do
    # Kein Setup-Browser-Popup im CLI-Kontext.
    Application.put_env(:worker, :no_browser, true)

    case Application.ensure_all_started(:worker) do
      {:ok, _apps} ->
        result = Worker.Maintenance.purge_live()

        Mix.shell().info(
          "purge_live: #{result.cleared_utterances} live-Utterance(s) in " <>
            "#{result.cleared_sessions} Session(s) getilgt, " <>
            "#{result.orphan_sessions} orphan-Session(s) übersprungen."
        )

      {:error, reason} ->
        Mix.raise(
          "Worker-App konnte nicht starten (#{inspect(reason)}). Läuft evtl. der " <>
            "Daemon auf demselben Mnesia-Dir? Dann purge_live per RPC fahren — siehe @moduledoc."
        )
    end
  end
end
