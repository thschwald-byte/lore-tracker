defmodule Hub.WorkerRegistry do
  @moduledoc """
  Phoenix.Tracker view of currently-connected workers.

  Each entry: `worker_id => %{admin_discord_id, applied_seq, channel_pid}`.
  `applied_seq` is updated whenever the worker acks an event apply; the
  Hub picks the worker with the highest `applied_seq` for snapshot reads.

  Membership changes broadcast `{:workers_changed, joins, leaves}` on
  Hub.PubSub topic `"workers"` so LiveViews can re-fetch their snapshots
  the moment a worker comes online (instead of waiting for an event).
  """

  use Phoenix.Tracker

  @topic "workers"

  def topic, do: @topic

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
  def handle_diff(diff, state) do
    case Map.get(diff, @topic) do
      nil ->
        :ok

      {joins, leaves} ->
        if joins != [] or leaves != [] do
          Phoenix.PubSub.broadcast(
            state.pubsub_server,
            @topic,
            {:workers_changed, joins, leaves}
          )
        end
    end

    {:ok, state}
  end

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
