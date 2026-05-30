defmodule Worker.GpuQueue do
  @moduledoc """
  Issue #292: strikt-serielle Job-Queue für GPU/CPU-schwere Operationen
  (Whisper-Transkription, pyannote-Diarisierung, lokale Ollama-Inference).
  Genau ein laufender Job, FIFO, kein Backpressure-Limit — Worker-lokal,
  ohne Persistenz.

  ## API

  - `run(fun, opts)` — synchron: blockiert den Caller bis der Job dran war
    und zurückgegeben hat. Liefert das Funktions-Ergebnis oder, bei einem
    Crash im Job, `{:error, {:exit, reason}}` / `{:error, {exception,
    stacktrace}}`.
  - `enqueue(fun, opts)` — asynchron (`cast`): fire-and-forget. Job läuft
    irgendwann, Caller sieht das Ergebnis nicht. Crashes werden gelogged
    aber nicht propagiert.
  - `status/0` — Snapshot: `%{running: %{label, mode, started_at} | nil,
    depth: pos_integer}`.
  - `list/0` — vollständigerer Snapshot inkl. Job-IDs für UI-Mutationen.
  - `move_up/1`, `move_down/1`, `cancel/1` — Mutation der wartenden Queue
    via Job-ID (UUIDv7). Laufender Job ist NICHT mutierbar — bewusst, weil
    das Killen mitten in einer GPU-Operation Ressourcen-Leaks riskiert.

  Optionen: `label: "transcribe:<sid>"` (für Logs), Default `"anon"`.

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
    GenServer.call(@name, {:enq, :sync, fun, label}, :infinity)
  end

  @spec enqueue((-> any()), keyword()) :: :ok
  def enqueue(fun, opts \\ []) when is_function(fun, 0) do
    label = Keyword.get(opts, :label, "anon")
    GenServer.cast(@name, {:enq, :async, fun, label})
  end

  @spec status() :: %{running: map() | nil, depth: non_neg_integer()}
  def status, do: GenServer.call(@name, :status)

  @doc """
  Vollständigerer Snapshot für /admin/jobs: running + wartende Jobs (Job-ID +
  Label) in FIFO-Reihenfolge. Funs werden bewusst NICHT exposed.
  """
  @spec list() :: %{running: map() | nil, queue: [map()]}
  def list, do: GenServer.call(@name, :list)

  @doc "Tauscht einen wartenden Job mit seinem Vorgänger. No-op wenn der Job ganz oben oder nicht in der Queue ist."
  @spec move_up(String.t()) :: :ok | {:error, :not_found}
  def move_up(job_id) when is_binary(job_id),
    do: GenServer.call(@name, {:move_up, job_id})

  @doc "Tauscht einen wartenden Job mit seinem Nachfolger. No-op wenn ganz unten oder nicht vorhanden."
  @spec move_down(String.t()) :: :ok | {:error, :not_found}
  def move_down(job_id) when is_binary(job_id),
    do: GenServer.call(@name, {:move_down, job_id})

  @doc """
  Entfernt einen wartenden Job aus der Queue. Bei Sync-Jobs wird der Caller
  mit `{:error, :cancelled}` notifiziert. Returnt `{:error, :not_found}` wenn
  der Job nicht (mehr) in der Queue ist — z.B. weil er bereits läuft (der
  laufende Job ist absichtlich nicht abbrechbar).
  """
  @spec cancel(String.t()) :: :ok | {:error, :not_found}
  def cancel(job_id) when is_binary(job_id),
    do: GenServer.call(@name, {:cancel, job_id})

  # ─── GenServer ────────────────────────────────────────────────────

  @impl true
  def init(_), do: {:ok, %{queue: :queue.new(), running: nil}}

  @impl true
  def handle_call({:enq, :sync, fun, label}, from, state) do
    {:noreply, schedule(state, {make_job_id(), :sync, fun, label, from})}
  end

  def handle_call(:status, _from, %{running: r, queue: q} = s) do
    running =
      case r do
        nil -> nil
        m -> Map.take(m, [:label, :mode, :started_at])
      end

    {:reply, %{running: running, depth: :queue.len(q)}, s}
  end

  def handle_call(:list, _from, %{running: r, queue: q} = s) do
    running =
      case r do
        nil ->
          nil

        m ->
          %{
            job_id: m.job_id,
            label: m.label,
            mode: m.mode,
            started_at: m.started_at,
            duration_ms: System.monotonic_time(:millisecond) - m.started_at
          }
      end

    jobs =
      q
      |> :queue.to_list()
      |> Enum.map(fn {job_id, mode, _fun, label, _from} ->
        %{job_id: job_id, label: label, mode: mode}
      end)

    {:reply, %{running: running, queue: jobs}, s}
  end

  def handle_call({:move_up, job_id}, _from, %{queue: q} = state) do
    list = :queue.to_list(q)

    case Enum.find_index(list, fn {jid, _, _, _, _} -> jid == job_id end) do
      nil ->
        {:reply, {:error, :not_found}, state}

      0 ->
        {:reply, :ok, state}

      idx ->
        {head, [job_above, target | tail]} = Enum.split(list, idx - 1)
        new_list = head ++ [target, job_above] ++ tail
        {:reply, :ok, %{state | queue: :queue.from_list(new_list)}}
    end
  end

  def handle_call({:move_down, job_id}, _from, %{queue: q} = state) do
    list = :queue.to_list(q)

    case Enum.find_index(list, fn {jid, _, _, _, _} -> jid == job_id end) do
      nil ->
        {:reply, {:error, :not_found}, state}

      idx ->
        if idx == length(list) - 1 do
          {:reply, :ok, state}
        else
          {head, [target, job_below | tail]} = Enum.split(list, idx)
          new_list = head ++ [job_below, target] ++ tail
          {:reply, :ok, %{state | queue: :queue.from_list(new_list)}}
        end
    end
  end

  def handle_call({:cancel, job_id}, _from, %{queue: q} = state) do
    list = :queue.to_list(q)

    case Enum.split_with(list, fn {jid, _, _, _, _} -> jid == job_id end) do
      {[], _} ->
        {:reply, {:error, :not_found}, state}

      {[{_, :sync, _fun, label, from}], rest} ->
        Logger.info("GpuQueue: cancel label=#{label} mode=sync")
        GenServer.reply(from, {:error, :cancelled})
        {:reply, :ok, %{state | queue: :queue.from_list(rest)}}

      {[{_, :async, _fun, label, _}], rest} ->
        Logger.info("GpuQueue: cancel label=#{label} mode=async")
        {:reply, :ok, %{state | queue: :queue.from_list(rest)}}
    end
  end

  @impl true
  def handle_cast({:enq, :async, fun, label}, state) do
    {:noreply, schedule(state, {make_job_id(), :async, fun, label, nil})}
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

    {:noreply, next(state)}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{running: %{ref: ref, mode: mode, from: from, label: label}} = state
      ) do
    Logger.warning("GpuQueue: DOWN label=#{label} mode=#{mode} reason=#{inspect(reason)}")
    if mode == :sync, do: GenServer.reply(from, {:error, {:exit, reason}})
    {:noreply, next(state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ─── Internal ─────────────────────────────────────────────────────

  defp make_job_id, do: UUIDv7.generate()

  defp schedule(%{running: nil, queue: q} = s, job) do
    next(%{s | queue: :queue.in(job, q)})
  end

  defp schedule(%{queue: q} = s, job), do: %{s | queue: :queue.in(job, q)}

  defp next(state) do
    case :queue.out(state.queue) do
      {:empty, _} ->
        %{state | running: nil}

      {{:value, {job_id, mode, fun, label, from}}, rest} ->
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
        Logger.info("GpuQueue: start label=#{label} mode=#{mode}")

        %{
          state
          | running: %{
              job_id: job_id,
              pid: pid,
              ref: ref,
              mode: mode,
              label: label,
              from: from,
              started_at: System.monotonic_time(:millisecond)
            },
            queue: rest
        }
    end
  end

  defp unwrap({:ok, v}), do: v
  defp unwrap({:error, _} = err), do: err
end
