defmodule Hub.Application do
  @moduledoc false
  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    Logger.info("Hub starting — version #{Hub.Version.display()}")

    children = [
      {Phoenix.PubSub, name: Hub.PubSub},
      # Issue #238: strukturierte Telemetry-Log-Lines für gigalixir logs |
      # grep + zukünftiges Log-Drain-Archiv. Stateless — registriert nur
      # :telemetry-Handlers im start_link/1.
      Hub.Telemetry,
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
end
