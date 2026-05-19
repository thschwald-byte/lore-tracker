defmodule Hub.Storage.WorkerTokens.PostgresTest do
  @moduledoc """
  Behavioural conformance tests for the Postgres WorkerTokens adapter.

  Tagged :postgres — excluded by default. Run with `mix test --include postgres`.
  """

  use ExUnit.Case, async: true
  @moduletag :postgres

  alias Hub.Storage.WorkerTokens.Postgres, as: Adapter
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(Hub.Repo)
  end

  test "issue/2 returns a non-empty token string" do
    token = Adapter.issue("worker-1", "discord-42")
    assert is_binary(token)
    assert byte_size(token) > 0
  end

  test "issue/2 + lookup/1 roundtrip preserves all fields" do
    token = Adapter.issue("worker-1", "discord-42")

    assert {:ok, row} = Adapter.lookup(token)
    assert row.token == token
    assert row.worker_id == "worker-1"
    assert row.admin_discord_id == "discord-42"
    assert %DateTime{} = row.issued_at
    assert %DateTime{} = row.last_seen_at
  end

  test "lookup/1 on unknown token returns :error" do
    assert :error = Adapter.lookup("definitely-not-a-real-token")
  end

  test "issue/2 produces unique tokens across calls" do
    tokens =
      for _ <- 1..20, do: Adapter.issue("w1", "d1")

    assert length(Enum.uniq(tokens)) == 20
  end
end
