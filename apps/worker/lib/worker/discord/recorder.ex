defmodule Worker.Discord.Recorder do
  @moduledoc """
  Per-guild recording state for the lore-spy Discord bot.

  Tracks at most one active recording per Discord guild:
  `{campaign_id, session_id, voice_channel_id}`. Slash-command handlers
  route through `start/3` and `stop/1`; both emit the corresponding
  domain events (`SessionScheduled`+`SessionStarted` or `SessionEnded`),
  which then flow through the normal hub log → materializer →
  pipeline path.

  Voice receive (Opus decoding, per-speaker buffering, Whisper) lands
  in M10c — for now the bot just joins the voice channel and creates
  the session; transcription comes from the existing
  `mix lore.fake_session` stub until M10c lands.
  """

  use GenServer

  require Logger

  alias Worker.Intents

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc """
  Begin recording. Returns:
  - `{:ok, %{campaign: c, session_id: id, voice_channel_id: vid}}`
  - `{:error, :already_recording, existing}`
  - `{:error, :not_in_voice}` if the caller isn't in a voice channel
  - `{:error, :campaign_not_found}`
  - `{:error, :not_owner}`
  """
  def start(guild_id, caller_discord_id, campaign_id) do
    GenServer.call(__MODULE__, {:start, guild_id, caller_discord_id, campaign_id}, 10_000)
  end

  @doc "End recording. Returns `:ok` or `{:error, :nothing_to_stop}`."
  def stop(guild_id) do
    GenServer.call(__MODULE__, {:stop, guild_id}, 10_000)
  end

  def status(guild_id) do
    GenServer.call(__MODULE__, {:status, guild_id})
  end

  # ─── GenServer ────────────────────────────────────────────────────

  @impl true
  def init(_), do: {:ok, %{by_guild: %{}}}

  @impl true
  def handle_call({:start, guild_id, caller, campaign_id}, _from, state) do
    cond do
      Map.has_key?(state.by_guild, guild_id) ->
        {:reply, {:error, :already_recording, state.by_guild[guild_id]}, state}

      true ->
        with {:ok, voice_channel_id} <- voice_channel_for(guild_id, caller),
             {:ok, campaign} <- resolve_campaign(campaign_id, caller),
             :ok <- join_voice(guild_id, voice_channel_id),
             {:ok, session_id} <- create_and_start_session(campaign),
             :ok <- start_capture_safely(guild_id, session_id) do
          entry = %{
            campaign_id: campaign.id,
            campaign_name: campaign.name,
            session_id: session_id,
            voice_channel_id: voice_channel_id,
            started_at: DateTime.utc_now()
          }

          Logger.info(
            "Recorder: started recording guild=#{guild_id} campaign=#{campaign.id} session=#{session_id}"
          )

          {:reply, {:ok, entry}, %{state | by_guild: Map.put(state.by_guild, guild_id, entry)}}
        else
          {:error, reason} ->
            {:reply, {:error, reason}, state}

          {:error, reason, extra} ->
            {:reply, {:error, reason, extra}, state}
        end
    end
  end

  def handle_call({:stop, guild_id}, _from, state) do
    case Map.pop(state.by_guild, guild_id) do
      {nil, _} ->
        {:reply, {:error, :nothing_to_stop}, state}

      {entry, rest} ->
        _ = Worker.Discord.AudioCapture.stop_capture(guild_id)
        leave_voice(guild_id)
        end_session(entry.session_id)

        Logger.info(
          "Recorder: stopped recording guild=#{guild_id} session=#{entry.session_id}"
        )

        {:reply, {:ok, entry}, %{state | by_guild: rest}}
    end
  end

  def handle_call({:status, guild_id}, _from, state) do
    {:reply, Map.get(state.by_guild, guild_id), state}
  end

  # ─── Helpers ──────────────────────────────────────────────────────

  defp voice_channel_for(guild_id, discord_id) do
    case Nostrum.Cache.GuildCache.get(guild_id) do
      {:ok, %{voice_states: states}} ->
        # Discord ids are integers in Nostrum's cache
        uid =
          case discord_id do
            i when is_integer(i) -> i
            s when is_binary(s) -> String.to_integer(s)
          end

        case Enum.find(states, fn vs -> vs.user_id == uid end) do
          %{channel_id: nil} -> {:error, :not_in_voice}
          %{channel_id: cid} -> {:ok, cid}
          nil -> {:error, :not_in_voice}
        end

      _ ->
        {:error, :guild_not_cached}
    end
  end

  defp resolve_campaign(campaign_id, caller_discord_id) when is_binary(campaign_id) do
    case Worker.Repo.get_campaign(campaign_id) do
      nil ->
        {:error, :campaign_not_found}

      %{owner_discord_id: owner} = c when owner == caller_discord_id ->
        {:ok, c}

      _ ->
        {:error, :not_owner}
    end
  end

  defp join_voice(guild_id, voice_channel_id) do
    case Nostrum.Voice.join_channel(guild_id, voice_channel_id) do
      :ok -> :ok
      {:error, reason} -> {:error, {:voice_join_failed, reason}}
    end
  end

  defp leave_voice(guild_id) do
    Nostrum.Voice.leave_channel(guild_id)
  end

  defp create_and_start_session(campaign) do
    session_id = UUIDv7.generate()
    number = Worker.Repo.next_session_number(campaign.id)

    {:ok, _} =
      Intents.publish(%{
        "kind" => Shared.Events.session_scheduled(),
        "id" => session_id,
        "campaign_id" => campaign.id,
        "number" => number,
        "name" => "Session #{number} (lore-spy)",
        "scheduled_for" => nil
      })

    {:ok, _} =
      Intents.publish(%{"kind" => Shared.Events.session_started(), "id" => session_id})

    {:ok, session_id}
  end

  defp end_session(session_id) do
    {:ok, _} =
      Intents.publish(%{"kind" => Shared.Events.session_ended(), "id" => session_id})

    :ok
  end

  defp start_capture_safely(guild_id, session_id) do
    case Worker.Discord.AudioCapture.start_capture(guild_id, session_id) do
      :ok ->
        :ok

      {:error, reason} ->
        # Recording can still proceed (manual fake utterances etc.) — log + continue.
        require Logger
        Logger.warning("Recorder: audio capture not started: #{inspect(reason)}")
        :ok
    end
  end
end
