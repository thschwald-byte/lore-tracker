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

  describe "GET /health/version (Issue #1224)" do
    test "nennt die Commit-SHA des laufenden Stands", %{conn: conn} do
      antwort = conn |> get("/health/version") |> json_response(200)

      assert %{"sha" => sha, "vsn" => vsn, "dirty" => dirty} = antwort
      assert is_binary(sha) and sha != ""
      assert is_binary(vsn) and vsn != ""
      assert is_boolean(dirty)

      # Der Cron-Check vergleicht per Präfix gegen `git rev-parse HEAD` — eine
      # SHA, die dort nicht passt, macht den Wächter wertlos, ohne dass etwas
      # rot wird. Deshalb hier gegen dieselbe Quelle geprüft.
      assert sha == Hub.Version.current().sha
    end

    test "liefert NUR diese drei Felder", %{conn: conn} do
      # Der Endpunkt ist unauthentifiziert und öffentlich erreichbar. Eine SHA
      # eines offenen AGPL-Repos verrät nichts; alles Weitere (Umgebung,
      # Pfade, Zählwerte) hätte dort nichts zu suchen — dieselbe Zurückhaltung
      # wie bei `/health/recording`, das bewusst nur ein Boolean liefert.
      antwort = conn |> get("/health/version") |> json_response(200)
      assert Map.keys(antwort) |> Enum.sort() == ["dirty", "sha", "vsn"]
    end

    test "braucht keine Anmeldung" do
      # Ohne die `:public_api`-Pipeline liefe der Aufruf in den Login-Redirect,
      # und der Cron-Lauf sähe HTML statt JSON — genau die Falle, die beim
      # Woodpecker-Log-Endpunkt einen halben Tag gekostet hat (CLAUDE.md).
      antwort =
        Phoenix.ConnTest.build_conn()
        |> get("/health/version")
        |> json_response(200)

      assert is_binary(antwort["sha"])
    end
  end
end
