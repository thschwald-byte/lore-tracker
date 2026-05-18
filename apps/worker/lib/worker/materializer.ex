defmodule Worker.Materializer do
  @moduledoc """
  Applies events delivered from the Hub to the local Mnesia view.

  Idempotent: events with `seq <= last_applied_seq` are dropped (echo
  protection on reconnect / repeated catch-ups).

  M3 stub: no real per-payload handlers yet — we just bump
  `:last_applied_seq` and ack. M4+ pattern-matches on `payload.kind` (or
  on the `%Shared.Events.*{}` struct types) and writes campaigns, sessions,
  members, etc.

  Caller (`Worker.HubClient`) is expected to forward each `event_appended`
  push and each item from `catch_up_batch` via `apply_event/1`. After a
  successful apply, the caller should send the worker's `ack_applied{seq}`
  back to the hub so `Hub.WorkerRegistry` can mark this worker as
  caught up to that seq.
  """

  use GenServer

  require Logger

  alias Worker.Repo

  # ─── API ──────────────────────────────────────────────────────────

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Synchronously apply an event. Returns `{:applied, seq}` or `:skipped`."
  @spec apply_event(map()) :: {:applied, pos_integer()} | :skipped
  def apply_event(event), do: GenServer.call(__MODULE__, {:apply, event})

  @doc "Convenience: apply a list of events in order, returns the highest seq applied."
  @spec apply_batch([map()]) :: non_neg_integer()
  def apply_batch(events) when is_list(events) do
    Enum.reduce(events, last_applied_seq(), fn ev, acc ->
      case apply_event(ev) do
        {:applied, seq} -> max(seq, acc)
        :skipped -> acc
      end
    end)
  end

  @doc "Current cursor from Mnesia."
  @spec last_applied_seq() :: non_neg_integer()
  def last_applied_seq, do: Repo.get_state(:last_applied_seq) || 0

  # ─── GenServer ────────────────────────────────────────────────────

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:apply, %{"seq" => seq} = event}, _from, state) when is_integer(seq) do
    current = last_applied_seq()

    cond do
      seq <= current ->
        # Already applied — echo or duplicate catch-up. Ignore.
        {:reply, :skipped, state}

      seq != current + 1 ->
        # Gap — we'd skip events. For M3 we just log and apply anyway;
        # M4+ will trigger a fresh catch_up_request to fill the hole.
        Logger.warning(
          "Materializer: gap detected (current=#{current}, incoming=#{seq}). Applying anyway."
        )

        do_apply(event)
        Repo.put_state(:last_applied_seq, seq)
        {:reply, {:applied, seq}, state}

      true ->
        do_apply(event)
        Repo.put_state(:last_applied_seq, seq)
        {:reply, {:applied, seq}, state}
    end
  end

  # ─── Pattern dispatch (stub) ─────────────────────────────────────

  defp do_apply(%{"payload" => payload, "seq" => seq}) do
    # M4+ will pattern-match on payload structure here.
    Logger.debug(fn -> "Materializer: applied seq=#{seq} payload=#{inspect(payload)}" end)
    :ok
  end
end
