defmodule HubWeb.HealthControllerTest do
  @moduledoc """
  Issue #703: GET /health/recording — unauthentifiziert, liefert nur ein
  Boolean für das Deploy-Gate im Woodpecker-deploy-Step.
  """

  use HubWeb.ConnCase, async: false

  alias Hub.WorkerRegistry

  test "keine aktive Aufnahme -> active_recording: false", %{conn: conn} do
    conn = get(conn, "/health/recording")
    assert json_response(conn, 200) == %{"active_recording" => false}
  end

  test "aktive Aufnahme -> active_recording: true", %{conn: conn} do
    parent = self()
    worker_id = "w-health-#{System.unique_integer([:positive])}"

    pid =
      spawn_link(fn ->
        {:ok, _} = WorkerRegistry.track(worker_id, "admin-test")
        {:ok, _} = WorkerRegistry.add_held_session(worker_id, "sess-health")
        send(parent, :tracked)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :tracked, 2_000

    Enum.reduce_while(1..50, false, fn _, _ ->
      if WorkerRegistry.any_active_recording?() do
        {:halt, true}
      else
        Process.sleep(20)
        {:cont, false}
      end
    end)

    conn = get(conn, "/health/recording")
    assert json_response(conn, 200) == %{"active_recording" => true}

    send(pid, :stop)
  end
end
