import Config

config :hub, HubWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "K8oQ5kJv2Lg7nF1qWxRtZcYmHbVpUaSdEeIfOgNhMiCjBkAlPrXsTwYzVuQnMoLi",
  server: false

config :worker,
  hub_base_url: "http://localhost:4002",
  setup_port: 4082

config :mnesia, dir: ~c"priv/mnesia/test"

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
