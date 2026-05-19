defmodule Hub.Storage.EventLog.Postgres do
  @moduledoc """
  Postgres-backed event log. `BIGSERIAL` on `seq` replaces the dedicated
  Mnesia counter — Postgres guarantees monotonic ascending values per
  insert, sufficient for the single-hub by-design constraint.
  """

  @behaviour Hub.Storage.EventLog

  import Ecto.Query

  alias Hub.Repo
  alias Hub.Schema.Event

  @impl true
  def bootstrap!, do: :ok

  @impl true
  def append(payload, author_worker_id, ts) do
    {1, [%{seq: seq}]} =
      Repo.insert_all(Event,
        [%{payload: payload, author_worker_id: author_worker_id, ts: ts}],
        returning: [:seq]
      )

    {:ok, seq}
  end

  @impl true
  def head do
    Repo.aggregate(Event, :max, :seq) || 0
  end

  @impl true
  def stream(after_seq) when is_integer(after_seq) and after_seq >= 0 do
    from(e in Event,
      where: e.seq > ^after_seq,
      order_by: e.seq,
      select: %{
        seq: e.seq,
        payload: e.payload,
        author_worker_id: e.author_worker_id,
        ts: e.ts
      }
    )
    |> Repo.all()
  end
end
