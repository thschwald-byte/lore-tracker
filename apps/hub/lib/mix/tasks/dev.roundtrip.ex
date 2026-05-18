defmodule Mix.Tasks.Dev.Roundtrip do
  @moduledoc """
  M3 smoke test: boot the umbrella, fire a dummy `:smoke` event through
  `Hub.EventLog.append/2`, and observe that `Worker.Materializer` applies
  it and the registry sees the bumped `applied_seq`.

      mix dev.roundtrip

  Stops when done. All logs (HubClient join, catch-up, event_appended,
  ack_applied) print to stdout.
  """

  use Mix.Task

  @shortdoc "End-to-end M3 channel round-trip smoke test"

  @impl Mix.Task
  def run(_args) do
    cfg = Application.get_env(:hub, HubWeb.Endpoint, [])
    Application.put_env(:hub, HubWeb.Endpoint, Keyword.put(cfg, :server, true))
    Mix.Task.run("app.start")

    IO.puts("\n=== waiting 2s for HubClient to join + catch-up ===\n")
    Process.sleep(2_000)

    IO.puts("\n=== appending dummy event ===\n")

    {:ok, seq} =
      Hub.EventLog.append(
        %{"kind" => "smoke", "ts" => DateTime.utc_now() |> DateTime.to_iso8601()},
        "manual"
      )

    IO.puts("appended seq=#{seq}")

    IO.puts("\n=== waiting 500ms for materializer to apply + ack ===\n")
    Process.sleep(500)

    IO.inspect(Hub.EventLog.head(), label: "hub head")
    IO.inspect(Worker.Materializer.last_applied_seq(), label: "worker applied seq")
    IO.inspect(Hub.WorkerRegistry.list(), label: "registry entries")

    IO.puts("\n=== done ===\n")
  end
end
