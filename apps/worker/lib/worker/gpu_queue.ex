defmodule Worker.GpuQueue do
  @moduledoc """
  Issue #292: strikt-serielle Job-Queue für GPU/CPU-schwere Operationen
  (Whisper-Transkription, pyannote-Diarisierung, lokale Ollama-Inference).
  Genau ein laufender Job, kein Backpressure-Limit — Worker-lokal,
  ohne Persistenz.

  ## Lanes (Issue #355, Phase 3)

  Zwei Queues:

  - **`:live`** (high priority): `LiveTranscribe` (VAD + Whisper pro
    Tick während aktiver Aufnahme). Sub-Sekunden-Latenz, läuft immer.
  - **`:background`** (default): AudioBuffer-Transcribe, Pipeline-Stages
    2–4, Probelauf, CampaignReplay. **Pausiert während aktiver
    Aufnahme** (Issue #355) — startet erst wieder wenn alle Sessions
    auf `:completed` sind. Ein bereits laufender Background-Job läuft
    fertig (kein Preempt).

  Scheduler-Reihenfolge:
  1. `live_queue` non-empty → starte Live-Job.
  2. Sonst: `recording_active?` false UND `bg_queue` non-empty → starte
     Background-Job.
  3. Sonst: idle.

  ## API

  - `run(fun, opts)` — synchron: blockiert den Caller bis der Job dran
    war und zurückgegeben hat. Liefert das Funktions-Ergebnis oder bei
    Crash `{:error, {:exit, reason}}` / `{:error, {exception, stacktrace}}`.
  - `enqueue(fun, opts)` — asynchron (`cast`): fire-and-forget.
  - `status/0` — Snapshot: `%{running, depth, recording_active?}`.
  - `list/0` — vollständigerer Snapshot inkl. Job-IDs.
  - `move_up/1`, `move_down/1`, `cancel/1` — Mutation der wartenden
    Queues via Job-ID (UUIDv7). Funktioniert für beide Lanes; Move
    bleibt innerhalb der eigenen Lane.

  Optionen für `run`/`enqueue`:
  - `priority: :live | :background` (default `:background`).
  - `label: "transcribe:<sid>"` (für Logs), Default `"anon"`.

  Job läuft im `Worker.TaskSupervisor` mit Monitor → DOWN räumt
  `running` auf und startet den nächsten in der Queue.
  """

  use GenServer
  require Logger

  @name __MODULE__

  # ─── API ──────────────────────────────────────────────────────────

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: @name)

  @spec run((-> any()), keyword()) :: any() | {:error, term()}
  def run(fun, opts \\ []) when is_function(fun, 0) do
    label = Keyword.get(opts, :label, "anon")
    priority = Keyword.get(opts, :priority, :background)
    GenServer.call(@name, {:enq, :sync, fun, label, priority}, :infinity)
  end

  @spec enqueue((-> any()), keyword()) :: :ok
  def enqueue(fun, opts \\ []) when is_function(fun, 0) do
    label = Keyword.get(opts, :label, "anon")
    priority = Keyword.get(opts, :priority, :background)
    GenServer.cast(@name, {:enq, :async, fun, label, priority})
  end

  @spec status() :: %{
          running: map() | nil,
          live_depth: non_neg_integer(),
          bg_depth: non_neg_integer(),
          recording_active?: boolean()
        }
  def status, do: GenServer.call(@name, :status)

  @doc """
  Vollständigerer Snapshot für /admin/jobs: running + beide Queues
  (Live + Background) in FIFO-Reihenfolge.
  """
  @spec list() :: %{
          running: map() | nil,
          live_queue: [map()],
          bg_queue: [map()],
          recording_active?: boolean()
        }
  def list, do: GenServer.call(@name, :list)

  @doc "Tauscht einen wartenden Job mit seinem Vorgänger (innerhalb seiner Lane). No-op wenn ganz oben oder nicht vorhanden."
  @spec move_up(String.t()) :: :ok | {:error, :not_found}
  def move_up(job_id) when is_binary(job_id),
    do: GenServer.call(@name, {:move_up, job_id})

  @doc "Tauscht einen wartenden Job mit seinem Nachfolger (innerhalb seiner Lane)."
  @spec move_down(String.t()) :: :ok | {:error, :not_found}
  def move_down(job_id) when is_binary(job_id),
    do: GenServer.call(@name, {:move_down, job_id})

  @doc """
  Entfernt einen wartenden Job aus seiner Queue. Sync-Caller bekommt
  `{:error, :cancelled}`. Der laufende Job ist nicht abbrechbar
  (würde Inferenz-Zeit verbrennen / Subprozess-Hänger riskieren).
  """
  @spec cancel(String.t()) :: :ok | {:error, :not_found}
  def cancel(job_id) when is_binary(job_id),
    do: GenServer.call(@name, {:cancel, job_id})

  # ─── GenServer ────────────────────────────────────────────────────

  @impl true
  def init(_) do
    Phoenix.PubSub.subscribe(Worker.PubSub, "recording_state")
    active? = safe_any_active_recording?()

    {:ok,
     %{
       bg_queue: :queue.new(),
       live_queue: :queue.new(),
       running: nil,
       recording_active?: active?
     }}
  end

  @impl true
  def handle_call({:enq, :sync, fun, label, priority}, from, state) do
    {:noreply, schedule(state, {make_job_id(), :sync, fun, label, from, priority})}
  end

  def handle_call(:status, _from, state) do
    running =
      case state.running do
        nil -> nil
        m -> Map.take(m, [:label, :mode, :started_at, :priority])
      end

    {:reply,
     %{
       running: running,
       live_depth: :queue.len(state.live_queue),
       bg_depth: :queue.len(state.bg_queue),
       recording_active?: state.recording_active?
     }, state}
  end

  def handle_call(:list, _from, state) do
    running =
      case state.running do
        nil ->
          nil

        m ->
          %{
            job_id: m.job_id,
            label: m.label,
            mode: m.mode,
            priority: m.priority,
            started_at: m.started_at,
            duration_ms: System.monotonic_time(:millisecond) - m.started_at
          }
      end

    live_jobs = :queue.to_list(state.live_queue) |> Enum.map(&job_to_map/1)
    bg_jobs = :queue.to_list(state.bg_queue) |> Enum.map(&job_to_map/1)

    {:reply,
     %{
       running: running,
       live_queue: live_jobs,
       bg_queue: bg_jobs,
       recording_active?: state.recording_active?
     }, state}
  end

  def handle_call({:move_up, job_id}, _from, state) do
    case find_lane(state, job_id) do
      nil -> {:reply, {:error, :not_found}, state}
      :live -> {:reply, :ok, swap_in_lane(state, :live, job_id, -1)}
      :background -> {:reply, :ok, swap_in_lane(state, :background, job_id, -1)}
    end
  end

  def handle_call({:move_down, job_id}, _from, state) do
    case find_lane(state, job_id) do
      nil -> {:reply, {:error, :not_found}, state}
      :live -> {:reply, :ok, swap_in_lane(state, :live, job_id, +1)}
      :background -> {:reply, :ok, swap_in_lane(state, :background, job_id, +1)}
    end
  end

  def handle_call({:cancel, job_id}, _from, state) do
    case find_lane(state, job_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      lane ->
        {:reply, :ok, cancel_in_lane(state, lane, job_id)}
    end
  end

  @impl true
  def handle_cast({:enq, :async, fun, label, priority}, state) do
    {:noreply, schedule(state, {make_job_id(), :async, fun, label, nil, priority})}
  end

  @impl true
  def handle_info(
        {:job_done, pid, result},
        %{running: %{pid: pid, mode: mode, from: from, label: label, started_at: t0}} = state
      ) do
    duration_ms = System.monotonic_time(:millisecond) - t0
    Logger.info("GpuQueue: done label=#{label} mode=#{mode} duration_ms=#{duration_ms}")

    if mode == :sync, do: GenServer.reply(from, unwrap(result))

    state =
      case state.running do
        %{ref: ref} when is_reference(ref) ->
          Process.demonitor(ref, [:flush])
          state

        _ ->
          state
      end

    {:noreply, next(%{state | running: nil})}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{running: %{ref: ref, mode: mode, from: from, label: label}} = state
      ) do
    Logger.warning("GpuQueue: DOWN label=#{label} mode=#{mode} reason=#{inspect(reason)}")
    if mode == :sync, do: GenServer.reply(from, {:error, {:exit, reason}})
    {:noreply, next(%{state | running: nil})}
  end

  # Issue #355: Recording-State-Updates aus AudioBuffer-Broadcasts.
  def handle_info({:recording_state_changed, active?}, state) do
    state = %{state | recording_active?: active?}
    # Wenn Recording endet UND nichts läuft → ggf. pending Background starten.
    state = if state.running == nil, do: next(state), else: state
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ─── Internal ─────────────────────────────────────────────────────

  defp make_job_id, do: UUIDv7.generate()

  defp safe_any_active_recording? do
    try do
      Worker.Repo.any_active_recording?()
    rescue
      _ -> false
    catch
      _, _ -> false
    end
  end

  defp schedule(%{running: nil} = s, job) do
    next(enqueue_into(s, job))
  end

  defp schedule(s, job), do: enqueue_into(s, job)

  defp enqueue_into(s, {_, _, _, _, _, :live} = job),
    do: %{s | live_queue: :queue.in(job, s.live_queue)}

  defp enqueue_into(s, job),
    do: %{s | bg_queue: :queue.in(job, s.bg_queue)}

  # Scheduler-Reihenfolge: Live zuerst. Background nur wenn Recording inaktiv.
  defp next(state) do
    case :queue.out(state.live_queue) do
      {{:value, job}, rest_live} ->
        start_job(%{state | live_queue: rest_live}, job)

      {:empty, _} ->
        if state.recording_active? do
          # Background-Pause: Recording aktiv → nichts starten.
          %{state | running: nil}
        else
          case :queue.out(state.bg_queue) do
            {{:value, job}, rest_bg} -> start_job(%{state | bg_queue: rest_bg}, job)
            {:empty, _} -> %{state | running: nil}
          end
        end
    end
  end

  defp start_job(state, {job_id, mode, fun, label, from, priority}) do
    parent = self()

    {:ok, pid} =
      Task.Supervisor.start_child(Worker.TaskSupervisor, fn ->
        result =
          try do
            {:ok, fun.()}
          rescue
            e -> {:error, {e, __STACKTRACE__}}
          catch
            kind, reason -> {:error, {kind, reason}}
          end

        send(parent, {:job_done, self(), result})
      end)

    ref = Process.monitor(pid)
    Logger.info("GpuQueue: start label=#{label} mode=#{mode} priority=#{priority}")

    %{
      state
      | running: %{
          job_id: job_id,
          pid: pid,
          ref: ref,
          mode: mode,
          label: label,
          priority: priority,
          from: from,
          started_at: System.monotonic_time(:millisecond)
        }
    }
  end

  # ─── Lane-Helpers für move/cancel ────────────────────────────────

  defp find_lane(state, job_id) do
    cond do
      lane_contains?(state.live_queue, job_id) -> :live
      lane_contains?(state.bg_queue, job_id) -> :background
      true -> nil
    end
  end

  defp lane_contains?(q, job_id) do
    q |> :queue.to_list() |> Enum.any?(fn {jid, _, _, _, _, _} -> jid == job_id end)
  end

  defp swap_in_lane(state, lane, job_id, delta) do
    q = get_lane(state, lane)
    list = :queue.to_list(q)
    idx = Enum.find_index(list, fn {jid, _, _, _, _, _} -> jid == job_id end)

    cond do
      idx == nil -> state
      idx + delta < 0 -> state
      idx + delta >= length(list) -> state
      true -> set_lane(state, lane, :queue.from_list(do_swap(list, idx, idx + delta)))
    end
  end

  defp do_swap(list, i, j) when i < j do
    {head, [a, b | tail]} = Enum.split(list, i)

    cond do
      j == i + 1 -> head ++ [b, a] ++ tail
      true -> raise "do_swap supports only adjacent swaps"
    end
  end

  defp do_swap(list, i, j) when i > j, do: do_swap(list, j, i)

  defp cancel_in_lane(state, lane, job_id) do
    q = get_lane(state, lane)
    list = :queue.to_list(q)
    {to_remove, rest} = Enum.split_with(list, fn {jid, _, _, _, _, _} -> jid == job_id end)

    Enum.each(to_remove, fn
      {_, :sync, _, label, from, _prio} ->
        Logger.info("GpuQueue: cancel label=#{label} mode=sync")
        GenServer.reply(from, {:error, :cancelled})

      {_, :async, _, label, _, _prio} ->
        Logger.info("GpuQueue: cancel label=#{label} mode=async")
    end)

    set_lane(state, lane, :queue.from_list(rest))
  end

  defp get_lane(state, :live), do: state.live_queue
  defp get_lane(state, :background), do: state.bg_queue
  defp set_lane(state, :live, q), do: %{state | live_queue: q}
  defp set_lane(state, :background, q), do: %{state | bg_queue: q}

  defp job_to_map({job_id, mode, _fun, label, _from, priority}) do
    %{job_id: job_id, label: label, mode: mode, priority: priority}
  end

  defp unwrap({:ok, v}), do: v
  defp unwrap({:error, _} = err), do: err
end
