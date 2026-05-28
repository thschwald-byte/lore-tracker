defmodule Worker.Recording.Recorder do
  @moduledoc """
  Per-campaign recording state tracker.

  Tracks at most one active recording per campaign:
  `%{session_id, campaign_id, campaign_name, owner_discord_id, started_at}`.
  The Hub UI REC button (via `HubClient`) calls into here. Starting emits
  `SessionScheduled` + `SessionStarted`; stopping triggers
  `Worker.Recording.AudioBuffer.finalize/1`, which transcribes per-player
  audio and then emits `SessionEnded` (so the pipeline only runs once all
  utterances are in the event log).

  Audio capture is browser-mic based (M10-BMP): each player streams their
  own mic from the Hub browser UI. This module is purely session
  bookkeeping — no audio plumbing.
  """

  use GenServer

  require Logger

  alias Worker.{Intents, Recording.AudioBuffer}

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  # ─── API (Hub UI path) ────────────────────────────────────────────

  @doc """
  Begin recording. Returns:
  - `{:ok, %{campaign_id, campaign_name, session_id, owner_discord_id, started_at}}`
  - `{:error, :already_recording, existing}`
  - `{:error, :campaign_not_found}`
  - `{:error, :not_authorized}` — caller ist nicht `:spielleiter` der Kampagne (per-Campaign-Membership, nicht abgeleitetes `owner_discord_id`)
  """
  def start_for_owner(discord_id, campaign_id, mode \\ :default) do
    GenServer.call(__MODULE__, {:start, discord_id, campaign_id, mode}, 10_000)
  end

  @doc "Stop the active recording for `campaign_id`. Returns `{:ok, info}` or `{:error, :not_recording}`."
  def stop_for_campaign(campaign_id) do
    GenServer.call(__MODULE__, {:stop, campaign_id}, 10_000)
  end

  @doc "All currently-active recordings, keyed by campaign_id."
  def list, do: GenServer.call(__MODULE__, :list)

  @doc "Get the active entry for a campaign, or nil."
  def get(campaign_id), do: GenServer.call(__MODULE__, {:get, campaign_id})

  # ─── GenServer ────────────────────────────────────────────────────

  @impl true
  def init(_), do: {:ok, %{by_campaign: %{}}}

  @impl true
  def handle_call({:start, caller_discord_id, campaign_id, mode}, _from, state) do
    if Map.has_key?(state.by_campaign, campaign_id) do
      {:reply, {:error, :already_recording, state.by_campaign[campaign_id]}, state}
    else
      with {:ok, campaign} <- resolve_campaign(campaign_id, caller_discord_id),
           {:ok, session_id} <- create_and_start_session(campaign) do
        entry = %{
          campaign_id: campaign.id,
          campaign_name: campaign.name,
          session_id: session_id,
          owner_discord_id: caller_discord_id,
          started_at: DateTime.utc_now()
        }

        case AudioBuffer.open_session(session_id, campaign.id, mode) do
          :ok ->
            Logger.info(
              "Recorder: started session=#{session_id} campaign=#{campaign.id} owner=#{caller_discord_id}"
            )

            {:reply, {:ok, entry},
             %{state | by_campaign: Map.put(state.by_campaign, campaign_id, entry)}}

          {:error, reason} = err ->
            Logger.error(
              "Recorder: AudioBuffer.open_session refused session=#{session_id} (#{inspect(reason)})"
            )

            {:reply, err, state}
        end
      else
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call({:stop, campaign_id}, _from, state) do
    case Map.pop(state.by_campaign, campaign_id) do
      {nil, _} ->
        {:reply, {:error, :not_recording}, state}

      {entry, rest} ->
        # finalize/1 is async: it closes writers, runs whisper-cli per file,
        # emits UtteranceAppended events, and finally emits SessionEnded.
        :ok = AudioBuffer.finalize(entry.session_id)

        Logger.info(
          "Recorder: stopped session=#{entry.session_id} campaign=#{campaign_id} (transcription pending)"
        )

        {:reply, {:ok, entry}, %{state | by_campaign: rest}}
    end
  end

  def handle_call(:list, _from, state), do: {:reply, state.by_campaign, state}

  def handle_call({:get, campaign_id}, _from, state),
    do: {:reply, Map.get(state.by_campaign, campaign_id), state}

  # ─── Helpers ──────────────────────────────────────────────────────

  defp resolve_campaign(campaign_id, caller_discord_id) when is_binary(campaign_id) do
    case Worker.Repo.get_campaign(campaign_id) do
      nil ->
        {:error, :campaign_not_found}

      c ->
        case Worker.Repo.campaign_role(campaign_id, caller_discord_id) do
          :spielleiter -> {:ok, c}
          _ -> {:error, :not_authorized}
        end
    end
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
        "name" => "Session #{number}",
        "scheduled_for" => nil
      })

    {:ok, _} =
      Intents.publish(%{"kind" => Shared.Events.session_started(), "id" => session_id})

    {:ok, session_id}
  end
end
