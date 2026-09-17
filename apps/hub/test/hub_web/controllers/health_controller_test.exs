defmodule HubWeb.HealthControllerTest do
  @moduledoc """
  Issue #703: GET /health/recording — unauthentifiziert, liefert nur ein
  Boolean für das Deploy-Gate im Woodpecker-deploy-Step.

  **Issue #1227:** der zweite Test erzeugt genau den Zustand, dessen Abwesenheit
  der erste zusichert — und beendete den Worker bis dahin unbeaufsichtigt in
  seiner letzten Zeile. Bei einem Startwert, der den zweiten Test zuerst laufen
  lässt (CI-Lauf 1070, Startwert 576067), sah der erste deshalb eine laufende
  Aufnahme. Aufgeräumt wird jetzt über `HubWeb.TrackerAufraeumen`, das auf das
  Verschwinden aus dem Tracker wartet.
  """

  use HubWeb.ConnCase, async: false

  import HubWeb.TrackerAufraeumen, only: [raeumt_auf: 2, warte_bis: 1]

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
    raeumt_auf(pid, worker_id)

    assert warte_bis(fn -> WorkerRegistry.any_active_recording?() end),
           "die gehaltene Session kam nie im Tracker an"

    conn = get(conn, "/health/recording")
    assert json_response(conn, 200) == %{"active_recording" => true}
  end
end
