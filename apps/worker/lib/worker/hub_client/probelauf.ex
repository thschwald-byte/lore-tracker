defmodule Worker.HubClient.Probelauf do
  @moduledoc """
  Issue #585: Probelauf-Topic-Bündel aus `Worker.HubClient`.

  - `start_probelauf` — Einzellauf (Worker.Probelauf.start/1)
  - `start_probelauf_sweep` — Extraktor-Modell-Sweep (seit #786 Wahrheitsbild-
    nativ, ohne Stage-Wahl — der Wahrheitsbild-Pfad hat genau einen LLM-Slot)

  Alle Trigger laufen im Supervisor-Task, weil sie länger blockieren als der
  HubClient-GenServer auf Message-Antwort warten will.
  """

  require Logger

  def on_start(%{"discord_id" => did}, socket) do
    Task.Supervisor.start_child(Worker.TaskSupervisor, fn ->
      case Worker.Probelauf.start(did) do
        {:ok, run_id} ->
          Logger.info("HubClient: UI-triggered probelauf started run_id=#{run_id}")

        {:error, {:already_running, existing}} ->
          Logger.warning("HubClient: UI start_probelauf rejected — already running #{existing}")
      end
    end)

    {:ok, socket}
  end

  def on_sweep(%{"discord_id" => did, "models" => models} = payload, socket)
      when is_list(models) do
    session_set = payload["session_set"]

    Task.Supervisor.start_child(Worker.TaskSupervisor, fn ->
      case Worker.Probelauf.start_sweep(did, models, session_set) do
        {:ok, sweep_id} ->
          Logger.info(
            "HubClient: UI-triggered probelauf-sweep started sweep_id=#{sweep_id} models=#{inspect(models)} session_set=#{inspect(session_set)}"
          )

        {:error, {:already_running, existing}} ->
          Logger.warning(
            "HubClient: UI start_probelauf_sweep rejected — already running #{existing}"
          )

        {:error, reason} ->
          Logger.warning("HubClient: UI start_probelauf_sweep rejected — #{inspect(reason)}")
      end
    end)

    {:ok, socket}
  end
end
