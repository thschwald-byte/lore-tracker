import Config

config :hub,
  generators: [timestamp_type: :utc_datetime]

config :hub, HubWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: HubWeb.ErrorHTML, json: HubWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Hub.PubSub,
  live_view: [signing_salt: "loretracker-lv"]

config :phoenix, :json_library, Jason

config :ueberauth, Ueberauth,
  providers: [
    discord: {Ueberauth.Strategy.Discord, [default_scope: "identify"]}
  ]

import_config "#{config_env()}.exs"
