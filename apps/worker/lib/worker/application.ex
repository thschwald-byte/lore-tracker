defmodule Worker.Application do
  @moduledoc false
  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    Logger.info("Worker starting — version #{Worker.Version.display()}")

    bootstrap_storage!()

    # Issue #500: Boot-Crash-Rollback. NACH dem Mnesia-Bootstrap (für get/put_state)
    # und VOR den crash-gefährdeten Children. Bootet eine frisch self-updatete SHA
    # wiederholt nicht durch, rollt das hier auf die letzte gute SHA zurück + hält
    # den Node (kehrt dann nicht zurück). Nur für den Auto-Update-Daemon.
    maybe_boot_guard!()

    children =
      if paired?() do
        migrate_legacy_mock_settings!()

        Logger.info(
          "Worker: pairing vorhanden. Starte PubSub + Materializer + HubClient + Pipeline + Recording."
        )

        [
          # Issue #512: systemd-Watchdog ganz vorne — pingt WATCHDOG=1, solange
          # der Worker-Tree lebt. Stoppt die App (Self-Update-Zombie), stirbt der
          # Pinger → systemd killt + restartet den BEAM. No-op (`:ignore`) ohne
          # systemd-Notify-Env (Dev-/PR-Test-Worker).
          Worker.SystemdWatchdog,
          {Phoenix.PubSub, name: Worker.PubSub},
          # Issue #233: supervisor für asynchrone Tasks (Stage-1-Transcribe etc.) —
          # ersetzt `Task.start/1` damit Crashes im Worker-Log als Stack-Trace
          # erscheinen statt silent unter `Task.start` zu verschwinden.
          {Task.Supervisor, name: Worker.TaskSupervisor},
          # Issue #292: strikt-serielle GPU/CPU-Queue. AudioBuffer + Pipeline
          # routen ihre schweren Jobs durch dieses GenServer, damit Whisper,
          # pyannote-Diarisierung und Ollama-Inference sich nicht mehr
          # gegenseitig die GPU/VRAM zerschießen.
          Worker.GpuQueue,
          Worker.Materializer,
          Worker.HubClient,
          Worker.Recording.AudioBuffer,
          Worker.Recording.Pipeline,
          Worker.Recording.Recorder,
          Worker.Recording.CampaignReplay,
          # Issue #281b/#296: Sidecar-Lifecycle. Spawnt Python-FastAPI als
          # OS-Subprocess wenn venv + Script da sind; setzt die jeweilige
          # *_sidecar_url-Setting nach erfolgreichem /health-Check. Zwei
          # Instanzen: NLI-Faithfulness (8765) + Diarisierung (8766, pyannote).
          # Fehlt ein venv, wird die Instanz graceful übersprungen.
          {Worker.Sidecar, Worker.Sidecar.faithfulness_spec()},
          {Worker.Sidecar, Worker.Sidecar.diarization_spec()},
          Worker.Probelauf,
          # Issue #289 Phase 3: Self-Correction Loop. Beobachtet
          # format_notes pro Stage und senkt temperature_stageN
          # automatisch wenn die Fehlerrate über dem Threshold liegt.
          Worker.FormatCorrector,
          # Issue #605: periodischer Trim der pipeline_errors-Tabelle (Keep-
          # last-N). Initial-Prune via handle_continue + Process.send_after-
          # Loop. Verhindert Mnesia-Bloat im mehrtaegigen Daemon-Lauf.
          Worker.PipelineErrorLog.Pruner
        ] ++ updater_child()
      else
        no_browser = Application.get_env(:worker, :no_browser, false)

        Logger.info(
          "Worker: kein Pairing vorhanden. Starte Setup-Endpoint auf localhost:#{setup_port()}." <>
            if(no_browser, do: "", else: " Öffne Browser.")
        )

        unless no_browser do
          open_browser_async("http://127.0.0.1:#{setup_port()}/setup")
        end

        [{Worker.Setup.Endpoint, port: setup_port()}]
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: Worker.Supervisor)
  end

  defp bootstrap_storage! do
    :ok = Shared.Mnesia.ensure_started!()
    :ok = Worker.Schema.Mnesia.bootstrap!()
  end

  # Issue #492: Maintainer-Self-Update. Opt-in über Env — nur der `worker_prod`-
  # Daemon (mit gesetzten Vars) startet den Updater. Dev-Worker (ohne Env)
  # bekommen keinen → kein versehentliches Auto-Update lokaler Arbeitskopien.
  defp updater_child do
    if System.get_env("LORE_WORKER_AUTOUPDATE") == "1" do
      case System.get_env("LORE_WORKER_DEPLOY_REPO") do
        repo when is_binary(repo) and repo != "" ->
          [{Worker.Updater, deploy_repo: repo}]

        _ ->
          Logger.error(
            "Worker: LORE_WORKER_AUTOUPDATE=1, aber LORE_WORKER_DEPLOY_REPO fehlt/leer — " <>
              "Updater NICHT gestartet (kein Deploy-Clone-Pfad)."
          )

          []
      end
    else
      []
    end
  end

  # Issue #500: Boot-Crash-Rollback nur für den Auto-Update-Daemon (gleiche Env-
  # Bedingung wie der Updater). Dev-Worker rollen ihre Arbeitskopie nie zurück.
  defp maybe_boot_guard! do
    with "1" <- System.get_env("LORE_WORKER_AUTOUPDATE"),
         repo when is_binary(repo) and repo != "" <- System.get_env("LORE_WORKER_DEPLOY_REPO") do
      Worker.Updater.boot_guard(repo)
    else
      _ -> :ok
    end
  end

  defp paired? do
    case Worker.Repo.get_state(:hub_token) do
      nil -> false
      _ -> true
    end
  end

  # One-shot migration: the Mock backend has been removed; any persisted
  # `:mock` per-stage setting becomes :local so the pipeline runs against
  # the real LLM without manual /settings intervention.
  defp migrate_legacy_mock_settings! do
    for stage <- 1..4 do
      key = String.to_atom("backend_stage#{stage}")

      if Worker.Repo.get_state(key) == :mock do
        Logger.info("Worker: migrating legacy #{key} = :mock → :local")
        :ok = Worker.Repo.put_state(key, :local)
      end
    end

    :ok
  end

  defp setup_port, do: Application.fetch_env!(:worker, :setup_port)

  defp open_browser_async(url) do
    # Issue #571: Bewusstes fire-and-forget — wenn der Browser nicht auf-
    # geht (System.cmd-Crash, xdg-open weg), soll der Worker trotzdem
    # bootstrappen. Logger.warning unten fängt den No-Opener-Fall ab; ein
    # nachgelagerter cmd-Crash betrifft nur den Convenience-Pfad.
    # credo:disable-for-next-line LoreTracker.Credo.Check.UnsupervisedTaskStart
    Task.start(fn ->
      # Give Cowboy a moment to bind the port before we open the browser.
      Process.sleep(500)

      opener =
        cond do
          System.find_executable("xdg-open") -> "xdg-open"
          System.find_executable("open") -> "open"
          true -> nil
        end

      case opener do
        nil ->
          Logger.warning(
            "Konnte keinen Browser-Opener finden (xdg-open/open). Bitte manuell öffnen: #{url}"
          )

        cmd ->
          System.cmd(cmd, [url], stderr_to_stdout: true)
      end
    end)
  end
end
