defmodule Worker.Application do
  @moduledoc false
  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    Logger.info("Worker starting — version #{Worker.Version.display()}")

    bootstrap_storage!()

    children =
      if paired?() do
        migrate_legacy_mock_settings!()

        Logger.info("Worker: pairing vorhanden. Starte PubSub + Materializer + HubClient + Pipeline + Recording.")

        [
          {Phoenix.PubSub, name: Worker.PubSub},
          # Issue #233: supervisor für asynchrone Tasks (Stage-1-Transcribe etc.) —
          # ersetzt `Task.start/1` damit Crashes im Worker-Log als Stack-Trace
          # erscheinen statt silent unter `Task.start` zu verschwinden.
          {Task.Supervisor, name: Worker.TaskSupervisor},
          Worker.Materializer,
          Worker.HubClient,
          {Registry, keys: :unique, name: Worker.Recording.LiveTranscribe.Registry},
          Worker.Recording.LiveTranscribe.Supervisor,
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
          Worker.Probelauf
        ]
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
