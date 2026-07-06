defmodule Hub.Events do
  @moduledoc """
  Stateless PubSub-only Event-Schiene (Issue #154, Etappe 4c.4).

  Nach Etappe 4c hat der Hub keine `events`-Tabelle mehr — alle Events
  leben kanonisch in den per-Campaign-Stores der Worker (`worker_campaign_events_*`)
  bzw. `worker_events_global`. Der Hub ist nur noch Sub/Pub-Router.

  Dieses Modul ersetzt das alte `Hub.EventLog` für die zwei verbleibenden
  Aufgaben:
  - `topic/0` für PubSub-Subscriber (LiveViews, WorkerChannel)
  - `broadcast/3` als der einzige Pfad, der ein Event ans LV-Layer +
    Worker-Subscriber broadcasted. Wird in `WorkerChannel.publish_intent`
    aufgerufen, wenn ein Worker ein neues Event ankündigt.

  Konzeptionell: keine seq, keine Persistenz, keine Adapter.
  """

  @topic "events"

  @spec topic() :: String.t()
  def topic, do: @topic

  @doc """
  Broadcastet ein Event ans PubSub-Topic. Worker-Channels filtern dann
  pro Campaign-Subscription (Issue #129 / Etappe 3b), LiveViews matchen
  per-`kind` im handle_info.

  `event_id` wird falls nicht mitgegeben lokal als UUIDv7 vergeben —
  Worker liefern ihre eigene mit (Worker-First-Apply, Issue #123).
  Wire-Frame trägt `seq: nil`, weil der Hub seit Etappe 4b keine seq
  mehr vergibt.
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

  @doc """
  Broadcastet MEHRERE Events als EINE PubSub-Message `{:events_batch, events}`
  (Issue #702). Ein Utterance-Backlog nach Session-Ende erzeugte vorher N
  einzelne `{:event_appended, …}`-Messages → N LiveView-Diffs → N Longpoll-
  Puffer-Einträge pro Client; auf der 0,4-GB-Instanz der OOM-Treiber. Ein
  Batch erzeugt genau eine Message und damit einen Diff pro Subscriber.

  Event-Shape pro Element identisch zu `broadcast/3` (`seq: nil`, `event_id`,
  `payload`, `author_worker_id`, `ts`). Batch der Größe 1 wird auf
  `broadcast/3` downgraded — weniger Code-Pfade, die die neue Message-Shape
  kennen müssen. `ts` ist pro Batch einheitlich (Broadcast-Zeit, nicht
  Payload-Zeit — wie bei `broadcast/3`).
  """
  @spec broadcast_batch([%{event_id: String.t() | nil, payload: term()}], String.t() | nil) ::
          :ok
  def broadcast_batch([], _author_worker_id), do: :ok

  def broadcast_batch([%{event_id: event_id, payload: payload}], author_worker_id),
    do: broadcast(event_id, payload, author_worker_id)

  def broadcast_batch(events, author_worker_id) when is_list(events) do
    ts = DateTime.utc_now()

    wrapped =
      Enum.map(events, fn %{event_id: event_id, payload: payload} ->
        %{
          seq: nil,
          event_id: event_id || UUIDv7.generate(),
          payload: payload,
          author_worker_id: author_worker_id,
          ts: ts
        }
      end)

    Phoenix.PubSub.broadcast(Hub.PubSub, @topic, {:events_batch, wrapped})
    :ok
  end
end
