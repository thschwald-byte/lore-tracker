defmodule Hub.Application do
  @moduledoc false
  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    Logger.info("Hub starting — version #{Hub.Version.display()}")

    # Issue #125: Auto-Migrate beim Boot für den Postgres-Backend. Ecto.Migrator
    # startet den Repo temporär und stoppt ihn nach den Migrationen, also kein
    # Konflikt mit dem regulären Repo-Child unten. Idempotent — Migrationen
    # die schon angewandt sind werden übersprungen.
    if backend() == :postgres do
      :ok = Hub.Release.migrate()
    end

    children = backend_children(backend()) ++ base_children()

    opts = [strategy: :one_for_one, name: Hub.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    HubWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp backend, do: Application.get_env(:hub, :storage_backend, :mnesia)

  defp base_children do
    [
      Hub.Vault,
      {Phoenix.PubSub, name: Hub.PubSub},
      {Hub.WorkerRegistry, []},
      Hub.Reader,
      HubWeb.Endpoint
    ]
  end

  defp backend_children(:mnesia) do
    :ok = Shared.Mnesia.ensure_started!()
    :ok = Hub.WorkerTokens.bootstrap!()
    :ok = Hub.CloudKeys.bootstrap!()
    []
  end

  defp backend_children(:postgres) do
    # Hub.Repo must be alive before the supervisor children that use it;
    # prepending it ensures it starts first.
    [Hub.Repo]
  end
end
