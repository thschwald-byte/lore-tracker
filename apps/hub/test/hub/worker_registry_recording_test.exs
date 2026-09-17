defmodule Hub.WorkerRegistryRecordingTest do
  @moduledoc """
  Issue #703: WorkerRegistry.any_active_recording?/0 — Deploy-Gate-Signal.
  Nutzt dasselbe held_sessions-Tracking wie #468, keine neue State-Quelle.

  **Issue #1227: das Aufräumen wartet auf den Endzustand.** Vorher endete jeder
  Test direkt nach `send(pid, :stop)`, ohne auf etwas zu warten — die Regel und
  ihre Begründung stehen in `HubWeb.TrackerAufraeumen`.
  """

  use ExUnit.Case, async: false

  import HubWeb.TrackerAufraeumen, only: [raeumt_auf: 2, gelistet?: 1, warte_bis: 1]

  alias Hub.WorkerRegistry

  defp track_and_hold(worker_id, session_id) do
    parent = self()

    pid =
      spawn_link(fn ->
        {:ok, _} = WorkerRegistry.track(worker_id, "admin-test")

        if session_id do
          {:ok, _} = WorkerRegistry.add_held_session(worker_id, session_id)
        end

        send(parent, :tracked)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :tracked, 2_000
    raeumt_auf(pid, worker_id)
  end

  test "kein Worker verbunden -> false" do
    refute WorkerRegistry.any_active_recording?()
  end

  test "Worker verbunden, aber ohne held_sessions -> false" do
    worker_id = "w-rec-empty-#{System.unique_integer([:positive])}"
    track_and_hold(worker_id, nil)

    assert warte_bis(fn -> gelistet?(worker_id) end), "Worker wurde nie getrackt"

    refute WorkerRegistry.any_active_recording?()
  end

  test "ein Worker hält eine Session -> true" do
    worker_id = "w-rec-holds-#{System.unique_integer([:positive])}"
    track_and_hold(worker_id, "sess-1")

    assert warte_bis(fn -> WorkerRegistry.any_active_recording?() end),
           "die gehaltene Session kam nie im Tracker an"
  end

  test "mehrere Worker, nur einer hält eine Session -> true" do
    idle_id = "w-rec-idle-#{System.unique_integer([:positive])}"
    holder_id = "w-rec-holder-#{System.unique_integer([:positive])}"

    track_and_hold(idle_id, nil)
    track_and_hold(holder_id, "sess-2")

    assert warte_bis(fn ->
             Enum.any?(WorkerRegistry.list(), fn {id, meta} ->
               id == holder_id and MapSet.size(Map.get(meta, :held_sessions, MapSet.new())) > 0
             end)
           end),
           "die gehaltene Session kam nie im Tracker an"

    assert WorkerRegistry.any_active_recording?()
  end
end
