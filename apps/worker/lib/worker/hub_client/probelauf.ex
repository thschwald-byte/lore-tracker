defmodule Worker.HubClient.Probelauf do
  @moduledoc """
  Issue #585: Probelauf-Topic-Bündel aus `Worker.HubClient`.

  - `start_probelauf` — Einzellauf (Worker.Probelauf.start/1)
  - `start_probelauf_sweep` — Modell-Sweep über alle 3 Stages
  - `start_probelauf_sweep_isolated` — Stage-isolierter Sweep (Issue #262/#284)
  - `start_probelauf_sweep_isolated_param` — Temperature-Param-Sweep (Issue #289 Phase 4)

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

  def on_sweep(
        %{"discord_id" => did, "stage" => stage, "models" => models} = payload,
        socket
      )
      when is_integer(stage) and is_list(models) do
    session_set = payload["session_set"]

    Task.Supervisor.start_child(Worker.TaskSupervisor, fn ->
      case Worker.Probelauf.start_sweep(did, stage, models, session_set) do
        {:ok, sweep_id} ->
          Logger.info(
            "HubClient: UI-triggered probelauf-sweep started sweep_id=#{sweep_id} stage=#{stage} models=#{inspect(models)} session_set=#{inspect(session_set)}"
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

  # Issue #262 / #284: Stage-isolierter Sweep mit optionalem session_set.
  def on_sweep_isolated(
        %{"discord_id" => did, "stage" => stage, "models" => models} = payload,
        socket
      )
      when is_integer(stage) and is_list(models) do
    session_set = payload["session_set"]

    Task.Supervisor.start_child(Worker.TaskSupervisor, fn ->
      case Worker.Probelauf.start_sweep_isolated(did, stage, models, session_set) do
        {:ok, sweep_id} ->
          Logger.info(
            "HubClient: UI-triggered probelauf-sweep-isolated started sweep_id=#{sweep_id} stage=#{stage} models=#{inspect(models)} session_set=#{inspect(session_set)}"
          )

        {:error, {:already_running, existing}} ->
          Logger.warning(
            "HubClient: UI start_probelauf_sweep_isolated rejected — already running #{existing}"
          )

        {:error, reason} ->
          Logger.warning(
            "HubClient: UI start_probelauf_sweep_isolated rejected — #{inspect(reason)}"
          )
      end
    end)

    {:ok, socket}
  end

  # Issue #289 Phase 4: Param-Sweep über Temperature-Varianten.
  def on_sweep_isolated_param(
        %{"discord_id" => did, "stage" => stage, "temperatures" => temperatures} = payload,
        socket
      )
      when is_integer(stage) and is_list(temperatures) do
    session_set = payload["session_set"]

    Task.Supervisor.start_child(Worker.TaskSupervisor, fn ->
      case Worker.Probelauf.start_sweep_isolated_param(did, stage, temperatures, session_set) do
        {:ok, sweep_id} ->
          Logger.info(
            "HubClient: UI-triggered probelauf-sweep-isolated-param started " <>
              "sweep_id=#{sweep_id} stage=#{stage} temperatures=#{inspect(temperatures)} " <>
              "session_set=#{inspect(session_set)}"
          )

        {:error, {:already_running, existing}} ->
          Logger.warning(
            "HubClient: UI start_probelauf_sweep_isolated_param rejected — already running #{existing}"
          )

        {:error, reason} ->
          Logger.warning(
            "HubClient: UI start_probelauf_sweep_isolated_param rejected — #{inspect(reason)}"
          )
      end
    end)

    {:ok, socket}
  end
end
