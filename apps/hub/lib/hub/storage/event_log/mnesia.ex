defmodule Hub.Storage.EventLog.Mnesia do
  @moduledoc """
  Mnesia-backed event log. The `seq` counter lives in a separate Mnesia
  counter table, atomic per node (single-hub by design).
  """

  @behaviour Hub.Storage.EventLog

  @table :hub_events
  @counter :hub_event_seq

  def table, do: @table

  @impl true
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

  @impl true
  def append(payload, author_worker_id, ts) do
    {:atomic, seq} =
      :mnesia.transaction(fn ->
        seq = :mnesia.dirty_update_counter(@counter, :seq, 1)
        :mnesia.write({@table, seq, payload, author_worker_id, ts})
        seq
      end)

    {:ok, seq}
  end

  @impl true
  def head do
    case :mnesia.dirty_read(@counter, :seq) do
      [{_, _, n}] -> n
      [] -> 0
    end
  end

  @impl true
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
