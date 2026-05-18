defmodule Hub.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    bootstrap_storage!()

    children = [
      {Phoenix.PubSub, name: Hub.PubSub},
      {Hub.WorkerRegistry, []},
      Hub.Reader,
      HubWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Hub.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    HubWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp bootstrap_storage! do
    :ok = Shared.Mnesia.ensure_started!()
    :ok = Hub.WorkerTokens.bootstrap!()
    :ok = Hub.EventLog.bootstrap!()
  end
end
