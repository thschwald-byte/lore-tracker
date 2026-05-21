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
  Ask **one** owner-worker (deterministic pick) to start recording the
  campaign. Was previously a fan-out to every admin-worker — that created
  duplicate sessions when the admin had >1 worker connected, with one
  worker accepting audio chunks and the others dropping them as "unknown
  session". Now a single recording leader handles the whole flow.
  """
  @spec request_recording_start(String.t(), String.t()) :: non_neg_integer()
  def request_recording_start(discord_id, campaign_id) do
    case pick_leader(discord_id) do
      nil ->
        0

      {_id, %{channel_pid: pid}} ->
        send(pid, {:start_recording, discord_id, campaign_id})
        1
    end
  end

  @spec request_recording_stop(String.t(), String.t()) :: non_neg_integer()
  def request_recording_stop(discord_id, campaign_id) do
    case pick_leader(discord_id) do
      nil ->
        0

      {_id, %{channel_pid: pid}} ->
        send(pid, {:stop_recording, campaign_id})
        1
    end
  end

  @doc """
  Ask the owner-worker of `discord_id` to start an LLM-Probelauf (Issue #74).
  Returns 1 wenn ein Worker das Signal bekommen hat, 0 wenn keiner
  verbunden ist.
  """
  @spec request_probelauf_start(String.t()) :: non_neg_integer()
  def request_probelauf_start(discord_id) when is_binary(discord_id) do
    case pick_leader(discord_id) do
      nil ->
        0

      {_id, %{channel_pid: pid}} ->
        send(pid, {:start_probelauf, discord_id})
        1
    end
  end

  @doc """
  Ask the owner-worker of `discord_id` to start an LLM-Probelauf-Sweep
  (Issue #88, Phase 2a). Variiert genau eine Stage durch eine Liste von
  Modellen — pro Modell ein voller Probelauf. Returns 1 wenn ein Worker das
  Signal bekommen hat, 0 sonst.
  """
  @spec request_probelauf_sweep(String.t(), integer(), [String.t()]) :: non_neg_integer()
  def request_probelauf_sweep(discord_id, stage, models)
      when is_binary(discord_id) and stage in [2, 3, 4] and is_list(models) do
    case pick_leader(discord_id) do
      nil ->
        0

      {_id, %{channel_pid: pid}} ->
        send(pid, {:start_probelauf_sweep, discord_id, stage, models})
        1
    end
  end

  @doc """
  Forward a single MediaRecorder audio chunk from a player's browser to
  the recording-leader worker for `owner_discord_id`. One target, no
  fan-out — the browser is streaming chunks tagged with one session_id,
  and only the worker that holds that session in its AudioBuffer can use
  the data anyway.
  """
  @spec forward_audio_chunk(String.t(), String.t(), String.t(), String.t()) :: non_neg_integer()
  def forward_audio_chunk(owner_discord_id, session_id, sender_discord_id, chunk_b64)
      when is_binary(owner_discord_id) and is_binary(session_id) and
             is_binary(sender_discord_id) and is_binary(chunk_b64) do
    case pick_leader(owner_discord_id) do
      nil ->
        0

      {_id, %{channel_pid: pid}} ->
        send(pid, {:audio_chunk, session_id, sender_discord_id, chunk_b64})
        1
    end
  end

  # Defensive fallback — drop the chunk + log enough to debug. Most common
  # cause: the JS hook fires once with nil/non-binary args (e.g. session_id
  # not yet set, or blobToBase64 returned undefined).
  def forward_audio_chunk(owner_discord_id, session_id, sender_discord_id, chunk_b64) do
    require Logger

    Logger.warning(
      "Hub.Commands.forward_audio_chunk: ignoring chunk with bad args " <>
        inspect(%{
          owner: type_of(owner_discord_id),
          session: type_of(session_id),
          sender: type_of(sender_discord_id),
          chunk: type_of(chunk_b64)
        })
    )

    0
  end

  # Pick a single deterministic worker per admin (highest applied_seq;
  # ties broken by worker_id sort). Same admin always lands on the same
  # leader as long as it stays connected.
  defp pick_leader(discord_id) do
    WorkerRegistry.list()
    |> Enum.filter(fn {_id, meta} -> meta.admin_discord_id == discord_id end)
    |> Enum.sort_by(fn {id, meta} -> {-Map.get(meta, :applied_seq, 0), id} end)
    |> List.first()
  end

  defp type_of(nil), do: :nil
  defp type_of(v) when is_binary(v), do: {:binary, byte_size(v)}
  defp type_of(v) when is_integer(v), do: :integer
  defp type_of(v) when is_atom(v), do: {:atom, v}
  defp type_of(v) when is_map(v), do: :map
  defp type_of(v) when is_list(v), do: :list
  defp type_of(_), do: :other
end
