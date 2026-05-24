defmodule Hub.ReaderTest do
  @moduledoc """
  Issue #146: Hub.Reader iteriert über Workers bei `forbidden`/`not_found`
  oder Timeout. Bei single-Worker-Setup keine Verhaltens-Änderung.

  Integration-Test — braucht voll-laufende `Hub.WorkerRegistry`
  (Phoenix.Tracker mit Worker-Pool). Excluded by default; ausführen via
  `mix test apps/hub/test/hub/reader_test.exs --include integration`.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias Hub.{Reader, WorkerRegistry}

  setup do
    # Frische Reader-Instanz pro Test damit pending-State sauber ist.
    case GenServer.whereis(Reader) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end

    {:ok, _pid} = Reader.start_link([])

    # WorkerRegistry leeren: alle Test-Worker-PIDs untracken indem wir
    # deren Helper-Processes killen (siehe spawn_worker/2 unten).
    on_exit(fn ->
      for {worker_id, _} <- WorkerRegistry.list() do
        Phoenix.Tracker.untrack(WorkerRegistry, self(), WorkerRegistry.topic(), worker_id)
      end
    end)

    :ok
  end

  # Helper: spawnt einen Test-Worker-Process, der auf snapshot_request
  # antwortet mit einer vorgegebenen Antwort-Sequenz.
  defp spawn_worker(worker_id, applied_seq, responses) do
    test_pid = self()

    pid =
      spawn_link(fn ->
        # Tracker.track muss aus dem Process selbst aufgerufen werden.
        Phoenix.Tracker.track(WorkerRegistry, self(), WorkerRegistry.topic(), worker_id, %{
          admin_discord_id: "admin-#{worker_id}",
          applied_seq: applied_seq,
          channel_pid: self(),
          subscribed_campaigns: MapSet.new()
        })

        worker_loop(worker_id, responses, test_pid)
      end)

    # Auf den ersten Tracker-Tick warten damit list/0 den Worker sieht.
    Process.sleep(50)
    pid
  end

  defp worker_loop(worker_id, responses, test_pid) do
    receive do
      {:snapshot_request, _scope, request_id, reader_pid} ->
        case responses do
          [] ->
            # Keine Antwort mehr — Reader läuft in Timeout.
            send(test_pid, {:no_response, worker_id, request_id})
            worker_loop(worker_id, [], test_pid)

          [{:reply, payload} | rest] ->
            Hub.Reader.handle_response(request_id, payload)
            send(test_pid, {:replied, worker_id, request_id})
            worker_loop(worker_id, rest, test_pid)

          [:silence | rest] ->
            send(test_pid, {:silent, worker_id, request_id})
            worker_loop(worker_id, rest, test_pid)
        end

      :stop ->
        :ok
    end
  end

  describe "Worker-Iteration bei retryable Responses (Issue #146)" do
    test "Single-Worker antwortet ok → Reader returnt das" do
      spawn_worker("w1", 100, [{:reply, %{"members" => []}}])

      assert {:ok, %{"members" => []}} =
               Reader.read(%{"kind" => "campaign", "id" => "c-1"}, timeout: 3_000)
    end

    test "erster Worker forbidden, zweiter ok → Reader returnt aus dem zweiten" do
      # w1 hat höchste applied_seq → wird zuerst probiert, antwortet forbidden.
      # w2 wird daraufhin probiert, antwortet ok.
      spawn_worker("w1", 200, [{:reply, %{"forbidden" => true}}])
      spawn_worker("w2", 100, [{:reply, %{"members" => [%{"id" => "vulpes"}]}}])

      assert {:ok, %{"members" => [%{"id" => "vulpes"}]}} =
               Reader.read(%{"kind" => "campaign", "id" => "c-1"}, timeout: 4_000)
    end

    test "erster Worker not_found, zweiter ok → Reader returnt aus dem zweiten" do
      spawn_worker("w1", 200, [{:reply, %{"not_found" => true}}])
      spawn_worker("w2", 100, [{:reply, %{"id" => "found"}}])

      assert {:ok, %{"id" => "found"}} =
               Reader.read(%{"kind" => "campaign", "id" => "c-1"}, timeout: 4_000)
    end

    test "alle Worker forbidden → Reader returnt forbidden (kein endloser Retry)" do
      spawn_worker("w1", 200, [{:reply, %{"forbidden" => true}}])
      spawn_worker("w2", 100, [{:reply, %{"forbidden" => true}}])
      spawn_worker("w3", 50, [{:reply, %{"forbidden" => true}}])

      assert {:ok, %{"forbidden" => true}} =
               Reader.read(%{"kind" => "campaign", "id" => "c-1"}, timeout: 6_000)
    end

    test "keine Worker connected → no_worker" do
      assert {:error, :no_worker} = Reader.read(%{"kind" => "campaign", "id" => "c-1"})
    end
  end

  describe "Pass-Through normaler Antworten" do
    test "nicht-retryable Response geht direkt an Caller" do
      spawn_worker("w1", 100, [{:reply, %{"campaign" => %{"id" => "c-1"}}}])

      assert {:ok, %{"campaign" => %{"id" => "c-1"}}} =
               Reader.read(%{"kind" => "campaign", "id" => "c-1"}, timeout: 3_000)
    end
  end
end
