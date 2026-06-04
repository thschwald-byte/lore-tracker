defmodule Worker.Updater do
  @moduledoc """
  Issue #492: Maintainer-Self-Update für den `worker_prod`-Daemon.

  Der Hub meldet beim (Re-)Join seine git-SHA (`Worker.HubClient.handle_join`
  → `hub_sha_seen/1`). Der Updater vergleicht sie mit der eigenen
  `Worker.Version.current().sha`. Bei Drift — und nur wenn der Worker **idle**
  ist (keine Aufnahme/Probelauf/Replay) — aktualisiert er einen **dedizierten
  Deploy-Clone** (`git checkout --detach <hub_sha>` + `mix compile`) und löst,
  nur bei erfolgreichem Compile, einen Restart via `Worker.Lifecycle.graceful_halt/0`
  aus. Ein externer Supervisor (systemd --user, Restart=always) startet den
  Worker aus dem aktualisierten Clone neu.

  **Opt-in**: läuft nur, wenn `Worker.Application` ihn startet
  (`LORE_WORKER_AUTOUPDATE=1` + `LORE_WORKER_DEPLOY_REPO`). Dev-Worker starten
  keinen Updater → keine versehentliche Manipulation lokaler Arbeitskopien.

  Sicherheit:
  - **Compile-Gating**: Restart nur bei Exit-0 von git+mix. Ein kaputter Commit
    kippt den laufenden Daemon NICHT.
  - **Idle-Gating**: nie ein Update mitten in einer Aufnahme; Re-Check beim
    Recording-Ende (PubSub `"recording_state"`) + Safety-Tick.
  - **Dirty-Guard**: ein dirty kompilierter Worker (lokale Änderungen) updatet
    nicht.
  - **Backoff** nach Fehlschlag.

  Code↔Daten getrennt: Code kommt aus dem Deploy-Clone, `LORE_MNESIA_DIR` bleibt
  konstant → Restart lädt dieselben Mnesia-Daten.
  """

  use GenServer

  require Logger

  @tick_ms 60_000
  @backoff_ms 600_000
  @recording_topic "recording_state"

  # ─── API ───────────────────────────────────────────────────────────

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Vom HubClient beim Join gerufen: die aktuelle Hub-SHA. Fire-and-forget."
  @spec hub_sha_seen(String.t()) :: :ok
  def hub_sha_seen(sha) when is_binary(sha), do: GenServer.cast(__MODULE__, {:hub_sha, sha})

  @doc false
  def updating?, do: GenServer.call(__MODULE__, :updating?)

  # ─── GenServer ─────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    deploy_repo = Keyword.fetch!(opts, :deploy_repo)
    Phoenix.PubSub.subscribe(Worker.PubSub, @recording_topic)
    Process.send_after(self(), :tick, @tick_ms)

    Logger.info("Worker.Updater: aktiv (deploy_repo=#{deploy_repo})")

    {:ok,
     %{
       deploy_repo: deploy_repo,
       target_sha: nil,
       updating?: false,
       # Issue #512: einmal gesetzt (graceful_halt ausgelöst) → der Node geht
       # runter, KEIN weiteres Update mehr starten. Verhindert den Re-Halt-Race,
       # bei dem ein zweites Drift-Event (rapid Hub-Deploys) während des Halt-
       # Fensters einen zweiten Update-/Halt-Zyklus anstößt.
       halting?: false,
       task_ref: nil,
       backoff_until: nil
     }}
  end

  @impl true
  def handle_cast({:hub_sha, sha}, state) do
    {:noreply, maybe_update(%{state | target_sha: sha})}
  end

  @impl true
  def handle_call(:updating?, _from, state), do: {:reply, state.updating?, state}

  # Recording-Ende → erneut prüfen (ein „pending" Update läuft jetzt evtl. los).
  @impl true
  def handle_info({:recording_state_changed, false}, state),
    do: {:noreply, maybe_update(state)}

  def handle_info({:recording_state_changed, _}, state), do: {:noreply, state}

  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, maybe_update(state)}
  end

  # Task-Ergebnis (Update-Sequenz abgeschlossen).
  def handle_info({ref, result}, %{task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_update(result, %{state | updating?: false, task_ref: nil})}
  end

  # Task gecrasht (vor dem Ergebnis).
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task_ref: ref} = state) do
    Logger.error("Worker.Updater: Update-Task gecrasht: #{inspect(reason)} — Backoff")
    {:noreply, %{state | updating?: false, task_ref: nil, backoff_until: backoff()}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ─── Entscheidungslogik ────────────────────────────────────────────

  @doc false
  def maybe_update(state) do
    local = Worker.Version.current()

    cond do
      # Issue #512: Node hält bereits an → nichts mehr anfassen.
      Map.get(state, :halting?) -> state
      state.updating? -> state
      is_nil(state.target_sha) -> state
      local.sha == "unknown" -> state
      state.target_sha == local.sha -> state
      # Map.get statt local.dirty?: @dirty? ist ein Compile-Time-Literal →
      # Elixir-1.19 würde den Bool als Singleton-Typ inferieren und den
      # cond-Zweig als „statisch entscheidbar" anmaulen. Map.get → dynamic().
      Map.get(local, :dirty?) -> warn_skip("dirty checkout — kein Auto-Update", state)
      in_backoff?(state) -> state
      not idle?() -> defer("busy (Aufnahme/Probelauf/Replay läuft)", state)
      true -> start_update(state, local.sha)
    end
  end

  defp start_update(state, local_sha) do
    sha = state.target_sha

    Logger.warning(
      "Worker.Updater: Drift erkannt (lokal=#{local_sha} hub=#{sha}) — Update im Deploy-Clone"
    )

    task =
      Task.Supervisor.async_nolink(Worker.TaskSupervisor, fn ->
        run_update(state.deploy_repo, sha)
      end)

    %{state | updating?: true, task_ref: task.ref}
  end

  # Restart NUR bei erfolgreichem Compile UND wenn der Worker immer noch idle ist
  # (eine Aufnahme könnte während des minutenlangen Compiles gestartet sein).
  defp finish_update({:ok, sha}, state) do
    cond do
      not idle?() ->
        Logger.info("Worker.Updater: während Compile busy geworden — Restart deferred (#{sha})")
        # target_sha bleibt; nächster Idle-Trigger versucht es erneut (Code im
        # Deploy-Clone steht schon, der nächste Lauf ist quasi instant).
        state

      true ->
        Logger.warning("Worker.Updater: Compile OK (#{sha}) — graceful halt → systemd-Restart")
        Worker.Lifecycle.graceful_halt()
        # Issue #512: ab jetzt hält der Node an — weitere Drift-Events (cast/tick/
        # recording_state) dürfen KEINEN zweiten Update-/Halt-Zyklus starten.
        %{state | halting?: true}
    end
  end

  defp finish_update({:error, step, code, out}, state) do
    Logger.error(
      "Worker.Updater: Update fehlgeschlagen bei '#{step}' (exit #{code}) — Backoff. " <>
        "Worker bleibt auf altem Code.\n#{String.slice(out, 0, 800)}"
    )

    %{state | backoff_until: backoff()}
  end

  # ─── Update-Sequenz (läuft im Task, OS-Prozess mit cwd=deploy_repo) ─

  defp run_update(repo, sha) do
    # Deploy-Clone selbstheilend machen (Reste eines vorigen Fehllaufs), dann
    # exakt auf die Hub-SHA (detached) → Worker-Code == Hub-Code, kein Skew.
    with :ok <- sh(repo, "git", ["reset", "--hard"]),
         :ok <- sh(repo, "git", ["clean", "-fd"]),
         :ok <- sh(repo, "git", ["fetch", "origin", "--quiet"]),
         :ok <- sh(repo, "git", ["checkout", "--detach", sha]),
         :ok <- sh(repo, "mix", ["deps.get"]),
         :ok <- sh(repo, "mix", ["compile"]) do
      {:ok, sha}
    end
  end

  defp sh(repo, cmd, args) do
    case System.cmd(cmd, args, cd: repo, stderr_to_stdout: true, env: [{"MIX_ENV", "dev"}]) do
      {_out, 0} -> :ok
      {out, code} -> {:error, "#{cmd} #{Enum.join(args, " ")}", code, out}
    end
  rescue
    e -> {:error, "#{cmd} (#{Exception.message(e)})", -1, ""}
  end

  # ─── Idle-Check (alle bestehenden Signale, defensiv ummantelt) ─────

  @doc false
  def idle? do
    not Worker.Repo.any_active_recording?() and
      is_nil(safe_call(Worker.Probelauf, :running)) and
      is_nil(safe_call(Worker.Recording.CampaignReplay, :running)) and
      not gpu_recording_active?()
  catch
    # Ein hängender/abgestürzter Status-GenServer → konservativ „nicht idle".
    _, _ -> false
  end

  defp gpu_recording_active? do
    case safe_call(Worker.GpuQueue, :list) do
      %{recording_active?: ra} -> ra
      _ -> false
    end
  end

  # GenServer.call mit Schutz: Timeout/Exit wird zu nil (Caller behandelt nil
  # als „nichts läuft" bzw. der idle?-catch greift).
  defp safe_call(mod, fun) do
    apply(mod, fun, [])
  catch
    :exit, _ -> :error
  end

  # ─── Helpers ───────────────────────────────────────────────────────

  defp defer(reason, state) do
    Logger.info("Worker.Updater: Update deferred — #{reason}")
    state
  end

  defp warn_skip(reason, state) do
    Logger.warning("Worker.Updater: skip — #{reason}")
    state
  end

  defp in_backoff?(%{backoff_until: nil}), do: false
  defp in_backoff?(%{backoff_until: until}), do: System.monotonic_time(:millisecond) < until
  defp backoff, do: System.monotonic_time(:millisecond) + @backoff_ms
end
