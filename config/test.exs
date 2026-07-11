import Config

config :hub, HubWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "K8oQ5kJv2Lg7nF1qWxRtZcYmHbVpUaSdEeIfOgNhMiCjBkAlPrXsTwYzVuQnMoLi",
  server: false

config :worker,
  hub_base_url: "http://localhost:4002",
  setup_port: 4082,
  # Issue #795: in MIX_ENV=test NIE den Setup-Browser öffnen. Jeder Boot der
  # Worker-App (jeder `mix test`/`coveralls`-Lauf) triggerte sonst den #571-
  # Convenience-Open (xdg-open → ein Browser-Tab pro Lauf) — bei wiederholten
  # Läufen ein Tab-Sturm. Der Default ist false; hier hart auf true.
  no_browser: true

config :mnesia, dir: ~c"priv/mnesia/test"

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
