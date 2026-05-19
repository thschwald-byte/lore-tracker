defmodule Hub.EventLog do
  @moduledoc """
  Public façade for the append-only event log.

  - `append/2` mints the next sequence number, persists the event via the
    configured `Hub.Storage.EventLog` adapter, and broadcasts on the
    `"events"` PubSub topic.
  - `stream/1` returns events with `seq > after_seq` (catch-up).
  - `head/0` is the current maximum `seq`.

  Storage backend (Mnesia in dev, Postgres in prod) is selected at runtime
  via `Application.get_env(:hub, :storage_backend)`.
  """

  @topic "events"

  def topic, do: @topic

  def bootstrap!, do: adapter().bootstrap!()

  @doc """
  Mint the next `seq`, persist the event, broadcast on PubSub.
  Returns `{:ok, seq}`.

  `author_worker_id` may be `nil` for events the Hub itself originates
  (e.g. from UI LiveViews).
  """
  @spec append(term(), String.t() | nil) :: {:ok, pos_integer()}
  def append(payload, author_worker_id) do
    ts = DateTime.utc_now()
    {:ok, seq} = adapter().append(payload, author_worker_id, ts)

    event = %{seq: seq, payload: payload, author_worker_id: author_worker_id, ts: ts}
    Phoenix.PubSub.broadcast(Hub.PubSub, @topic, {:event_appended, event})

    {:ok, seq}
  end

  @spec head() :: non_neg_integer()
  def head, do: adapter().head()

  @doc "Return events with `seq > after_seq`, ordered ascending."
  @spec stream(non_neg_integer()) :: [map()]
  def stream(after_seq) when is_integer(after_seq) and after_seq >= 0 do
    adapter().stream(after_seq)
  end

  defp adapter do
    case Application.get_env(:hub, :storage_backend, :mnesia) do
      :mnesia -> Hub.Storage.EventLog.Mnesia
      :postgres -> Hub.Storage.EventLog.Postgres
      other -> raise "Unknown :hub :storage_backend #{inspect(other)}"
    end
  end
end
