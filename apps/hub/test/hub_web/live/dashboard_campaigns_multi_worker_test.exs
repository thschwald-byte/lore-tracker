defmodule HubWeb.DashboardCampaignsMultiWorkerTest do
  @moduledoc """
  Issue #981: `DashboardLive.read_campaigns_all_workers/1` fragt ALLE
  verbundenen Worker (nicht nur die eigenen, s. Moduldoc der Funktion) parallel
  ab und vereinigt die `campaigns_for`-Antworten. Integration-Test — braucht
  voll-laufende `Hub.WorkerRegistry` (Phoenix.Tracker) + `Hub.Reader`, analog
  `Hub.ReaderTest`. Excluded by default; ausführen via
  `mix test apps/hub/test/hub_web/live/dashboard_campaigns_multi_worker_test.exs --include integration`.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias Hub.WorkerRegistry
  alias HubWeb.DashboardLive

  # Bewusst KEIN GenServer.stop(Hub.Reader) + manueller Neu-Start hier (das
  # Muster aus Hub.ReaderTest) — das kollidiert mit dem Supervisor-Restart des
  # PERMANENT-Childs und reißt bei genügend Wiederholungen die Restart-
  # Intensität des Hub.Supervisor, was auch Hub.WorkerRegistry (Sibling unter
  # :one_for_one) neu startet und dessen ETS-Tabelle unter uns wegzieht. Der
  # bereits laufende, supervisierte Hub.Reader hat für einen frischen Test
  # ohnehin ein leeres `pending` (keine vorherigen Requests) — kein Neustart
  # nötig.
  setup do
    on_exit(fn ->
      for {worker_id, _} <- WorkerRegistry.list() do
        Phoenix.Tracker.untrack(WorkerRegistry, self(), WorkerRegistry.topic(), worker_id)
      end
    end)

    :ok
  end

  # Muster aus Hub.ReaderTest: spawnt einen Fake-Worker-Prozess, der sich in
  # der Registry trackt und auf snapshot_request mit einer festen Payload
  # antwortet.
  defp spawn_worker(worker_id, applied_seq, response) do
    pid =
      spawn_link(fn ->
        Phoenix.Tracker.track(WorkerRegistry, self(), WorkerRegistry.topic(), worker_id, %{
          admin_discord_id: "admin-#{worker_id}",
          applied_seq: applied_seq,
          channel_pid: self(),
          subscribed_campaigns: MapSet.new()
        })

        receive do
          {:snapshot_request, _scope, request_id, _reader_pid} ->
            Hub.Reader.handle_response(request_id, response)
        end
      end)

    Process.sleep(50)
    pid
  end

  # Ein Worker, der nie antwortet (simuliert Timeout/Absturz) — darf die
  # anderen nicht blockieren.
  defp spawn_silent_worker(worker_id, applied_seq) do
    pid =
      spawn_link(fn ->
        Phoenix.Tracker.track(WorkerRegistry, self(), WorkerRegistry.topic(), worker_id, %{
          admin_discord_id: "admin-#{worker_id}",
          applied_seq: applied_seq,
          channel_pid: self(),
          subscribed_campaigns: MapSet.new()
        })

        receive do
          :stop -> :ok
        end
      end)

    Process.sleep(50)
    pid
  end

  test "keine Worker connected -> no_worker" do
    assert {:error, :no_worker} =
             DashboardLive.read_campaigns_all_workers(%{
               "kind" => "campaigns_for",
               "discord_id" => "did-x"
             })
  end

  test "zwei disjunkte Worker (Spieler ohne eigenen Worker, Mitglied bei zwei fremden GMs) -> Union" do
    spawn_worker("gm1-worker", 100, %{
      "campaigns" => [%{"id" => "camp-a", "name" => "Kampagne A"}],
      "users" => %{"did-x" => %{"display_name" => "X"}},
      "viewer_role" => "spieler"
    })

    spawn_worker("gm2-worker", 50, %{
      "campaigns" => [%{"id" => "camp-b", "name" => "Kampagne B"}],
      "users" => %{"did-x" => %{"display_name" => "X"}},
      "viewer_role" => "spieler"
    })

    assert {:ok, snap} =
             DashboardLive.read_campaigns_all_workers(%{
               "kind" => "campaigns_for",
               "discord_id" => "did-x"
             })

    assert Enum.map(snap["campaigns"], & &1["id"]) |> Enum.sort() == ["camp-a", "camp-b"]
  end

  test "ein Worker antwortet nicht (Timeout) -> die anderen liefern trotzdem" do
    spawn_worker("responsive", 100, %{
      "campaigns" => [%{"id" => "camp-a"}],
      "users" => %{},
      "viewer_role" => "spieler"
    })

    spawn_silent_worker("silent", 200)

    assert {:ok, snap} =
             DashboardLive.read_campaigns_all_workers(%{
               "kind" => "campaigns_for",
               "discord_id" => "did-x"
             })

    assert Enum.map(snap["campaigns"], & &1["id"]) == ["camp-a"]
  end

  test "dieselbe Campaign auf zwei synchronisierten Workern -> dedupe" do
    payload = %{
      "campaigns" => [%{"id" => "camp-shared", "name" => "Geteilt"}],
      "users" => %{},
      "viewer_role" => "spielleiter"
    }

    spawn_worker("w1", 100, payload)
    spawn_worker("w2", 50, payload)

    assert {:ok, snap} =
             DashboardLive.read_campaigns_all_workers(%{
               "kind" => "campaigns_for",
               "discord_id" => "did-x"
             })

    assert [%{"id" => "camp-shared"}] = snap["campaigns"]
  end
end
