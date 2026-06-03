defmodule Mix.Tasks.Dev.Roundtrip do
  @moduledoc """
  M3/M4 smoke test: boot the umbrella, append a `CampaignCreated` event,
  verify the worker materialized it and we can read it back via the
  snapshot-request protocol.

      mix dev.roundtrip

  All logs print to stdout. Exits when the round-trip is done.
  """

  use Mix.Task

  # Issue #430: dieser Dev-Task bootet die ganze Umbrella (app.start) — Worker.*
  # ist zur Laufzeit da, nur zur Compile-Zeit (hub-App allein) nicht sichtbar.
  @compile {:no_warn_undefined, [Worker.Repo, Worker.Materializer]}

  @shortdoc "End-to-end smoke test through the event log and snapshot protocol"

  @impl Mix.Task
  def run(_args) do
    cfg = Application.get_env(:hub, HubWeb.Endpoint, [])
    Application.put_env(:hub, HubWeb.Endpoint, Keyword.put(cfg, :server, true))
    Mix.Task.run("app.start")

    IO.puts("\n=== waiting 2s for HubClient to join + catch-up ===\n")
    Process.sleep(2_000)

    admin_discord_id = Worker.Repo.get_state(:admin_discord_id)
    campaign_id = UUIDv7.generate()

    IO.puts("\n=== bridging CampaignCreated id=#{campaign_id} via Worker ===\n")

    :ok =
      Hub.EventBridge.publish(%{
        "kind" => Shared.Events.campaign_created(),
        "id" => campaign_id,
        "name" => "Smoke Campaign",
        "icon_url" => nil,
        "theme_blurb" => nil,
        "owner_discord_id" => admin_discord_id
      })

    IO.puts("bridge_publish dispatched")
    Process.sleep(300)

    IO.puts("\n=== Hub.Reader.read({campaigns_for, admin}) ===\n")

    case Hub.Reader.read(%{"kind" => "campaigns_for", "discord_id" => admin_discord_id}) do
      {:ok, %{"campaigns" => list}} ->
        IO.inspect(list, label: "campaigns")

      other ->
        IO.inspect(other, label: "reader result")
    end

    IO.puts("\n=== Hub.Reader.read({campaign, id, viewer=admin}) ===\n")

    case Hub.Reader.read(%{
           "kind" => "campaign",
           "id" => campaign_id,
           "viewer_discord_id" => admin_discord_id
         }) do
      {:ok, snap} -> IO.inspect(snap, label: "snapshot")
      other -> IO.inspect(other, label: "reader result")
    end

    IO.puts("\n=== state ===\n")
    IO.inspect(Worker.Materializer.last_applied_seq(), label: "worker applied seq")

    IO.puts("\n=== done ===\n")
  end
end
