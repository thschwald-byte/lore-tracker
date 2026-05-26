defmodule Hub.WorkerRegistryModelsTest do
  @moduledoc """
  Issue #50: WorkerRegistry.report_models/2 schreibt die Liste der lokal
  installierten Ollama-Modelle eines Workers als MapSet ins Tracker-Meta.
  Settings-LV liest das via `WorkerRegistry.list()` und aggregiert für das
  Multi-Worker-Union-Badge.
  """

  use ExUnit.Case, async: false

  alias Hub.WorkerRegistry

  defp models_of(worker_id) do
    case Enum.find(WorkerRegistry.list(), fn {id, _} -> id == worker_id end) do
      {_id, meta} -> Map.get(meta, :models_available, MapSet.new())
      nil -> nil
    end
  end

  test "report_models/2 schreibt Modell-Liste als MapSet ins Meta" do
    parent = self()
    worker_id = "w-models-test-#{System.unique_integer([:positive])}"

    pid =
      spawn_link(fn ->
        {:ok, _} = WorkerRegistry.track(worker_id, "admin-test")
        {:ok, _} = WorkerRegistry.report_models(worker_id, ["qwen2.5:7b", "mistral-nemo:12b"])
        send(parent, :reported)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :reported, 2_000

    # Polling — Tracker.update ist async.
    Enum.reduce_while(1..50, nil, fn _, _ ->
      case models_of(worker_id) do
        %MapSet{} = ms ->
          if MapSet.size(ms) == 2, do: {:halt, ms}, else: {:cont, ms}

        _ ->
          Process.sleep(20)
          {:cont, nil}
      end
    end)

    models = models_of(worker_id)
    assert MapSet.member?(models, "qwen2.5:7b")
    assert MapSet.member?(models, "mistral-nemo:12b")
    refute MapSet.member?(models, "phi3")

    send(pid, :stop)
  end

  test "report_models/2 überschreibt vorherige Liste (idempotent statt merge)" do
    parent = self()
    worker_id = "w-models-overwrite-#{System.unique_integer([:positive])}"

    pid =
      spawn_link(fn ->
        {:ok, _} = WorkerRegistry.track(worker_id, "admin-test")
        {:ok, _} = WorkerRegistry.report_models(worker_id, ["alt-modell"])
        Process.sleep(50)
        {:ok, _} = WorkerRegistry.report_models(worker_id, ["neu-modell-1", "neu-modell-2"])
        send(parent, :reported)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :reported, 2_000

    Enum.reduce_while(1..50, nil, fn _, _ ->
      case models_of(worker_id) do
        %MapSet{} = ms ->
          if MapSet.member?(ms, "neu-modell-1"), do: {:halt, ms}, else: {:cont, ms}

        _ ->
          Process.sleep(20)
          {:cont, nil}
      end
    end)

    models = models_of(worker_id)
    assert MapSet.member?(models, "neu-modell-1")
    assert MapSet.member?(models, "neu-modell-2")

    refute MapSet.member?(models, "alt-modell"),
           "alte Liste muss durch zweiten Push komplett überschrieben sein"

    send(pid, :stop)
  end

  test "report_models/2 mit leerer Liste (Ollama offline)" do
    parent = self()
    worker_id = "w-models-empty-#{System.unique_integer([:positive])}"

    pid =
      spawn_link(fn ->
        {:ok, _} = WorkerRegistry.track(worker_id, "admin-test")
        {:ok, _} = WorkerRegistry.report_models(worker_id, [])
        send(parent, :reported)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :reported, 2_000

    # Auch leere Liste muss als MapSet im Meta landen (nicht crashen, nicht :undefined)
    Enum.reduce_while(1..50, nil, fn _, _ ->
      case models_of(worker_id) do
        %MapSet{} = ms ->
          {:halt, ms}

        _ ->
          Process.sleep(20)
          {:cont, nil}
      end
    end)

    assert MapSet.new() == models_of(worker_id)

    send(pid, :stop)
  end
end
