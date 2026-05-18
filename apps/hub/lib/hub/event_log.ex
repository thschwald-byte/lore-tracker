defmodule Hub.EventLog do
  @moduledoc """
  Append-only event log persisted in Mnesia.

  - `append/2` mints the next sequence number, persists the event, and
    broadcasts on the `"events"` PubSub topic.
  - `stream/1` returns events with `seq > after_seq` (catch-up).
  - `head/0` is the current maximum `seq`.

  The `seq` counter is a separate Mnesia counter table, atomic per node.
  We're single-hub by design; if that ever changes, replace the counter
  with a clustered allocator (e.g. khepri or a leader-elected GenServer).
  """

  @table :hub_events
  @counter :hub_event_seq
  @topic "events"

  def table, do: @table
  def topic, do: @topic

  def bootstrap! do
    :ok =
      Shared.Mnesia.ensure_table!(@table,
        attributes: [:seq, :payload, :author_worker_id, :ts],
        type: :ordered_set
      )

    :ok =
      Shared.Mnesia.ensure_table!(@counter,
        attributes: [:key, :value],
        type: :set
      )

    :ok
  end

  @doc """
  Mint the next `seq`, persist `{seq, payload, author_worker_id, now}`,
  broadcast on PubSub. Returns the new `seq`.

  `author_worker_id` may be `nil` for events the Hub itself originates
  (e.g. from UI LiveViews in M4+).
  """
  @spec append(term(), String.t() | nil) :: {:ok, pos_integer()}
  def append(payload, author_worker_id) do
    ts = DateTime.utc_now()

    {:atomic, seq} =
      :mnesia.transaction(fn ->
        seq = :mnesia.dirty_update_counter(@counter, :seq, 1)
        :mnesia.write({@table, seq, payload, author_worker_id, ts})
        seq
      end)

    event = %{seq: seq, payload: payload, author_worker_id: author_worker_id, ts: ts}
    Phoenix.PubSub.broadcast(Hub.PubSub, @topic, {:event_appended, event})

    {:ok, seq}
  end

  @spec head() :: non_neg_integer()
  def head do
    case :mnesia.dirty_read(@counter, :seq) do
      [{_, _, n}] -> n
      [] -> 0
    end
  end

  @doc """
  Return events with `seq > after_seq`, ordered. Empty list if caught up.
  """
  @spec stream(non_neg_integer()) :: [map()]
  def stream(after_seq) when is_integer(after_seq) and after_seq >= 0 do
    head = head()

    cond do
      after_seq >= head ->
        []

      true ->
        {:atomic, list} =
          :mnesia.transaction(fn ->
            for seq <- (after_seq + 1)..head, reduce: [] do
              acc ->
                case :mnesia.read(@table, seq) do
                  [{_, ^seq, payload, author, ts}] ->
                    [%{seq: seq, payload: payload, author_worker_id: author, ts: ts} | acc]

                  [] ->
                    acc
                end
            end
          end)

        Enum.reverse(list)
    end
  end
end
