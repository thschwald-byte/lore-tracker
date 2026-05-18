defmodule Hub.Reader do
  @moduledoc """
  Coordinates `snapshot_request`/`snapshot_response` round-trips between
  Hub-side callers (LiveViews) and connected workers.

  - `read/2` picks the most-up-to-date connected worker from
    `Hub.WorkerRegistry`, generates a request_id, hands the request to
    that worker's channel pid, and blocks until the worker pushes a
    `snapshot_response` back (or the timeout fires).
  - LiveView callers should treat `{:error, :no_worker}` as the
    "Warte auf Worker" condition.
  """

  use GenServer

  require Logger

  @default_timeout 5_000

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @spec read(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def read(scope, opts \\ []) when is_map(scope) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    GenServer.call(__MODULE__, {:read, scope, timeout}, timeout + 500)
  end

  @doc "Called by WorkerChannel when a snapshot_response arrives."
  def handle_response(request_id, payload) do
    GenServer.cast(__MODULE__, {:response, request_id, payload})
  end

  # ─── GenServer ────────────────────────────────────────────────────

  @impl true
  def init(_), do: {:ok, %{pending: %{}, timers: %{}}}

  @impl true
  def handle_call({:read, scope, timeout}, from, state) do
    case pick_worker() do
      nil ->
        {:reply, {:error, :no_worker}, state}

      {_worker_id, channel_pid} ->
        request_id = 12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
        send(channel_pid, {:snapshot_request, scope, request_id, self()})
        timer = Process.send_after(self(), {:timeout, request_id}, timeout)

        {:noreply,
         %{
           state
           | pending: Map.put(state.pending, request_id, from),
             timers: Map.put(state.timers, request_id, timer)
         }}
    end
  end

  @impl true
  def handle_cast({:response, request_id, payload}, state) do
    case Map.pop(state.pending, request_id) do
      {nil, _} ->
        # Late response after timeout — drop.
        {:noreply, state}

      {from, pending} ->
        cancel_timer(state.timers[request_id])
        GenServer.reply(from, {:ok, payload})
        {:noreply, %{state | pending: pending, timers: Map.delete(state.timers, request_id)}}
    end
  end

  @impl true
  def handle_info({:timeout, request_id}, state) do
    case Map.pop(state.pending, request_id) do
      {nil, _} ->
        {:noreply, state}

      {from, pending} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | pending: pending, timers: Map.delete(state.timers, request_id)}}
    end
  end

  # ─── Helpers ────────────────────────────────────────────────────

  defp pick_worker do
    case Hub.WorkerRegistry.list() do
      [] ->
        nil

      list ->
        {worker_id, meta} = Enum.max_by(list, fn {_, m} -> m.applied_seq end)
        {worker_id, meta.channel_pid}
    end
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)
end
