ExUnit.start(exclude: [:postgres, :integration])

# Etappe 5b (Issue #162): keine Hub-side Tabellen mehr (cloud_keys ist weg).
# Mnesia bleibt initialisiert für die Worker-Tabellen die in den Hub-Tests
# indirekt referenziert werden (z.B. Reader/Materializer-Round-Trip).
:ok = Shared.Mnesia.ensure_started!()


# Postgres storage tests are off by default. Run with:
#
#     mix ecto.create && mix ecto.migrate && mix test --include postgres
#
# A Postgres instance must be reachable using the creds in config/test.exs
# (env-var-overridable: POSTGRES_HOST/USER/PASSWORD/DB). The Repo is started
# with Sandbox pool mode :manual so each test checks out its own connection.
# Migrations are NOT run here — Sandbox pool blocks the migrator lock; run
# them via `mix ecto.migrate` from the shell first.
included_tags = ExUnit.configuration()[:include] || []

if :postgres in included_tags do
  {:ok, _} = Hub.Repo.start_link()
  Ecto.Adapters.SQL.Sandbox.mode(Hub.Repo, :manual)
end
