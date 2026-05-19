defmodule Hub.Commands do
  @moduledoc """
  Hub-side helpers for non-event commands (channel pushes that don't change
  domain state and aren't replicated to other workers).

  Currently only `:shutdown_worker`. Lease/regenerate commands for the LLM
  pipeline (M8) land here too.
  """

  alias Hub.WorkerRegistry

  @spec shutdown_worker(String.t()) :: :ok | {:error, :worker_offline}
  def shutdown_worker(worker_id) when is_binary(worker_id) do
    case Enum.find(WorkerRegistry.list(), fn {id, _} -> id == worker_id end) do
      nil ->
        {:error, :worker_offline}

      {_id, %{channel_pid: pid}} ->
        send(pid, :shutdown_worker)
        :ok
    end
  end

  @doc """
  Shut down every connected worker whose admin Discord-ID matches `discord_id`.
  Returns the number of workers signalled.
  """
  @spec shutdown_my_workers(String.t()) :: non_neg_integer()
  def shutdown_my_workers(discord_id) when is_binary(discord_id) do
    WorkerRegistry.list()
    |> Enum.filter(fn {_id, meta} -> meta.admin_discord_id == discord_id end)
    |> Enum.map(fn {_id, %{channel_pid: pid}} -> send(pid, :shutdown_worker) end)
    |> length()
  end

  @doc """
  Push a settings update to every connected worker whose admin Discord-ID
  matches `discord_id`. `kv` is a map of `Worker.Settings`-key → value.
  Returns the number of workers signalled.
  """
  @spec update_my_worker_settings(String.t(), map()) :: non_neg_integer()
  def update_my_worker_settings(discord_id, kv) when is_binary(discord_id) and is_map(kv) do
    WorkerRegistry.list()
    |> Enum.filter(fn {_id, meta} -> meta.admin_discord_id == discord_id end)
    |> Enum.map(fn {_id, %{channel_pid: pid}} -> send(pid, {:update_settings, kv}) end)
    |> length()
  end

  @doc """
  Same as `update_my_worker_settings/2` but to every connected worker
  regardless of admin. Used by the dev `/dev/settings` endpoint.
  """
  @spec update_all_worker_settings(map()) :: non_neg_integer()
  def update_all_worker_settings(kv) when is_map(kv) do
    WorkerRegistry.list()
    |> Enum.map(fn {_id, %{channel_pid: pid}} -> send(pid, {:update_settings, kv}) end)
    |> length()
  end

  @doc """
  Ask the owner-worker for `discord_id` to start recording the given
  campaign. Worker creates the session and opens an `AudioBuffer` for it;
  per-player audio then arrives via `forward_audio_chunk/3`.
  """
  @spec request_recording_start(String.t(), String.t()) :: non_neg_integer()
  def request_recording_start(discord_id, campaign_id) do
    WorkerRegistry.list()
    |> Enum.filter(fn {_id, meta} -> meta.admin_discord_id == discord_id end)
    |> Enum.map(fn {_id, %{channel_pid: pid}} ->
      send(pid, {:start_recording, discord_id, campaign_id})
    end)
    |> length()
  end

  @doc """
  Ask every owner-worker to stop the recording for `campaign_id`.
  Workers that aren't recording that campaign just no-op.
  """
  @spec request_recording_stop(String.t(), String.t()) :: non_neg_integer()
  def request_recording_stop(discord_id, campaign_id) do
    WorkerRegistry.list()
    |> Enum.filter(fn {_id, meta} -> meta.admin_discord_id == discord_id end)
    |> Enum.map(fn {_id, %{channel_pid: pid}} ->
      send(pid, {:stop_recording, campaign_id})
    end)
    |> length()
  end

  @doc """
  Forward a single MediaRecorder audio chunk from a player's browser to
  every connected owner-worker. `owner_discord_id` is the campaign owner
  (the worker registered under that admin holds the AudioBuffer);
  `sender_discord_id` is the player whose mic produced the chunk.
  Returns the number of workers the chunk was pushed to.
  """
  @spec forward_audio_chunk(String.t(), String.t(), String.t(), String.t()) :: non_neg_integer()
  def forward_audio_chunk(owner_discord_id, session_id, sender_discord_id, chunk_b64)
      when is_binary(owner_discord_id) and is_binary(session_id) and
             is_binary(sender_discord_id) and is_binary(chunk_b64) do
    WorkerRegistry.list()
    |> Enum.filter(fn {_id, meta} -> meta.admin_discord_id == owner_discord_id end)
    |> Enum.map(fn {_id, %{channel_pid: pid}} ->
      send(pid, {:audio_chunk, session_id, sender_discord_id, chunk_b64})
    end)
    |> length()
  end
end
