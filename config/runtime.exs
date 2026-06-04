import Config
import Dotenvy

# Read .env (+ optional .env.<env> overlay) from the repo root. dotenvy keeps
# the merged values in its own process dict — `env!/2` reads from there.
# This means we don't pollute the OS env, and we don't need fish to source the
# file before `mix phx.server`.
#
# In :prod the values come from the runtime environment (systemd unit, docker
# compose, ...); the .env files are optional then.
env_dir = Path.expand("../", __DIR__)

source!([
  Path.join(env_dir, ".env"),
  Path.join(env_dir, ".env.#{config_env()}"),
  System.get_env()
])

if env!("PHX_SERVER", :boolean, false) do
  config :hub, HubWeb.Endpoint, server: true
end

# Mnesia dir — per-BEAM. Default = `<umbrella>/priv/mnesia/<env>` so a
# single-BEAM dev setup (umbrella root `mix phx.server`) just works. To run
# hub and worker as two separate BEAMs, set LORE_MNESIA_DIR for at least
# one of them (typically the worker, e.g. priv/mnesia/dev-worker).
if config_env() != :prod do
  default_dir =
    Path.expand("../priv/mnesia/#{config_env()}", __DIR__)

  mnesia_dir = env!("LORE_MNESIA_DIR", :string, default_dir)
  File.mkdir_p!(mnesia_dir)
  config :mnesia, dir: String.to_charlist(mnesia_dir)

  # Per-BEAM worker overrides — lets you run one worker against the local
  # dev hub and a second one against a remote hub (e.g. Gigalixir prod).
  if hub_url = env!("HUB_BASE_URL", :string, nil) do
    config :worker, hub_base_url: hub_url
  end

  if setup_port = env!("LORE_WORKER_SETUP_PORT", :integer, nil) do
    config :worker, setup_port: setup_port
  end

  # Override Hub-Endpoint-Port in dev — used when running multiple hub
  # instances side-by-side (PR-test workflow). `dev.exs` hardcodes 4000 for
  # the default `mix phx.server`; PORT=4001 etc. shifts a second instance.
  if hub_port = env!("PORT", :integer, nil) do
    config :hub, HubWeb.Endpoint, http: [ip: {127, 0, 0, 1}, port: hub_port]
  end

end

config :ueberauth, Ueberauth.Strategy.Discord.OAuth,
  client_id: env!("DISCORD_CLIENT_ID", :string, nil),
  client_secret: env!("DISCORD_CLIENT_SECRET", :string, nil)

# Issue #160 (Etappe 5a): JWT-Signing-Secret für Worker-Pairing-Tokens.
# In :dev/:test optional damit Tests ohne LORE_JWT_SECRET laufen — WorkerJWT
# raised dann erst beim ersten sign_token/verify_token-Call mit verständlicher
# Message. In :prod-Block weiter unten via :string! erzwungen.
config :hub, jwt_secret: env!("LORE_JWT_SECRET", :string, nil)

# Issue #167: Default-Admin-Discord-ID für `mix lore.pr_test` (PR-Test-Setup).
# dotenvy schreibt nicht ins OS-Env, daher hier in :hub-App-Env exposen.
config :hub, local_admin_discord_id: env!("LORE_LOCAL_ADMIN_DISCORD_ID", :string, nil)

config :worker,
  whisper_bin: env!("WHISPER_BIN", :string, nil),
  whisper_model: env!("WHISPER_MODEL", :string, nil),
  whisper_lang: env!("WHISPER_LANG", :string, nil),
  whisper_vad_model: env!("WHISPER_VAD_MODEL", :string, nil),
  ffmpeg_bin: env!("FFMPEG_BIN", :string, nil),
  audio_dir: env!("LORE_AUDIO_DIR", :string, nil)

if config_env() == :prod do
  secret_key_base = env!("SECRET_KEY_BASE", :string!)
  host = env!("PHX_HOST", :string, "example.com")
  port = env!("PORT", :integer, 4000)

  # Etappe 5a/5c: Hub ist stateless. Einziges required Secret ist
  # LORE_JWT_SECRET (Pairing-JWT-Signing). DATABASE_URL/POOL_SIZE/
  # LORE_CLOAK_KEY/LORE_STORAGE_BACKEND sind seit Etappe 5c obsolet.
  config :hub, jwt_secret: env!("LORE_JWT_SECRET", :string!)

  # Issue #473: Discord-OAuth-Credentials sind in :prod required. Ohne sie
  # scheitert der Login erst zur Laufzeit (erst wenn ein User sich einloggt)
  # statt beim Boot — `:string!` erzwingt sie beim Release-Start (fail-fast).
  # In :dev/:test bleiben sie via env!(…, :string, nil) oben optional.
  config :ueberauth, Ueberauth.Strategy.Discord.OAuth,
    client_id: env!("DISCORD_CLIENT_ID", :string!),
    client_secret: env!("DISCORD_CLIENT_SECRET", :string!)

  config :hub, HubWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base,
    server: true,
    check_origin: ["https://#{host}"]
end
