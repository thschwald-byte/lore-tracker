import Config

config :hub, HubWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "K8oQ5kJv2Lg7nF1qWxRtZcYmHbVpUaSdEeIfOgNhMiCjBkAlPrXsTwYzVuQnMoLi",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:hub, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:hub, ~w(--watch)]}
  ],
  live_reload: [
    patterns: [
      ~r"apps/hub/priv/static/.*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"apps/hub/lib/hub_web/(controllers|live|components)/.*(ex|heex)$"
    ]
  ]

config :worker,
  hub_base_url: "http://localhost:4000",
  setup_port: 4080

# Hub uses Mnesia by default in dev (no Postgres dependency). To switch
# locally — e.g. to verify the Postgres adapter before deploying — set
# `LORE_STORAGE_BACKEND=postgres` in `.env` and ensure Postgres is running.
# The Repo config below is dormant unless `:storage_backend` is `:postgres`.
config :hub, Hub.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "loretracker_dev",
  pool_size: 10,
  show_sensitive_data_on_connection_error: true,
  stacktrace: true

# Mnesia is a node-singleton — a single BEAM owns a given dir. The default
# below works when hub+worker boot inside one umbrella BEAM. If you launch
# them as two separate processes, set LORE_MNESIA_DIR for the worker BEAM
# to a different absolute path (e.g. priv/mnesia/dev-worker). See
# config/runtime.exs for the actual evaluation.

config :logger, :default_formatter, format: "[$level] $message\n"
config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
config :phoenix_live_view, debug_heex_annotations: true
