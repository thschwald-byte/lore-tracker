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

  # ─── GenServer ────────────────────────────────────────────────────

  @impl true
  def init(_), do: {:ok, %{queue: :queue.new(), running: nil}}

  @impl true
  def handle_call({:enq, :sync, fun, label}, from, state) do
    {:noreply, schedule(state, {:sync, fun, label, from})}
  end

  def handle_call(:status, _from, %{running: r, queue: q} = s) do
    running =
      case r do
        nil -> nil
        m -> Map.take(m, [:label, :mode, :started_at])
      end

    {:reply, %{running: running, depth: :queue.len(q)}, s}
  end

  @impl true
  def handle_cast({:enq, :async, fun, label}, state) do
    {:noreply, schedule(state, {:async, fun, label, nil})}
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

  defp schedule(%{running: nil, queue: q} = s, job) do
    next(%{s | queue: :queue.in(job, q)})
  end

  defp schedule(%{queue: q} = s, job), do: %{s | queue: :queue.in(job, q)}

  defp next(state) do
    case :queue.out(state.queue) do
      {:empty, _} ->
        %{state | running: nil}

      {{:value, {mode, fun, label, from}}, rest} ->
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
