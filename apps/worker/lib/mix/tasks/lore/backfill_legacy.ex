defmodule Mix.Tasks.Lore.BackfillLegacy do
  use Mix.Task

  @shortdoc "Schreibt Pre-Migration-Kampagnen als Events in die Sync-Logs nach (#696)"

  @moduledoc """
  Issue #696: Alt-Kampagnen aus der Zeit vor dem Event-Store existieren nur
  als materialisierter Mnesia-Zustand auf dem Besitz-Worker — der #693-Pull-Sync
  kann sie nicht replizieren. Dieser Task synthetisiert ihren Domain-Zustand
  als Events (`Worker.LegacyEventBackfill`) und wendet sie lokal an; die
  Verteilung an andere Worker übernimmt danach der normale Pull-Sync.

  ## Verwendung

      # Dry-Run (Default): listet Kandidaten + Event-Zähler, schreibt NICHTS
      LORE_MNESIA_DIR=/pfad/zur/worker-mnesia mix lore.backfill_legacy

      # Anwenden (schreibt Events in die Logs):
      LORE_MNESIA_DIR=… mix lore.backfill_legacy --apply

      # Nur bestimmte Kampagnen / Re-Run trotz vorhandenem CampaignCreated:
      LORE_MNESIA_DIR=… mix lore.backfill_legacy --campaign <id> --apply --force

  ## Achtung: laufender Daemon

  Gegen einen **laufenden** `worker_prod`-Daemon geht das NICHT (Mnesia ist
  schema-/pfad-exklusiv — der Task-BEAM kollidiert beim Schema-Lock). Den
  Daemon vorher stoppen (`systemctl --user stop lore-worker-prod`), Task
  fahren, Daemon wieder starten — beim nächsten Sync-Tick verteilen sich die
  nachgeschriebenen Events an alle anderen Worker.
  """

  alias Worker.LegacyEventBackfill, as: Backfill

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [campaign: :keep, apply: :boolean, force: :boolean]
      )

    apply? = Keyword.get(opts, :apply, false)
    force? = Keyword.get(opts, :force, false)
    explicit = Keyword.get_values(opts, :campaign)

    # Kein Setup-Browser-Popup im CLI-Kontext (Muster lore.purge_live).
    Application.put_env(:worker, :no_browser, true)

    case Application.ensure_all_started(:worker) do
      {:ok, _apps} ->
        ids = if explicit == [], do: Backfill.legacy_campaigns(), else: explicit
        execute(ids, apply?, force?)

      {:error, reason} ->
        Mix.raise(
          "Worker-App konnte nicht starten (#{inspect(reason)}). Läuft evtl. der " <>
            "Daemon auf demselben Mnesia-Dir? Erst stoppen — siehe @moduledoc."
        )
    end
  end

  defp execute([], _apply?, _force?) do
    Mix.shell().info("Keine Legacy-Kampagnen gefunden — alle CampaignCreated liegen im Log. ✅")
  end

  defp execute(ids, false, _force?) do
    Mix.shell().info("DRY-RUN (nichts wird geschrieben) — Kandidaten: #{length(ids)}\n")

    Enum.each(ids, fn cid ->
      case Backfill.plan(cid) do
        {:error, :not_found} ->
          Mix.shell().info("  #{cid}: NICHT GEFUNDEN")

        {:ok, events} ->
          migrated =
            if Backfill.migrated?(cid), do: " (schon migriert — würde geskippt)", else: ""

          Mix.shell().info("  #{cid}: #{length(events)} Events#{migrated}")

          events
          |> Enum.frequencies_by(& &1["payload"]["kind"])
          |> Enum.sort_by(fn {_k, v} -> -v end)
          |> Enum.each(fn {kind, n} -> Mix.shell().info("      #{kind}: #{n}") end)
      end
    end)

    Mix.shell().info("\nZum Schreiben: mix lore.backfill_legacy --apply")
  end

  defp execute(ids, true, force?) do
    Mix.shell().info("APPLY — #{length(ids)} Kampagne(n)…")

    Backfill.run(ids, force: force?)
    |> Enum.each(fn
      {cid, :applied, n} -> Mix.shell().info("  #{cid}: #{n} Events geschrieben ✅")
      {cid, :skipped_migrated} -> Mix.shell().info("  #{cid}: geskippt (schon migriert; --force)")
      {cid, :not_found} -> Mix.shell().info("  #{cid}: NICHT GEFUNDEN")
    end)

    Mix.shell().info(
      "\nFertig. Daemon wieder starten — der nächste Sync-Tick verteilt die Events an die Peers."
    )
  end
end
