import Config

config :hub,
  generators: [timestamp_type: :utc_datetime],
  ecto_repos: [Hub.Repo],
  # Storage adapter for the Hub's event-log + worker-tokens. Mnesia (default,
  # file-backed) for local dev; Postgres for container hosts like Gigalixir
  # — set in config/runtime.exs prod block.
  storage_backend: :mnesia

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

config :esbuild,
  version: "0.21.5",
  hub: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../apps/hub/assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

config :tailwind,
  version: "3.4.3",
  hub: [
    args:
      ~w(--config=tailwind.config.js --input=css/app.css --output=../priv/static/assets/app.css),
    cd: Path.expand("../apps/hub/assets", __DIR__)
  ]

config :ueberauth, Ueberauth,
  providers: [
    discord: {Ueberauth.Strategy.Discord, [default_scope: "identify"]}
  ]

import_config "#{config_env()}.exs"
