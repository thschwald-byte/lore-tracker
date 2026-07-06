defmodule HubWeb.Live.EventsBatchFoldTest do
  @moduledoc """
  Issue #702: `EventsBatch.fold/3` faltet einen Batch in Reihenfolge durch
  einen `{:event_appended, …}`-Handler — ein Handler-Call pro Event, Socket
  wird durchgereicht, Rückgabe `{:noreply, final}`.
  """
  use ExUnit.Case, async: true

  alias HubWeb.Live.EventsBatch

  test "faltet in Reihenfolge, ein Handler-Call pro Event" do
    # "Socket" ist hier ein beliebiger Akkumulator — fold ist shape-agnostisch.
    handler = fn {:event_appended, ev}, acc ->
      {:noreply, acc ++ [ev.event_id]}
    end

    events = for i <- 1..4, do: %{event_id: "e-#{i}", payload: %{}}

    assert {:noreply, ["e-1", "e-2", "e-3", "e-4"]} = EventsBatch.fold(events, [], handler)
  end

  test "leerer Batch: Socket unverändert" do
    handler = fn _, _ -> flunk("Handler darf bei leerem Batch nicht laufen") end
    assert {:noreply, :socket} = EventsBatch.fold([], :socket, handler)
  end

  test "Handler der nicht {:noreply, _} returnt crasht laut (Silent-Failure-Guard)" do
    handler = fn {:event_appended, _}, acc -> {:reply, :oops, acc} end

    assert_raise MatchError, fn ->
      EventsBatch.fold([%{event_id: "e-1", payload: %{}}], :socket, handler)
    end
  end
end
