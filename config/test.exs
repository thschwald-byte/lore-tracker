import Config

config :hub, HubWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "K8oQ5kJv2Lg7nF1qWxRtZcYmHbVpUaSdEeIfOgNhMiCjBkAlPrXsTwYzVuQnMoLi",
  server: false

config :worker,
  hub_base_url: "http://localhost:4002",
  setup_port: 4082

config :mnesia, dir: ~c"priv/mnesia/test"

# Hub.Repo for the Postgres adapter tests. Opted-in via `--include postgres`
# tag; ignored otherwise. Pool defaults to Sandbox so tests run isolated.
config :hub, Hub.Repo,
  username: System.get_env("POSTGRES_USER", "postgres"),
  password: System.get_env("POSTGRES_PASSWORD", "postgres"),
  hostname: System.get_env("POSTGRES_HOST", "localhost"),
  database: System.get_env("POSTGRES_DB", "loretracker_test"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
