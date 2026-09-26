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

    # Issue #542, Signal 4: wie ist der vorherige Lauf geendet? Nach dem
    # Mnesia-Bootstrap (braucht get/put_state), aber vor den Children —
    # ein Worker, der stirbt, meldet nichts mehr, und der Befund soll auch
    # dann im Log stehen, wenn der Start danach scheitert.
    Worker.Telemetry.melde_vorherigen_abgang()

    # #1247: der HTTP-Pool für die Modell-Aufrufe steht VOR dem Pairing-Gate.
    # Er ist Infrastruktur, nicht Feature: Er hat keine Abhängigkeit, kostet im
    # Leerlauf nichts, und ein Aufruf ohne laufenden Pool wirft
    # (`unknown registry`). Genau das ist beim ersten Anlauf passiert — drei
    # Tests, die echte HTTP-Aufrufe gegen einen lokalen Stub fahren, fielen um,
    # weil der Pool nur im gepaarten Zweig stand. Ein Rückfall auf Reqs
    # Default-Pool wäre die stillere, aber schlechtere Antwort gewesen: Dann
    # liefe ein Teil der Aufrufe wieder ohne Frist, und niemand sähe es.
    children =
      [Worker.Agent.Modell.Pool.kind()] ++
        if paired?() do
          migrate_legacy_mock_settings!()
          warn_stale_legacy_model_settings!()
          migrate_stage2_to_stage4_if_unset!()
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
            # Issue #542: die Vorfall-Zählung gehört weit nach vorn — sie soll
            # auch die Abstürze der Kinder sehen, die nach ihr starten. Der
            # Logger-Handler für Task-Abstürze hängt an ihrem `init/1`; ohne
            # laufenden Reporter verfallen Zählrufe still, ein Fehlstart hier
            # legt also nichts lahm.
            Worker.Telemetry,
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
            # Issue #1122: Gedächtnis des laufenden Durchgangs (Stufe, Einheiten,
            # Zeiten). Eigener Prozess, damit die Fortschritts-Casts einer
            # Gap-Fill-Schleife (bis zu einige hundert) sich nicht vor den
            # `run_for_session`-Call der Pipeline legen — und weil er später die
            # Koordinator-Rolle für auf mehrere Worker verteilte Batches trägt.
            Worker.Recording.Pipeline.Fortschritt,
            # J4 (#1207): die Laufsicht für Jack-Läufe der Pipeline, nur auf
            # Loopback (Tom, 11.09.2026). Ohne Port (Tests) kein Prozess; ein
            # belegter Port — ein zweiter Worker auf derselben Maschine — ist
            # eine Warnung, kein Startfehler.
            %{
              id: Worker.Jack.Sicht,
              start:
                {Worker.Jack.Sicht, :betrieb, [Application.get_env(:worker, :jack_sicht_port)]}
            },
            # #1247: die Laufsicht des Zeit-Jack, eine Stelle über der von Jack
            # (Maintainer, 19.09.2026). Eigener Prozess, eigener Port, eigener
            # Name — zwei Läufe teilen sich sonst eine Seite, und wer den einen
            # beobachtet, verliert den anderen. Dieselbe Zurückhaltung beim
            # Start: ohne Port kein Prozess, ein belegter Port ist eine Warnung.
            %{
              id: Worker.Jack.Zeit.Sicht,
              start:
                {Worker.Jack.Sicht, :betrieb,
                 [
                   Application.get_env(:worker, :zeit_sicht_port),
                   [name: Worker.Jack.Zeit.Sicht, titel: "Zeit-Laufsicht"]
                 ]}
            },
            # Issue #985 Slice 1 (Stage D): Registry + DynamicSupervisor für
            # per-Kampagne Discord-Voice-Prozesse — das ERSTE dynamische
            # Prozess-Pattern in apps/worker (alle anderen Recording-Prozesse
            # sind Singleton-GenServer mit interner State-Map). Genuin variable
            # Kardinalität (0..N Kampagnen mit aktivem Bot-Voice gleichzeitig),
            # Start/Stop on-demand — der Standard-OTP-Antwort dafür. Registry-
            # Key = Discord-Guild-ID (Integer) — das ist, was der Consumer aus
            # rohen Voice-Paketen kennt (`VoiceWSState.guild_id`), nicht die
            # interne campaign_id.
            {Registry, keys: :unique, name: Worker.Discord.Registry},
            # Issue #1259: Registry der laufenden AGENTENLÄUFE (jeder Jack, auch
            # von Hand gefahren). Der Updater fragt daran, ob er halten darf —
            # `gpu_busy?` sieht nur Jacks innerhalb der Pipeline.
            {Registry, keys: :duplicate, name: Worker.Agent.Laeufe.registry()},
            # Issue #850: Registry der laufenden Frage-Läufe, Key = Lauf-ID des
            # Hub. Ein Lauf ist ein Task; die Registry macht ihn zum Abbrechen
            # wiederauffindbar und verhindert, dass dieselbe ID zweimal läuft.
            {Registry, keys: :unique, name: Worker.Jack.Frage.Registry},
            # Issue #850: die Verläufe der offenen Frage-Gespräche (Chat-Modus).
            Worker.Jack.Frage.Gespraech,
            {DynamicSupervisor, name: Worker.Discord.BotSupervisor, strategy: :one_for_one},
            # Issue #866 (Slice F): Kuration → automatische Neuableitung
            # (Text-Identitäts-Weiche); eigener Prozess, gleiche PubSub-Quelle.
            Worker.Recording.Pipeline.Dirty,
            Worker.Recording.Recorder,
            Worker.Recording.CampaignReplay,
            # Issue #281b/#296: Sidecar-Lifecycle. Spawnt Python-FastAPI als
            # OS-Subprocess wenn venv + Script da sind; setzt die jeweilige
            # *_sidecar_url-Setting nach erfolgreichem /health-Check. Eine
            # Instanz: Diarisierung (8766, pyannote). Der NLI-Faithfulness-
            # Sidecar (8765) ist mit #1124 entfallen.
            # Fehlt ein venv, wird die Instanz graceful übersprungen.
            {Worker.Sidecar, Worker.Sidecar.diarization_spec()},
            # Issue #605: periodischer Trim der pipeline_errors-Tabelle (Keep-
            # last-N). Initial-Prune via handle_continue + Process.send_after-
            # Loop. Verhindert Mnesia-Bloat im mehrtaegigen Daemon-Lauf.
            Worker.PipelineErrorLog.Pruner,
            # Issue #1076: der Discord-Gateway-Bot hängt unter einem eigenen
            # DynamicSupervisor statt als statischer Top-Level-Child. Grund ist
            # nicht Symmetrie, sondern Schadensbegrenzung: ein Fehlstart liefert
            # hier `{:error, reason}` an den Aufrufer, statt den gesamten
            # Worker-Boot mitzureißen (#985, empirisch gefunden). Der
            # BotSupervisor daneben bleibt für die per-Kampagne-VoiceSessions —
            # zwei Lebenszyklen, zwei Supervisor.
            {DynamicSupervisor, name: Worker.Discord.GatewaySupervisor, strategy: :one_for_one},
            Worker.Discord.BotGate,
            # Issue #1218: Zwischenspeicher für den Statusendpunkt (Präsenz).
            Worker.Status.Praesenz
          ] ++ updater_child() ++ status_kind()
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

    ergebnis = Supervisor.start_link(children, strategy: :one_for_one, name: Worker.Supervisor)

    # Issue #1218: Cowboy legt die Socket-Datei erst beim Binden an — die Rechte
    # lassen sich deshalb erst setzen, wenn der Supervisor steht. Nur dann: ohne
    # Endpunkt gibt es keine Datei, und eine Warnung über eine fehlende wäre
    # Lärm (im Test lief genau das).
    Worker.Status.Endpunkt.rechte_setzen(Worker.Status.Endpunkt.pfad())

    ergebnis
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
  # Issue #1218: der lesende Statusendpunkt über einen Unix-Domain-Socket.
  # Leere Liste heißt „abgeschaltet" — der Pfad kommt aus LORE_STATUS_SOCKET
  # oder XDG_RUNTIME_DIR.
  defp status_kind, do: Worker.Status.Endpunkt.kind()

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
  # the real LLM without manual /settings intervention. Stufe 2 und 3 haben
  # seit J4 (#1207) kein Backend-Setting mehr (Stufe 5 kam erst nach dem Mock).
  defp migrate_legacy_mock_settings! do
    for stage <- [1, 4] do
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
          "Jacks Modell in /settings im Block „Jack: Extract/verify“ (model_stage2_local) setzen."
      )
    end

    # J4 (#1207): Stufe 2 ist Jack und immer lokal. Ein gespeichertes Cloud-
    # Backend für die frühere Extraktion wird nicht mehr gelesen — ohne diese
    # Zeile liefe ein bisher per Cloud extrahierender Worker still lokal.
    if v = Worker.Repo.get_state(:backend_stage2) do
      if v not in [:local, "local"] do
        Logger.warning(
          "Worker: backend_stage2=#{inspect(v)} wird ignoriert — Stufe 2 (Jack) läuft seit " <>
            "J4 immer lokal, auf model_stage2_local über local_endpoint."
        )
      end
    end

    # Issue #783 Phase 2: judge_model/render_model (Phase 1, #783) sind komplett
    # entfernt (kein Read-Pfad mehr, `LLM.put_model_override/2` ist weg). Ein
    # Bestandsworker mit persistiertem Wert bekommt hier den Hinweis statt eines
    # stillen Nichts-Passiert. Der Judge (Stufe 3) ist seit J4 ganz entfallen.
    if v = Worker.Repo.get_state(:judge_model) do
      Logger.warning(
        "Worker: stale Legacy-Setting judge_model=#{inspect(v)} wird ignoriert — " <>
          "Stufe 3 (Verify) ist seit J4 entfallen, Jack prüft seine Aussagen selbst."
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
  # hier defaultet backend_stage4 auf :local mit model_stage4_local:
  # :no_default → der Render scheitert mit :no_model_configured, obwohl der GM
  # seit dem Update nichts geändert hat (stiller Hard-Break statt eines
  # Feature-Rollouts). Einmalig beim ersten Boot nach dem Update: Stage 2
  # (Extraktion) teilte sich bis #786 EINEN Slot mit dem Render — dieser
  # Zustand wird als expliziter Startwert für Stage 4 übernommen.
  #
  # Seit J4 (#1207) fällt der Stufe-3-Teil weg (Verify entfallen), und die
  # Stufe-2-Keys stehen nicht mehr in `Worker.Settings` (weder Default noch
  # Whitelist). Gelesen wird deshalb ROH aus dem Store (`Worker.Repo.get_state/1`
  # kennt keine Whitelist, ein alter Wert liegt dort unverändert), mit den
  # damaligen Defaults als Rückfall (`@legacy_stage2`) — das Ergebnis für
  # Stufe 4 ist dasselbe wie vor J4. Gate ist jetzt `backend_stage4` (auch roh,
  # nicht `Settings.get/1`: der `:local`-Default machte „nie berührt“ und
  # „explizit :local“ ununterscheidbar). Idempotent: zweiter Boot sieht
  # `backend_stage4` gesetzt → No-op. Jeder Worker, der die Migration vor J4
  # schon hatte, trägt `backend_stage4` bereits.
  #
  # `def` statt `defp` (mit `@doc false`) — direkt testbar ohne vollen
  # App-Neustart im Test (analog anderer `@doc false`-Test-Hooks im Repo).
  @legacy_stage2 %{
    ctx_stage2: 8192,
    temperature_stage2: 0.15,
    top_p_stage2: 0.7,
    repeat_penalty_stage2: 1.1
  }
  @legacy_backends [:local, :anthropic, :openai, :google]

  @doc false
  def migrate_stage2_to_stage4_if_unset! do
    if Worker.Repo.get_state(:backend_stage4) == nil do
      backend = Worker.Repo.get_state(:backend_stage2) || :local
      model = legacy_stage2_model(backend)

      Worker.Settings.put(:backend_stage4, backend)
      if model, do: Worker.Settings.put(Worker.Settings.model_key(4, backend), model)

      for {alt, neu} <- [
            ctx_stage2: :ctx_stage4,
            temperature_stage2: :temperature_stage4,
            top_p_stage2: :top_p_stage4,
            repeat_penalty_stage2: :repeat_penalty_stage4
          ] do
        Worker.Settings.put(neu, Worker.Repo.get_state(alt) || Map.fetch!(@legacy_stage2, alt))
      end

      Logger.info(
        "Worker: Stage 4 (Resümee) erstmalig von der früheren Stage 2 übernommen " <>
          "(Verhalten unverändert) — in /settings prüfen und ggf. trennen."
      )
    end

    :ok
  end

  # Das Stufe-2-Modell des gespeicherten Backends, roh (s.o.); leer = keins.
  defp legacy_stage2_model(backend) do
    case Enum.find(@legacy_backends, &(&1 == backend or Atom.to_string(&1) == backend)) do
      nil ->
        nil

      b ->
        case Worker.Repo.get_state(:"model_stage2_#{b}") do
          m when is_binary(m) -> if String.trim(m) == "", do: nil, else: m
          _ -> nil
        end
    end
  end

  # J6 (#1210, E4): `migrate_stage4_to_stage5_if_unset!/0` ist entfernt — es
  # kopierte beim ersten Boot Stage 4 nach Stage 5 (Render-Epos). Stage 5 gibt
  # es nicht mehr, das Kapitel schreibt der Epos-Jack mit Jacks Einstellungen.

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
