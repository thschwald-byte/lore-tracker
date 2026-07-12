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
        warn_stale_legacy_model_settings!()
        migrate_stage2_to_stage34_if_unset!()
        migrate_stage4_to_stage5_if_unset!()
        heal_campaign_stores_best_effort!()

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

  # Issue #718: fehlende Campaign-Stores beim Boot heilen (Crash zwischen
  # Membership-Apply und Schema-Op hinterlässt sonst dauerhaft eine Campaign
  # ohne Event-Store — der spätere Join-Pull hätte kein Ziel). Best-effort:
  # ein Heal-Fehler darf den Boot nicht verhindern (der Worker ist ohne
  # Heilung immerhin so kaputt wie vorher, aber online). Orphans werden nur
  # geloggt, nie automatisch gedroppt.
  defp heal_campaign_stores_best_effort! do
    %{healed: healed, orphans: orphans} = Worker.Maintenance.heal_campaign_stores()

    if healed > 0 or orphans > 0 do
      Logger.info("Worker-Boot: campaign_stores heal=#{healed} orphans=#{orphans}")
    end

    :ok
  rescue
    e ->
      Logger.error("Worker-Boot: heal_campaign_stores fehlgeschlagen: #{Exception.message(e)}")
      :ok
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

  # Issue #784: die Legacy-`model_stage{n}`-Keys sind entfernt (weder Default
  # noch schreibbar). Ein Bestandsworker kann noch einen persistierten Legacy-
  # Wert im worker_state halten — der wird jetzt IGNORIERT (model_for/2 liest nur
  # pro-Backend-Keys). Statt fail-loud mitten in der Extraktion die Konsequenz
  # beim Boot sichtbar machen. Keine Auto-Migration (kein Settings-Migrations-
  # mechanismus; Ein-Klick-Neusetzen in /settings ist billiger). Seit #786 nur
  # noch n=2 — die stage3/4-Slots existieren nicht mehr (stale Rows dazu sind
  # komplett tot, eine Warnung mit Neu-Setzen-Hinweis wäre falsch).
  defp warn_stale_legacy_model_settings! do
    if v = Worker.Repo.get_state(:model_stage2) do
      Logger.warning(
        "Worker: stale Legacy-Setting model_stage2=#{inspect(v)} wird ignoriert — " <>
          "Modell in /settings per-Backend (model_stage2_<backend>) neu setzen."
      )
    end

    # Issue #783 Phase 2: judge_model/render_model (Phase 1, #783) sind durch
    # die volle Stage-3/4-Trennung (backend_stage3/4 + model_stage{3,4}_<backend>)
    # ersetzt und komplett entfernt (kein Read-Pfad mehr, `LLM.put_model_override/2`
    # ist weg). Ein Bestandsworker mit persistiertem Wert bekommt hier den Hinweis
    # statt eines stillen Nichts-Passiert.
    if v = Worker.Repo.get_state(:judge_model) do
      Logger.warning(
        "Worker: stale Legacy-Setting judge_model=#{inspect(v)} wird ignoriert — " <>
          "ersetzt durch backend_stage3 + model_stage3_<backend> in /settings."
      )
    end

    if v = Worker.Repo.get_state(:render_model) do
      Logger.warning(
        "Worker: stale Legacy-Setting render_model=#{inspect(v)} wird ignoriert — " <>
          "ersetzt durch backend_stage4 + model_stage4_<backend> in /settings."
      )
    end

    :ok
  end

  # Issue #783 Phase 2 (Design F): Migrationspfad für Bestandsworker. Ohne das
  # hier defaulten backend_stage3/4 auf :local mit model_stage{3,4}_local:
  # :no_default → Verify/Render scheitern mit :no_model_configured, obwohl der
  # GM seit dem Update nichts geändert hat (stiller Hard-Break statt eines
  # Feature-Rollouts). Einmalig beim ersten Boot nach dem Update: Stage 2
  # (Extraktion) teilte sich bis hierhin EINEN Slot mit Verify/Render (#786) —
  # dieser Zustand wird als expliziter Startwert für die neu getrennten Stage
  # 3/4 übernommen (heutiges Verhalten bleibt unverändert, GM kann danach in
  # /settings trennen).
  #
  # Gate ist ein ROHER Store-Read (nicht `Settings.get/1`) — der würde durch
  # den `:local`-Default "Stage 3 nie berührt" und "Stage 3 explizit auf
  # :local gesetzt" ununterscheidbar machen. Idempotent: zweiter Boot sieht
  # `backend_stage3` bereits gesetzt (egal auf welchen Wert) → No-op.
  #
  # `def` statt `defp` (mit `@doc false`) — direkt testbar ohne vollen
  # App-Neustart im Test (analog anderer `@doc false`-Test-Hooks im Repo).
  @doc false
  def migrate_stage2_to_stage34_if_unset! do
    if Worker.Repo.get_state(:backend_stage3) == nil do
      backend = Worker.Settings.get(:backend_stage2, :local)
      model = Worker.Settings.model_for(2, backend)
      ctx = Worker.Settings.get(:ctx_stage2, 8192)
      temperature = Worker.Settings.get(:temperature_stage2)
      top_p = Worker.Settings.get(:top_p_stage2)
      repeat_penalty = Worker.Settings.get(:repeat_penalty_stage2)

      for n <- [3, 4] do
        Worker.Settings.put(:"backend_stage#{n}", backend)
        if model, do: Worker.Settings.put(Worker.Settings.model_key(n, backend), model)
        Worker.Settings.put(:"ctx_stage#{n}", ctx)
        Worker.Settings.put(:"temperature_stage#{n}", temperature)
        Worker.Settings.put(:"top_p_stage#{n}", top_p)
        Worker.Settings.put(:"repeat_penalty_stage#{n}", repeat_penalty)
      end

      Logger.info(
        "Worker: Stage 3/4 erstmalig von Stage 2 übernommen (Verhalten unverändert) — " <>
          "in /settings prüfen und ggf. trennen."
      )
    end

    :ok
  end

  # Issue #783 Phase 2, Nachtrag (Tom-Feedback auf der Teststage: Resümee und
  # Epos sollen eigene Modelle bekommen): Migrationspfad für Bestandsworker,
  # analog `migrate_stage2_to_stage34_if_unset!/0`. Resümee (Stage 4) und
  # Epos-Kapitel (Stage 5) teilten sich bis hierhin einen Slot (Stage 4) —
  # ohne diese Migration würde ein Bestandsworker nach dem Update mit
  # `:no_model_configured` auf dem Epos-Render brechen, obwohl der GM nichts
  # geändert hat. Gate ist wieder ein ROHER Store-Read von `backend_stage5`
  # (nicht `Settings.get/1`, aus demselben Grund wie oben). Idempotent.
  @doc false
  def migrate_stage4_to_stage5_if_unset! do
    if Worker.Repo.get_state(:backend_stage5) == nil do
      backend = Worker.Settings.get(:backend_stage4, :local)
      model = Worker.Settings.model_for(4, backend)
      ctx = Worker.Settings.get(:ctx_stage4, 8192)
      temperature = Worker.Settings.get(:temperature_stage4)
      top_p = Worker.Settings.get(:top_p_stage4)
      repeat_penalty = Worker.Settings.get(:repeat_penalty_stage4)

      Worker.Settings.put(:backend_stage5, backend)
      if model, do: Worker.Settings.put(Worker.Settings.model_key(5, backend), model)
      Worker.Settings.put(:ctx_stage5, ctx)
      Worker.Settings.put(:temperature_stage5, temperature)
      Worker.Settings.put(:top_p_stage5, top_p)
      Worker.Settings.put(:repeat_penalty_stage5, repeat_penalty)

      Logger.info(
        "Worker: Stage 5 (Epos) erstmalig von Stage 4 (Resümee) übernommen " <>
          "(Verhalten unverändert) — in /settings prüfen und ggf. trennen."
      )
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
