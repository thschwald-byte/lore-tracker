defmodule Hub.Storage.EventLog.MnesiaTest do
  @moduledoc """
  Behavioural conformance tests for the Mnesia EventLog adapter.

  Mnesia is process-global, so async: false. We clear both backing tables
  before each test to get a clean slate without re-creating schemas.
  """

  use ExUnit.Case, async: false

  alias Hub.Storage.EventLog.Mnesia, as: Adapter

  setup do
    {:atomic, :ok} = :mnesia.clear_table(:hub_events)
    {:atomic, :ok} = :mnesia.clear_table(:hub_event_seq)
    :ok
  end

  test "head/0 on empty log returns 0" do
    assert Adapter.head() == 0
  end

  test "append/4 mints monotonic seqs starting at 1" do
    ts = ~U[2026-05-19 10:00:00.000000Z]

    assert {:ok, 1} = Adapter.append(nil, %{"kind" => "a"}, "w1", ts)
    assert {:ok, 2} = Adapter.append(nil, %{"kind" => "b"}, "w1", ts)
    assert {:ok, 3} = Adapter.append(nil, %{"kind" => "c"}, nil, ts)
    assert Adapter.head() == 3
  end

  test "stream/1 returns events in ascending seq order" do
    ts = ~U[2026-05-19 10:00:00.000000Z]
    for i <- 1..5, do: {:ok, _} = Adapter.append(nil, %{"i" => i}, "w1", ts)

    events = Adapter.stream(0)
    assert length(events) == 5
    assert Enum.map(events, & &1.seq) == [1, 2, 3, 4, 5]
    assert Enum.map(events, & &1.payload) == Enum.map(1..5, fn i -> %{"i" => i} end)
  end

  test "stream(after) skips already-applied events" do
    ts = ~U[2026-05-19 10:00:00.000000Z]
    for i <- 1..5, do: {:ok, _} = Adapter.append(nil, %{"i" => i}, "w1", ts)

    assert length(Adapter.stream(0)) == 5
    assert length(Adapter.stream(2)) == 3
    assert length(Adapter.stream(4)) == 1
    assert length(Adapter.stream(5)) == 0
  end

  test "stream past head returns []" do
    {:ok, _} = Adapter.append(nil, %{"k" => "v"}, nil, DateTime.utc_now())
    assert Adapter.stream(999_999) == []
  end

  test "payload preserves nested maps + strings + nils" do
    ts = ~U[2026-05-19 10:00:00.000000Z]
    payload = %{"kind" => "X", "nested" => %{"a" => 1, "b" => nil}, "list" => ["x", "y"]}
    {:ok, seq} = Adapter.append(nil, payload, "author-1", ts)

    [
      %{
        seq: ^seq,
        payload: read_back,
        author_worker_id: "author-1",
        ts: ^ts,
        event_id: nil
      }
    ] = Adapter.stream(0)

    assert read_back == payload
  end

  # Issue #123 (Etappe 2): event_id wird durchgereicht und kommt mit beim Stream.
  test "append/4 mit event_id schreibt + liest die UUIDv7 zurück" do
    ts = ~U[2026-05-19 10:00:00.000000Z]
    eid = "019e4ef5-22d3-7c2e-a79d-9baedfb4699e"

    {:ok, seq} = Adapter.append(eid, %{"kind" => "z"}, "w1", ts)
    [%{seq: ^seq, event_id: ^eid}] = Adapter.stream(0)
  end
end
