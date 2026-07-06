defmodule Hub.EventsBroadcastBatchTest do
  @moduledoc """
  Issue #702: `Hub.Events.broadcast_batch/2` — ein Event-Schwall wird als
  EINE PubSub-Message `{:events_batch, events}` gebroadcastet (statt N
  einzelnen `{:event_appended, …}`); Batch der Größe 1 downgraded auf die
  Einzel-Message, leerer Batch broadcastet gar nicht.
  """
  use ExUnit.Case, async: true

  alias Hub.Events

  setup do
    :ok = Phoenix.PubSub.subscribe(Hub.PubSub, Events.topic())
    :ok
  end

  defp ev(id, kind), do: %{event_id: id, payload: %{"kind" => kind}}

  test "2+ Events → eine {:events_batch, …}-Message mit Event-Shape wie broadcast/3" do
    :ok =
      Events.broadcast_batch([ev("e-1", "UtteranceAppended"), ev("e-2", "MarkerAdded")], "w-1")

    assert_receive {:events_batch, [first, second]}

    assert %{
             seq: nil,
             event_id: "e-1",
             payload: %{"kind" => "UtteranceAppended"},
             author_worker_id: "w-1",
             ts: %DateTime{}
           } = first

    assert second.event_id == "e-2"
    refute_receive {:event_appended, _}
  end

  test "genau 1 Event → downgrade auf {:event_appended, …}" do
    :ok = Events.broadcast_batch([ev("e-solo", "UtteranceAppended")], "w-1")

    assert_receive {:event_appended, %{event_id: "e-solo", author_worker_id: "w-1"}}
    refute_receive {:events_batch, _}
  end

  test "leere Liste broadcastet nichts" do
    :ok = Events.broadcast_batch([], "w-1")
    refute_receive {:events_batch, _}
    refute_receive {:event_appended, _}
  end

  test "nil event_id bekommt eine generierte UUIDv7" do
    :ok = Events.broadcast_batch([ev(nil, "A"), ev(nil, "B")], nil)

    assert_receive {:events_batch, [%{event_id: id1}, %{event_id: id2}]}
    assert is_binary(id1) and byte_size(id1) == 36
    assert id1 != id2
  end
end
