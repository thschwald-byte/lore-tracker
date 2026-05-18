defmodule Worker.Discord do
  @moduledoc """
  Nostrum-based "lore-spy" Discord bot.

  M10a scope: log in, register a `/lore status` per-guild slash command,
  reply with worker_id + hub connection state. Voice receive comes in
  M10b+ (join/leave on command) and M10c+ (Opus decode → Whisper).

  Only starts if `:worker, :discord_bot_enabled?` is true (i.e. the
  user set `DISCORD_BOT_TOKEN` in `.env`).
  """

  use Nostrum.Consumer

  require Logger

  # ─── Lifecycle events ─────────────────────────────────────────────

  def handle_event({:READY, %{user: %{username: name}, application: app}, _ws}) do
    Logger.info("Discord: logged in as #{name} (application_id=#{app.id})")
    register_commands()
    :noop
  end

  def handle_event({:INTERACTION_CREATE, interaction, _ws}) do
    case interaction.data.name do
      "lore" -> handle_lore(interaction)
      _ -> :noop
    end

    :noop
  end

  def handle_event(_), do: :noop

  # ─── /lore slash command ──────────────────────────────────────────

  defp handle_lore(interaction) do
    subcommand =
      case interaction.data.options do
        [%{name: name} | _] -> name
        _ -> nil
      end

    body = lore_response(subcommand)

    case Nostrum.Api.Interaction.create_response(interaction, %{
           type: 4,
           data: %{content: body, flags: 64}
         }) do
      {:ok, _} -> :ok
      {:error, err} -> Logger.error("Discord: interaction reply failed: #{inspect(err)}")
    end
  end

  defp lore_response("status") do
    worker_id = Worker.Repo.get_state(:worker_id) || "?"
    admin = Worker.Repo.get_state(:admin_discord_id) || "?"
    hub = Worker.Repo.get_state(:hub_base_url) || "?"
    seq = Worker.Materializer.last_applied_seq()

    """
    **LoreTracker — Worker status**
    Worker ID: `#{worker_id}`
    Admin Discord ID: `#{admin}`
    Hub: `#{hub}`
    last_applied_seq: `#{seq}`
    """
  end

  defp lore_response(_), do: "Unbekannter Sub-Command. Verfügbar: `/lore status`"

  # ─── Slash command registration ───────────────────────────────────

  defp register_commands do
    cmd = %{
      name: "lore",
      description: "LoreTracker bot commands",
      options: [
        %{
          type: 1,
          name: "status",
          description: "Show worker + hub connection state"
        }
      ]
    }

    case Application.get_env(:worker, :discord_guild_ids, []) do
      [] ->
        Logger.warning(
          "Discord: no DISCORD_GUILD_IDS configured — falling back to global slash commands (sync up to 1h)"
        )

        case Nostrum.Api.ApplicationCommand.create_global_command(cmd) do
          {:ok, _} -> Logger.info("Discord: registered global /lore")
          {:error, err} -> Logger.error("Discord: global cmd registration failed: #{inspect(err)}")
        end

      guild_ids ->
        for gid <- guild_ids do
          case Nostrum.Api.ApplicationCommand.create_guild_command(gid, cmd) do
            {:ok, _} -> Logger.info("Discord: registered /lore for guild=#{gid}")
            {:error, err} -> Logger.error("Discord: guild #{gid} cmd failed: #{inspect(err)}")
          end
        end
    end
  end
end
