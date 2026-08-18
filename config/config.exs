import Config

config :hub,
  # Compile-time snapshot of Mix.env() — Mix isn't available in a release,
  # so this is the only way to gate dev-only UI bits (e.g. the Listen-Modus
  # radio in /settings) at runtime in prod.
  env: Mix.env()

config :worker,
  env: Mix.env()

config :hub, HubWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: HubWeb.ErrorHTML, json: HubWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Hub.PubSub,
  live_view: [signing_salt: "loretracker-lv"]

# Issue #629: Per-IP Rate-Limit auf /pair, /invite/:token,
# /auth/discord/callback. Default :direct (kein trusted Proxy — korrekt für
# lokalen Dev + PR-Test-Stacks ohne Reverse-Proxy davor); :prod überschreibt
# auf {:trusted_proxies, N} mit dem in Issue #629 Stufe A gemessenen N.
config :hub, HubWeb.Plugs.RateLimit,
  proxy_config: :direct,
  limits: %{
    # 10/min/IP — rein maschineller Endpoint.
    pair: {10, 60_000},
    # 30/min/IP — Brute-Force-Klasse, aber User klickt evtl. mehrfach den Link.
    invite: {30, 60_000},
    # 60/min/IP — Login-Bursts nach OAuth-Redirect sind menschlich möglich.
    auth_callback: {60, 60_000}
  }

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

# Issue #985 Slice 1: KEIN `config :nostrum, :token` — das aktiviert Nostrums
# Alt-Auto-Start-Pfad und kollidiert mit der eigenen bedingten Supervision
# (Worker.Discord.BotGate startet Nostrum.Bot mit `wrapped_token` unter
# Worker.Discord.GatewaySupervisor, #1076). youtube-dl/streamlink sind
# Voice-PLAYBACK-Features, die dieser Voice-RECEIVE-Usecase nicht braucht —
# deaktiviert, sonst warnt jeder
# Worker-Boot über fehlende externe Binaries, die er nie nutzt.
config :nostrum,
  youtubedl: false,
  streamlink: false

import_config "#{config_env()}.exs"
