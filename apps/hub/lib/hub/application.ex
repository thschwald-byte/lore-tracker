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
      # Issue #144: ETS-backed Admin-Debug-Consent (RAM-only, Hub bleibt
      # stateless seit #164). User aktiviert "Debug-Zugriff" in den
      # Einstellungen, Admin darf solange LV-State + Permission-Matrix
      # via DebugController abrufen.
      Hub.DebugConsent,
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
