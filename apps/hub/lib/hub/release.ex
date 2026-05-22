defmodule Hub.Release do
  @moduledoc """
  Production-Release-Helper: Ecto-Migrationen automatisch beim Hub-Boot
  ausführen (Issue #125).

  Hintergrund: Mix-Releases enthalten kein Mix, also kein `mix ecto.migrate`
  zur Laufzeit. Bei Gigalixir braucht's ohne diesen Hook einen manuellen
  `gigalixir ps:migrate`-Aufruf nach jedem Deploy mit DB-Change — wenn der
  vergessen wird, crasht der Hub beim ersten Query (Postgrex `undefined_column`).

  `Hub.Application.start/2` ruft `migrate/0` für den Postgres-Backend vor
  dem App-Start. `Ecto.Migrator.with_repo/2` startet den Repo temporär,
  führt alle ausstehenden Migrationen aus und stoppt ihn — kein Konflikt
  mit dem regulären Repo-Child im Supervisor-Tree.
  """

  @app :hub

  require Logger

  @doc """
  Führt alle ausstehenden Ecto-Migrationen für alle konfigurierten Repos.
  Idempotent — bereits angewandte Migrationen werden übersprungen.
  """
  def migrate do
    load_app()

    for repo <- repos() do
      Logger.info("Hub.Release: running migrations for #{inspect(repo)}")
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
