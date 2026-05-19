defmodule Hub.Storage.EventLog.PostgresTest do
  @moduledoc """
  Behavioural conformance tests for the Postgres EventLog adapter.

  Tagged :postgres — excluded by default. Run with `mix test --include postgres`
  against a Postgres reachable per config/test.exs creds. Each test runs
  inside a Sandbox-checked-out connection (transactional isolation).
  """

  use ExUnit.Case, async: true
  @moduletag :postgres

  alias Hub.Storage.EventLog.Postgres, as: Adapter
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(Hub.Repo)
  end

  test "head/0 on empty log returns 0" do
    assert Adapter.head() == 0
  end

  test "append/3 mints monotonic seqs (BIGSERIAL)" do
    ts = ~U[2026-05-19 10:00:00.000000Z]

    {:ok, s1} = Adapter.append(%{"kind" => "a"}, "w1", ts)
    {:ok, s2} = Adapter.append(%{"kind" => "b"}, "w1", ts)
    {:ok, s3} = Adapter.append(%{"kind" => "c"}, nil, ts)

    assert s2 > s1
    assert s3 > s2
    assert Adapter.head() == s3
  end

  test "stream/1 returns events in ascending seq order" do
    ts = ~U[2026-05-19 10:00:00.000000Z]

    expected =
      for i <- 1..5 do
        {:ok, seq} = Adapter.append(%{"i" => i}, "w1", ts)
        {seq, i}
      end

    events = Adapter.stream(0)
    assert Enum.map(events, & &1.seq) == Enum.map(expected, &elem(&1, 0))
    assert Enum.map(events, & &1.payload["i"]) == Enum.map(expected, &elem(&1, 1))
  end

  test "stream(after) skips already-applied events" do
    ts = ~U[2026-05-19 10:00:00.000000Z]
    seqs = for i <- 1..5, do: (elem(Adapter.append(%{"i" => i}, nil, ts), 1))

    assert length(Adapter.stream(0)) == 5
    assert length(Adapter.stream(Enum.at(seqs, 1))) == 3
    assert length(Adapter.stream(Enum.at(seqs, 3))) == 1
    assert length(Adapter.stream(Enum.at(seqs, 4))) == 0
  end

  test "stream past head returns []" do
    {:ok, _} = Adapter.append(%{"k" => "v"}, nil, DateTime.utc_now())
    assert Adapter.stream(999_999_999) == []
  end

  test "payload preserves nested maps + strings + nils via JSONB roundtrip" do
    ts = ~U[2026-05-19 10:00:00.000000Z]
    payload = %{"kind" => "X", "nested" => %{"a" => 1, "b" => nil}, "list" => ["x", "y"]}
    {:ok, seq} = Adapter.append(payload, "author-1", ts)

    [%{seq: ^seq, payload: read_back, author_worker_id: "author-1"}] = Adapter.stream(seq - 1)
    assert read_back == payload
  end
end
