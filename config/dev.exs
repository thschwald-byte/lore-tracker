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

# Mnesia is a node-singleton — a single BEAM owns a given dir. The default
# below works when hub+worker boot inside one umbrella BEAM. If you launch
# them as two separate processes, set LORE_MNESIA_DIR for the worker BEAM
# to a different absolute path (e.g. priv/mnesia/dev-worker). See
# config/runtime.exs for the actual evaluation.

config :logger, :default_formatter, format: "[$level] $message\n"

# Default to :info in dev — :debug floods the console with Phoenix
# channel/LV-mount traces and slipstream heartbeats, drowning out real
# errors. Crank back to :debug in iex via Logger.configure(level: :debug)
# when you actually need it.
config :logger, level: :info

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
config :phoenix_live_view, debug_heex_annotations: true
