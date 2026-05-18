defmodule Worker.Discord do
  @moduledoc """
  Nostrum-based "lore-spy" Discord bot.

  Slash commands (all under `/lore`):

      /lore status
      /lore record start campaign:<name>   — joins caller's voice channel,
                                             creates + starts a session
      /lore record stop                    — leaves voice channel,
                                             ends current recording

  `campaign` is autocompleted from the campaigns where the calling Discord
  user is owner. Voice receive (Opus → Whisper) lands in M10c+.

  Only starts if `:worker, :discord_bot_enabled?` is true.
  """

  use Nostrum.Consumer

  require Logger

  alias Worker.Discord.Recorder

  # ─── Lifecycle events ─────────────────────────────────────────────

  def handle_event({:READY, %{user: %{username: name}, application: app}, _ws}) do
    Logger.info("Discord: logged in as #{name} (application_id=#{app.id})")
    register_commands()
    :noop
  end

  def handle_event({:INTERACTION_CREATE, interaction, _ws}) do
    case interaction.type do
      # APPLICATION_COMMAND
      2 ->
        if interaction.data.name == "lore", do: handle_lore_command(interaction)

      # APPLICATION_COMMAND_AUTOCOMPLETE
      4 ->
        if interaction.data.name == "lore", do: handle_lore_autocomplete(interaction)

      _ ->
        :noop
    end

    :noop
  end

  # Voice receive runs in the Python sidecar (Worker.Discord.PythonVoice) —
  # Nostrum doesn't speak Discord's DAVE (E2EE) yet, so we don't subscribe
  # to voice events on the Elixir side.

  def handle_event(_), do: :noop

  # ─── /lore dispatch ───────────────────────────────────────────────

  defp handle_lore_command(interaction) do
    path = parse_path(interaction.data.options)

    case path do
      {["status"], _} ->
        reply(interaction, lore_status())

      {["record", "start"], opts} ->
        campaign_id = opts["campaign"]
        do_record_start(interaction, campaign_id)

      {["record", "stop"], _} ->
        do_record_stop(interaction)

      _ ->
        reply(interaction, "Unbekannter Sub-Command.")
    end
  end

  defp handle_lore_autocomplete(interaction) do
    path = parse_path(interaction.data.options)
    caller_id = caller_discord_id(interaction)

    case path do
      {["record", "start"], _opts} ->
        choices = autocomplete_campaigns(caller_id)
        autocomplete_reply(interaction, choices)

      _ ->
        autocomplete_reply(interaction, [])
    end
  end

  # ─── record start ─────────────────────────────────────────────────

  defp do_record_start(_interaction, nil) do
    # Should not happen because option is required; safety net.
    :noop
  end

  defp do_record_start(interaction, campaign_id) do
    guild_id = interaction.guild_id
    caller_id = caller_discord_id(interaction)

    case Recorder.start(guild_id, caller_id, campaign_id) do
      {:ok, info} ->
        reply(interaction, """
        🎙️ Aufnahme gestartet für **#{info.campaign_name}**, Session #{short(info.session_id)}.
        (Audio-Capture + Whisper landen in M10c — bis dahin bin ich im Voice-Channel, transkribiere aber noch nichts.)
        """)

      {:error, :already_recording, existing} ->
        reply(
          interaction,
          "⚠️ Es läuft schon eine Aufnahme (#{existing.campaign_name}, Session #{short(existing.session_id)}). Erst `/lore record stop`."
        )

      {:error, :not_in_voice} ->
        reply(interaction, "Du musst in einem Voice-Channel sein, damit ich beitreten kann.")

      {:error, :campaign_not_found} ->
        reply(interaction, "Kampagne nicht gefunden.")

      {:error, :not_owner} ->
        reply(interaction, "Nur der Owner der Kampagne darf die Aufnahme starten.")

      {:error, :guild_not_cached} ->
        reply(interaction, "Guild-State noch nicht synchronisiert. Kurz warten und nochmal probieren.")

      {:error, reason} ->
        reply(interaction, "Fehler beim Start: `#{inspect(reason)}`")
    end
  end

  defp do_record_stop(interaction) do
    case Recorder.stop(interaction.guild_id) do
      {:ok, info} ->
        reply(interaction, """
        ⏹️ Aufnahme beendet für **#{info.campaign_name}**, Session #{short(info.session_id)}.
        Pipeline läuft: Stage 2 (Resümee) → 3 (Epos) → 4 (Chronik).
        """)

      {:error, :nothing_to_stop} ->
        reply(interaction, "Keine laufende Aufnahme.")

      {:error, reason} ->
        reply(interaction, "Fehler beim Stop: `#{inspect(reason)}`")
    end
  end

  # ─── /lore status ────────────────────────────────────────────────

  defp lore_status do
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

  # ─── Autocomplete: owner's campaigns ─────────────────────────────

  defp autocomplete_campaigns(nil), do: []

  defp autocomplete_campaigns(caller_discord_id) do
    caller_discord_id
    |> Worker.Repo.list_campaigns_for()
    |> Enum.filter(fn c -> c.owner_discord_id == caller_discord_id end)
    |> Enum.take(25)
    |> Enum.map(fn c -> %{name: c.name, value: c.id} end)
  end

  # ─── Reply helpers ────────────────────────────────────────────────

  defp reply(interaction, content) do
    Nostrum.Api.Interaction.create_response(interaction, %{
      type: 4,
      data: %{content: content, flags: 64}
    })
  end

  defp autocomplete_reply(interaction, choices) do
    Nostrum.Api.Interaction.create_response(interaction, %{
      type: 8,
      data: %{choices: choices}
    })
  end

  # ─── Interaction helpers ──────────────────────────────────────────

  # Walk subcommand_group/subcommand chain. Returns
  # {[command_path], string_options_at_leaf}.
  defp parse_path(nil), do: {[], %{}}
  defp parse_path([]), do: {[], %{}}

  defp parse_path([%{type: type, name: name, options: subopts} | _])
       when type in [1, 2] and is_list(subopts) do
    {sub_path, leaf_opts} = parse_path(subopts)
    {[name | sub_path], leaf_opts}
  end

  defp parse_path([%{type: 1, name: name} | _]) do
    {[name], %{}}
  end

  defp parse_path(opts) when is_list(opts) do
    leaf =
      Enum.reduce(opts, %{}, fn
        %{name: n, value: v}, acc -> Map.put(acc, n, v)
        _, acc -> acc
      end)

    {[], leaf}
  end

  defp caller_discord_id(%{member: %{user: %{id: id}}}), do: to_string(id)
  defp caller_discord_id(%{user: %{id: id}}), do: to_string(id)
  defp caller_discord_id(_), do: nil

  defp short(<<a::binary-size(8), _::binary>>), do: a
  defp short(other), do: other

  # ─── Slash command registration ───────────────────────────────────

  defp register_commands do
    cmd = %{
      name: "lore",
      description: "LoreTracker bot commands",
      options: [
        %{type: 1, name: "status", description: "Show worker + hub connection state"},
        %{
          type: 2,
          name: "record",
          description: "Recording-Steuerung",
          options: [
            %{
              type: 1,
              name: "start",
              description: "Bot tritt deinem Voice-Channel bei und startet eine Session",
              options: [
                %{
                  type: 3,
                  name: "campaign",
                  description: "Welche Kampagne wird aufgenommen?",
                  required: true,
                  autocomplete: true
                }
              ]
            },
            %{type: 1, name: "stop", description: "Aufnahme beenden, Voice-Channel verlassen"}
          ]
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
