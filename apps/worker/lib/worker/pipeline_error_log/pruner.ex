defmodule Worker.PipelineErrorLog.Pruner do
  @moduledoc """
  Issue #605: periodischer Trim der `worker_pipeline_errors`-Tabelle.

  Mini-GenServer im Application-Tree (`Worker.Application`-children).
  Initialer Trim laeuft in `handle_continue/2` (out-of-init, damit der
  Application-Boot nicht auf Mnesia-Locks haengt), dann
  `Process.send_after`-Loop alle `:pipeline_errors_prune_interval_ms`
  (Default 1h).

  Liest das Intervall pro Lauf neu aus `Worker.Settings` — Setting-Change
  greift ab dem naechsten Tick (keine `:timer.cancel`-Akrobatik noetig).
  """

  use GenServer

  require Logger

  @default_interval_ms 3_600_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, %{timer_ref: nil}, {:continue, :initial_prune}}
  end

  @impl true
  def handle_continue(:initial_prune, state) do
    do_prune()
    {:noreply, %{state | timer_ref: schedule_next()}}
  end

  @impl true
  def handle_info(:prune, state) do
    do_prune()
    {:noreply, %{state | timer_ref: schedule_next()}}
  end

  # Restart-/Shutdown-Hygiene: laufenden Timer cancellen, damit kein
  # `:prune` an einen nachfolgenden Prozess derselben PID-Restart-Inkarnation
  # zugestellt wird. send_after an self() ist nach Crash zwar harmlos (alte
  # PID weg), aber der explizite Cancel macht das Lifecycle-Modell sauber.
  @impl true
  def terminate(_reason, %{timer_ref: ref}) when is_reference(ref) do
    Process.cancel_timer(ref)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp do_prune do
    try do
      Worker.PipelineErrorLog.prune_keep_last()
    rescue
      e ->
        Logger.warning(
          "Worker.PipelineErrorLog.Pruner: Prune-Fehler #{inspect(e)} — uebersprungen, naechster Tick laeuft trotzdem."
        )
    end
  end

  defp schedule_next do
    interval =
      Worker.Settings.get(:pipeline_errors_prune_interval_ms, @default_interval_ms)

    Process.send_after(self(), :prune, interval)
  end
end
