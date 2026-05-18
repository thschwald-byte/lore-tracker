import Config

config :hub, HubWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "K8oQ5kJv2Lg7nF1qWxRtZcYmHbVpUaSdEeIfOgNhMiCjBkAlPrXsTwYzVuQnMoLi",
  watchers: [],
  live_reload: [
    patterns: [
      ~r"apps/hub/lib/hub_web/(controllers|live|components)/.*(ex|heex)$"
    ]
  ]

config :worker,
  hub_base_url: "http://localhost:4000",
  setup_port: 4080

# Mnesia is a node-singleton — hub and worker share the dev BEAM and thus
# one schema dir; they namespace tables (hub_* vs worker_*). Setting it on
# the :mnesia application env *before* OTP starts means mnesia auto-starts
# pointed at the right dir.
config :mnesia, dir: ~c"priv/mnesia/dev"

config :logger, :default_formatter, format: "[$level] $message\n"
config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
config :phoenix_live_view, debug_heex_annotations: true
