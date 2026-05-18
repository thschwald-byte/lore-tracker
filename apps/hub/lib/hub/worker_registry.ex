defmodule Hub.WorkerRegistry do
  @moduledoc """
  Phoenix.Tracker view of currently-connected workers.

  Each entry: `worker_id => %{admin_discord_id, applied_seq, channel_pid}`.
  `applied_seq` is updated whenever the worker acks an event apply; the
  Hub picks the worker with the highest `applied_seq` for snapshot reads.
  """

  use Phoenix.Tracker

  @topic "workers"

  # ─── Tracker plumbing ─────────────────────────────────────────────

  def start_link(opts) do
    opts =
      Keyword.merge(
        [name: __MODULE__, pubsub_server: Hub.PubSub],
        opts
      )

    Phoenix.Tracker.start_link(__MODULE__, opts, opts)
  end

  @impl true
  def init(opts) do
    {:ok, %{pubsub_server: Keyword.fetch!(opts, :pubsub_server)}}
  end

  @impl true
  def handle_diff(_diff, state), do: {:ok, state}

  # ─── API used from WorkerChannel ──────────────────────────────────

  @doc "Register the calling channel pid as the worker with the given id."
  def track(worker_id, admin_discord_id) when is_binary(worker_id) do
    Phoenix.Tracker.track(__MODULE__, self(), @topic, worker_id, %{
      admin_discord_id: admin_discord_id,
      applied_seq: 0,
      channel_pid: self()
    })
  end

  @doc "Bump the applied_seq metadata for the calling channel pid."
  def update_applied_seq(worker_id, seq) when is_binary(worker_id) and is_integer(seq) do
    Phoenix.Tracker.update(__MODULE__, self(), @topic, worker_id, fn meta ->
      Map.put(meta, :applied_seq, max(seq, meta.applied_seq))
    end)
  end

  @doc "List `{worker_id, metadata}` for everyone currently connected."
  def list, do: Phoenix.Tracker.list(__MODULE__, @topic)
end
