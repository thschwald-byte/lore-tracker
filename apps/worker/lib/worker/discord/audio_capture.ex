defmodule Worker.Discord.AudioCapture do
  @moduledoc """
  Holds the per-recording audio-capture state for the lore-spy bot.

  M10c.1 scope (this slice):
  - Tracks the SSRC → discord_id mapping coming from
    `:VOICE_SPEAKING_UPDATE` events.
  - Logs each `:VOICE_INCOMING_PACKET` so we see what Nostrum actually
    delivers (sequence, timestamp, opus payload size, speaker mapping).

  No OGG-writing or Whisper yet — those land in M10c.2 / M10c.3 once
  we've verified the receive plumbing produces useful packets.
  """

  use GenServer

  require Logger

  alias Nostrum.Voice

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  # ─── API ─────────────────────────────────────────────────────────

  @doc "Begin capturing audio for a recording session. Called from Recorder.start/3."
  def start_capture(guild_id, session_id) do
    GenServer.call(__MODULE__, {:start_capture, guild_id, session_id})
  end

  @doc "Stop capturing. Called from Recorder.stop/1. Returns capture stats."
  def stop_capture(guild_id) do
    GenServer.call(__MODULE__, {:stop_capture, guild_id})
  end

  def put_ssrc_mapping(ssrc, discord_id) do
    GenServer.cast(__MODULE__, {:ssrc_mapping, ssrc, discord_id})
  end

  def handle_packet(packet) do
    GenServer.cast(__MODULE__, {:packet, packet})
  end

  # ─── GenServer ────────────────────────────────────────────────────

  @impl true
  def init(_) do
    {:ok,
     %{
       # ssrc => discord_id
       ssrc_to_user: %{},
       # guild_id => %{session_id, started_at, packet_count, byte_count, ssrcs_seen}
       captures: %{}
     }}
  end

  @impl true
  def handle_call({:start_capture, guild_id, session_id}, _from, state) do
    case Voice.start_listen_async(guild_id) do
      :ok ->
        capture = %{
          session_id: session_id,
          started_at: DateTime.utc_now(),
          packet_count: 0,
          byte_count: 0,
          ssrcs_seen: MapSet.new()
        }

        Logger.info(
          "AudioCapture: started listening guild=#{guild_id} session=#{session_id}"
        )

        {:reply, :ok, %{state | captures: Map.put(state.captures, guild_id, capture)}}

      {:error, reason} ->
        Logger.error("AudioCapture: start_listen_async failed: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:stop_capture, guild_id}, _from, state) do
    case Map.pop(state.captures, guild_id) do
      {nil, _} ->
        {:reply, {:error, :not_capturing}, state}

      {capture, rest} ->
        Voice.stop_listen_async(guild_id)

        Logger.info(
          "AudioCapture: stopped guild=#{guild_id} session=#{capture.session_id} " <>
            "packets=#{capture.packet_count} bytes=#{capture.byte_count} " <>
            "speakers=#{MapSet.size(capture.ssrcs_seen)}"
        )

        {:reply, {:ok, capture}, %{state | captures: rest}}
    end
  end

  @impl true
  def handle_cast({:ssrc_mapping, ssrc, discord_id}, state) do
    {:noreply, %{state | ssrc_to_user: Map.put(state.ssrc_to_user, ssrc, discord_id)}}
  end

  def handle_cast({:packet, packet}, state) do
    ssrc = Map.get(packet, :ssrc) || Map.get(packet, "ssrc")
    payload = Map.get(packet, :opus) || Map.get(packet, :opus_packet) || <<>>
    discord_id = Map.get(state.ssrc_to_user, ssrc)

    Logger.info(
      "Voice: packet ssrc=#{ssrc} user=#{discord_id || "?"} bytes=#{byte_size(payload)}"
    )

    # Update per-guild capture stats (we don't know guild from packet directly; pick the first active capture).
    # Per-guild routing comes in M10c.2 alongside OGG writing.
    captures =
      Enum.into(state.captures, %{}, fn {gid, c} ->
        {gid,
         %{
           c
           | packet_count: c.packet_count + 1,
             byte_count: c.byte_count + byte_size(payload),
             ssrcs_seen: MapSet.put(c.ssrcs_seen, ssrc)
         }}
      end)

    {:noreply, %{state | captures: captures}}
  end
end
