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

  @doc """
  Find the guild where `discord_id` is currently in voice and start
  recording the given campaign there. Used by the UI-button path so the
  caller doesn't have to specify a guild explicitly.
  """
  def start_for_owner(discord_id, campaign_id) do
    case find_voice_guild(discord_id) do
      {:ok, guild_id} -> start(guild_id, discord_id, campaign_id)
      :not_found -> {:error, :not_in_voice}
    end
  end

  @doc "Stop whichever recording is currently running for `campaign_id`."
  def stop_for_campaign(campaign_id) do
    GenServer.call(__MODULE__, {:stop_by_campaign, campaign_id}, 10_000)
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
             {:ok, session_id} <- create_and_start_session(campaign),
             :ok <- start_capture_safely(guild_id, voice_channel_id, session_id) do
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
        # Don't end the session here — Python sidecar emits SessionEnded
        # after transcription completes, so utterances land before the
        # Pipeline fires.
        leave_voice(guild_id)

        Logger.info(
          "Recorder: stopped recording guild=#{guild_id} session=#{entry.session_id}"
        )

        {:reply, {:ok, entry}, %{state | by_guild: rest}}
    end
  end

  def handle_call({:status, guild_id}, _from, state) do
    {:reply, Map.get(state.by_guild, guild_id), state}
  end

  def handle_call({:stop_by_campaign, campaign_id}, from, state) do
    case Enum.find(state.by_guild, fn {_gid, e} -> e.campaign_id == campaign_id end) do
      nil -> {:reply, {:error, :not_recording}, state}
      {guild_id, _} -> handle_call({:stop, guild_id}, from, state)
    end
  end

  # ─── Helpers ──────────────────────────────────────────────────────

  defp find_voice_guild(discord_id) do
    uid =
      case discord_id do
        i when is_integer(i) -> i
        s when is_binary(s) -> String.to_integer(s)
      end

    Nostrum.Cache.GuildCache.all()
    |> Enum.find_value(:not_found, fn guild ->
      case Enum.find(guild.voice_states, fn vs -> vs.user_id == uid end) do
        %{channel_id: cid} when not is_nil(cid) -> {:ok, guild.id}
        _ -> nil
      end
    end)
  end

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

  # Voice join lives in start_capture_safely/3 — it needs the session_id
  # which only exists after create_and_start_session/1.

  defp leave_voice(guild_id) do
    Worker.Discord.PythonVoice.leave_voice(guild_id)
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

  defp start_capture_safely(guild_id, voice_channel_id, session_id) do
    case Worker.Discord.PythonVoice.join_voice(guild_id, voice_channel_id, session_id) do
      :ok ->
        :ok

      {:error, reason} ->
        # Recording can still proceed (manual fake utterances etc.) — log + continue.
        require Logger
        Logger.warning("Recorder: PythonVoice join failed: #{inspect(reason)}")
        :ok
    end
  end
end
