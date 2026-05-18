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
end
