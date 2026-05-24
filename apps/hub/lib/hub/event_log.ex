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

  Generiert intern eine `event_id` (UUIDv7) wenn keine mitgeliefert wurde —
  Hub-internal-Events behalten das schlanke `append/2`-Interface. Worker
  publishen über `append/3` mit ihrer eigenen event_id (Issue #123).
  """
  @spec append(term(), String.t() | nil) :: {:ok, pos_integer()}
  def append(payload, author_worker_id) do
    append(nil, payload, author_worker_id)
  end

  @doc """
  Variant mit expliziter event_id — der Worker generiert die UUIDv7 lokal,
  weil er das Event vor dem Hub-Sync schon lokal materialisiert (Worker-First-
  Apply, Issue #123). Hub übernimmt sie unverändert.
  """
  @spec append(String.t() | nil, term(), String.t() | nil) :: {:ok, pos_integer()}
  def append(event_id, payload, author_worker_id)
      when is_binary(event_id) or is_nil(event_id) do
    event_id = event_id || UUIDv7.generate()
    ts = DateTime.utc_now()
    {:ok, seq} = adapter().append(event_id, payload, author_worker_id, ts)

    event = %{
      seq: seq,
      event_id: event_id,
      payload: payload,
      author_worker_id: author_worker_id,
      ts: ts
    }

    Phoenix.PubSub.broadcast(Hub.PubSub, @topic, {:event_appended, event})

    {:ok, seq}
  end

  @doc """
  Broadcast-only Pfad (Issue #152, Etappe 4b): publiziert ein Event NUR
  über PubSub, ohne `seq` zu vergeben und ohne in den Storage-Adapter zu
  schreiben. Wird von `WorkerChannel.publish_intent` benutzt, weil der
  Worker das Event seit Etappe 2 ja schon lokal materialisiert hat und
  andere Worker es seit 3c via `pull_since` holen — die events-Tabelle
  als Worker-Sync-Pfad ist seitdem redundant.

  Hub-Side-Producer (LiveViews, Controllers) gehen weiterhin durch
  `append/3` — die Hub-erzeugten Events sind erst in Etappe 4c über
  einen Worker-Bridge-Pfad umzulenken.

  Reply-Map enthält `seq: nil` — Worker.HubClient ignoriert das Feld
  seit 4a (Pull-Sync deckt alles).
  """
  @spec broadcast(String.t() | nil, term(), String.t() | nil) :: :ok
  def broadcast(event_id, payload, author_worker_id)
      when is_binary(event_id) or is_nil(event_id) do
    event_id = event_id || UUIDv7.generate()
    ts = DateTime.utc_now()

    event = %{
      seq: nil,
      event_id: event_id,
      payload: payload,
      author_worker_id: author_worker_id,
      ts: ts
    }

    Phoenix.PubSub.broadcast(Hub.PubSub, @topic, {:event_appended, event})
    :ok
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
