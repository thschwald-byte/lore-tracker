defmodule Worker.HubClient.EventsChunkTest do
  @moduledoc """
  Issue #690: Drift-Guard für das Byte-Budget-Chunking der Pull-Antworten
  (`Worker.HubClient.Events.chunk_by_budget/2`). Ohne Chunking geht ein
  Cold-Start-Sync (z.B. 15110 Events) als EIN WebSocket-Frame durch den
  Gigalixir/Google-Cloud-Proxy und wird mit 502 verworfen → frischer Worker
  bleibt leer. Der Test sichert die Invarianten, auf die der Fix sich verlässt:
  Reihenfolge + Vollständigkeit bleiben, kein Chunk sprengt das Budget (außer
  ein einzelnes über-Budget-Event, das allein rausgeht statt hängenzubleiben).
  """
  use ExUnit.Case, async: true

  alias Worker.HubClient.Events

  # Wire-Event-Shape wie in on_pull_request_global aufgebaut. `text` bestimmt die
  # serialisierte Größe (via :erlang.external_size im Chunker).
  defp ev(id, text_len) do
    %{
      event_id: "ev-#{id}",
      hub_seq: id,
      payload: %{"kind" => "UtteranceAppended", "text" => String.duplicate("a", text_len)},
      ts: "2026-07-03T00:00:00Z"
    }
  end

  describe "chunk_by_budget/2" do
    test "leere Liste → []" do
      assert Events.chunk_by_budget([], 200_000) == []
    end

    test "ein Event → genau ein Chunk mit diesem Event" do
      e = ev(1, 50)
      assert Events.chunk_by_budget([e], 200_000) == [[e]]
    end

    test "viele kleine Events, großes Budget → ein Chunk" do
      events = for i <- 1..20, do: ev(i, 20)
      assert Events.chunk_by_budget(events, 1_000_000) == [events]
    end

    test "Reihenfolge + Vollständigkeit bleiben über mehrere Chunks erhalten" do
      events = for i <- 1..50, do: ev(i, 200)
      chunks = Events.chunk_by_budget(events, 1_000)

      assert length(chunks) > 1, "erwarte mehrere Chunks bei kleinem Budget"
      # Flatten reproduziert die Eingabe exakt (Reihenfolge + kein Verlust/Dup).
      assert List.flatten(chunks) == events
    end

    test "jeder Multi-Event-Chunk bleibt unter dem Budget" do
      events = for i <- 1..50, do: ev(i, 200)
      budget = 1_000
      chunks = Events.chunk_by_budget(events, budget)

      for chunk <- chunks, length(chunk) > 1 do
        size = Enum.reduce(chunk, 0, fn e, acc -> acc + :erlang.external_size(e) end)

        assert size <= budget,
               "Multi-Event-Chunk (#{length(chunk)}) überschreitet Budget: #{size}"
      end
    end

    test "jeder Chunk ist nicht-leer" do
      events = for i <- 1..30, do: ev(i, 300)
      chunks = Events.chunk_by_budget(events, 500)
      assert Enum.all?(chunks, &(&1 != []))
    end

    test "einzelnes über-Budget-Event landet allein in eigenem Chunk (kein Hänger)" do
      big = ev(1, 5_000)
      small = ev(2, 10)
      # Budget kleiner als das große Event → big muss trotzdem raus, allein.
      chunks = Events.chunk_by_budget([big, small], 1_000)

      assert [big] in chunks
      assert List.flatten(chunks) == [big, small]
      # big darf small nicht mit in seinen Chunk ziehen.
      big_chunk = Enum.find(chunks, &(big in &1))
      assert big_chunk == [big]
    end
  end
end
