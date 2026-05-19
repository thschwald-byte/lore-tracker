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

  # Allow a local override for the Hub storage adapter without editing
  # config files. `LORE_STORAGE_BACKEND=postgres` flips to the Postgres
  # adapter and assumes Postgres is up. If DATABASE_URL is set we use it
  # (CI uses this); otherwise dev.exs creds apply for plain local Postgres.
  case env!("LORE_STORAGE_BACKEND", :string, nil) do
    "postgres" ->
      config :hub, storage_backend: :postgres

      if database_url = env!("DATABASE_URL", :string, nil) do
        config :hub, Hub.Repo,
          url: database_url,
          pool_size: env!("POOL_SIZE", :integer, 10)
      end

    "mnesia" ->
      config :hub, storage_backend: :mnesia

    nil ->
      :ok
  end
end

config :ueberauth, Ueberauth.Strategy.Discord.OAuth,
  client_id: env!("DISCORD_CLIENT_ID", :string, nil),
  client_secret: env!("DISCORD_CLIENT_SECRET", :string, nil)

# Nostrum (lore-spy bot). The token enables the bot at all; if absent,
# Worker.Discord falls back to "disabled" and never starts a connection.
# Guild IDs are comma-separated; per-guild slash commands sync instantly
# (global commands take up to an hour, useless for dev).
discord_bot_token = env!("DISCORD_BOT_TOKEN", :string, nil)

discord_guild_ids =
  env!("DISCORD_GUILD_IDS", :string, "")
  |> String.split(",", trim: true)
  |> Enum.map(&String.to_integer/1)

config :nostrum,
  token: discord_bot_token || "missing",
  gateway_intents: [
    :guilds,
    :guild_messages,
    :guild_voice_states,
    :message_content
  ]

config :worker,
  discord_bot_enabled?: is_binary(discord_bot_token),
  discord_guild_ids: discord_guild_ids,
  whisper_bin: env!("WHISPER_BIN", :string, nil),
  whisper_model: env!("WHISPER_MODEL", :string, nil),
  whisper_lang: env!("WHISPER_LANG", :string, nil),
  ffmpeg_bin: env!("FFMPEG_BIN", :string, nil),
  audio_dir: env!("LORE_AUDIO_DIR", :string, nil)

if config_env() == :prod do
  secret_key_base = env!("SECRET_KEY_BASE", :string!)
  host = env!("PHX_HOST", :string, "example.com")
  port = env!("PORT", :integer, 4000)
  database_url = env!("DATABASE_URL", :string!)
  pool_size = env!("POOL_SIZE", :integer, 10)

  config :hub,
    storage_backend: :postgres

  config :hub, Hub.Repo,
    url: database_url,
    pool_size: pool_size,
    ssl: env!("PGSSL", :boolean, true),
    socket_options:
      if(env!("ECTO_IPV6", :boolean, false), do: [:inet6], else: [])

  config :hub, HubWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base,
    server: true,
    check_origin: ["https://#{host}"]
end
