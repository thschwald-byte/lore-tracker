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

config :ueberauth, Ueberauth.Strategy.Discord.OAuth,
  client_id: env!("DISCORD_CLIENT_ID", :string, nil),
  client_secret: env!("DISCORD_CLIENT_SECRET", :string, nil)

if config_env() == :prod do
  secret_key_base = env!("SECRET_KEY_BASE", :string!)
  host = env!("PHX_HOST", :string, "example.com")
  port = env!("PORT", :integer, 4000)

  config :hub, HubWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base
end
