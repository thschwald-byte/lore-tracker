defmodule Hub.Storage.WorkerTokens.MnesiaTest do
  @moduledoc """
  Behavioural conformance tests for the Mnesia WorkerTokens adapter.
  """

  use ExUnit.Case, async: false

  alias Hub.Storage.WorkerTokens.Mnesia, as: Adapter

  setup do
    {:atomic, :ok} = :mnesia.clear_table(:hub_worker_tokens)
    :ok
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
    # Pre-Join: alle Version-Felder sind nil
    assert is_nil(row.last_seen_version)
    assert is_nil(row.last_seen_sha)
    assert is_nil(row.last_seen_protocol_version)
  end

  test "record_join/2 persists version + sha + protocol_version and bumps last_seen_at" do
    token = Adapter.issue("worker-1", "discord-42")
    {:ok, before_row} = Adapter.lookup(token)
    # Mnesia speichert utc_datetime mit µs-Genauigkeit — kurz schlafen,
    # damit der neue Timestamp messbar später ist.
    Process.sleep(5)

    assert :ok =
             Adapter.record_join(token, %{
               "worker_version" => "0.2.0",
               "worker_sha" => "abc1234",
               "protocol_version" => 1
             })

    assert {:ok, after_row} = Adapter.lookup(token)
    assert after_row.last_seen_version == "0.2.0"
    assert after_row.last_seen_sha == "abc1234"
    assert after_row.last_seen_protocol_version == 1
    assert DateTime.compare(after_row.last_seen_at, before_row.last_seen_at) == :gt
    # issued_at bleibt unverändert
    assert after_row.issued_at == before_row.issued_at
  end

  test "record_join/2 on unknown token returns :error" do
    assert :error =
             Adapter.record_join("nope", %{
               "worker_version" => "0.2.0",
               "worker_sha" => "abc1234",
               "protocol_version" => 1
             })
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
