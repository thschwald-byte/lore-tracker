defmodule Worker.LLM.CloudHelperTest do
  @moduledoc """
  Issue #463 — Tests für `Worker.LLM.CloudHelper.map_response/2` und
  `with_retry/2`. Beide Funktionen werden in allen drei Cloud-Backends
  geshared — die Backend-spezifischen Module haben drumherum nur noch
  Request-Shape + Response-Parsing.

  `map_response/2` ist pure (nur Logger als Side-Effect) → direkter
  Schmäh-Test ohne Req-Mocks.
  """

  use ExUnit.Case, async: true

  alias Worker.LLM.CloudHelper

  describe "map_response/2 — status-based mapping" do
    test "200 → {:ok, body} (Backend parsed weiter)" do
      assert {:ok, %{"foo" => "bar"}} =
               CloudHelper.map_response({:ok, %{status: 200, body: %{"foo" => "bar"}}}, "Test")
    end

    test "401 → :upstream_auth (Vertrags-Fix: vorher nur Google)" do
      assert {:error, :upstream_auth} =
               CloudHelper.map_response({:ok, %{status: 401, body: %{"error" => "x"}}}, "Test")
    end

    test "403 → :upstream_auth (Vertrags-Fix: vorher nur Google)" do
      assert {:error, :upstream_auth} =
               CloudHelper.map_response({:ok, %{status: 403, body: %{"error" => "x"}}}, "Test")
    end

    test "429 → :upstream_rate_limit" do
      assert {:error, :upstream_rate_limit} =
               CloudHelper.map_response({:ok, %{status: 429, body: %{}}}, "Test")
    end

    test "500 → {:upstream_error, 500, msg} extrahiert error.message" do
      body = %{"error" => %{"message" => "server boom"}}

      assert {:error, {:upstream_error, 500, "server boom"}} =
               CloudHelper.map_response({:ok, %{status: 500, body: body}}, "Test")
    end

    test "503 → {:upstream_error, 503, nil} ohne error.message-Shape" do
      assert {:error, {:upstream_error, 503, nil}} =
               CloudHelper.map_response({:ok, %{status: 503, body: %{}}}, "Test")
    end

    test "404 → {:http, 404, body} (4xx ≠ 401/403/429)" do
      assert {:error, {:http, 404, %{"x" => "y"}}} =
               CloudHelper.map_response({:ok, %{status: 404, body: %{"x" => "y"}}}, "Test")
    end

    test "400 → {:http, 400, body}" do
      assert {:error, {:http, 400, _}} =
               CloudHelper.map_response({:ok, %{status: 400, body: %{}}}, "Test")
    end

    test "Req error → {:network_error, reason}" do
      assert {:error, {:network_error, :timeout}} =
               CloudHelper.map_response({:error, :timeout}, "Test")
    end

    test "Req-Error mit Exception → {:network_error, exception}" do
      reason = %Req.TransportError{reason: :econnrefused}

      assert {:error, {:network_error, ^reason}} =
               CloudHelper.map_response({:error, reason}, "Test")
    end
  end

  describe "with_retry/2 — retry behaviour" do
    test "ok auf erstem Versuch → kein Retry" do
      counter = :counters.new(1, [])

      result =
        CloudHelper.with_retry(
          fn ->
            :counters.add(counter, 1, 1)
            {:ok, :payload}
          end,
          initial_backoff_ms: 1
        )

      assert {:ok, :payload} = result
      assert :counters.get(counter, 1) == 1
    end

    test ":upstream_rate_limit retried bis max_retries, dann gibt auf" do
      counter = :counters.new(1, [])

      result =
        CloudHelper.with_retry(
          fn ->
            :counters.add(counter, 1, 1)
            {:error, :upstream_rate_limit}
          end,
          initial_backoff_ms: 1,
          max_retries: 2
        )

      assert {:error, :upstream_rate_limit} = result
      # 1 initialer Call + 2 Retries = 3
      assert :counters.get(counter, 1) == 3
    end

    test ":upstream_rate_limit recovered im zweiten Versuch" do
      counter = :counters.new(1, [])

      result =
        CloudHelper.with_retry(
          fn ->
            n = :counters.get(counter, 1)
            :counters.add(counter, 1, 1)

            if n == 0 do
              {:error, :upstream_rate_limit}
            else
              {:ok, :recovered}
            end
          end,
          initial_backoff_ms: 1
        )

      assert {:ok, :recovered} = result
      assert :counters.get(counter, 1) == 2
    end

    test "{:upstream_error, 500, _} retried" do
      counter = :counters.new(1, [])

      result =
        CloudHelper.with_retry(
          fn ->
            :counters.add(counter, 1, 1)
            {:error, {:upstream_error, 500, "boom"}}
          end,
          initial_backoff_ms: 1,
          max_retries: 1
        )

      assert {:error, {:upstream_error, 500, "boom"}} = result
      assert :counters.get(counter, 1) == 2
    end

    test "{:upstream_error, 502, _} retried (alle 5xx)" do
      counter = :counters.new(1, [])

      _ =
        CloudHelper.with_retry(
          fn ->
            :counters.add(counter, 1, 1)
            {:error, {:upstream_error, 502, nil}}
          end,
          initial_backoff_ms: 1,
          max_retries: 1
        )

      assert :counters.get(counter, 1) == 2
    end

    test "{:network_error, _} retried" do
      counter = :counters.new(1, [])

      _ =
        CloudHelper.with_retry(
          fn ->
            :counters.add(counter, 1, 1)
            {:error, {:network_error, :timeout}}
          end,
          initial_backoff_ms: 1,
          max_retries: 2
        )

      assert :counters.get(counter, 1) == 3
    end

    test ":upstream_auth retried NICHT (Client-Fehler, sofort hart)" do
      counter = :counters.new(1, [])

      result =
        CloudHelper.with_retry(
          fn ->
            :counters.add(counter, 1, 1)
            {:error, :upstream_auth}
          end,
          initial_backoff_ms: 1,
          max_retries: 2
        )

      assert {:error, :upstream_auth} = result
      # Kein Retry — exakt 1 Call
      assert :counters.get(counter, 1) == 1
    end

    test "{:http, 400, _} retried NICHT (Client-Fehler)" do
      counter = :counters.new(1, [])

      _ =
        CloudHelper.with_retry(
          fn ->
            :counters.add(counter, 1, 1)
            {:error, {:http, 400, %{}}}
          end,
          initial_backoff_ms: 1,
          max_retries: 2
        )

      assert :counters.get(counter, 1) == 1
    end

    test "{:upstream_error, 4xx, _} retried NICHT (4xx kein Server-Fehler)" do
      counter = :counters.new(1, [])

      _ =
        CloudHelper.with_retry(
          fn ->
            :counters.add(counter, 1, 1)
            {:error, {:upstream_error, 418, "teapot"}}
          end,
          initial_backoff_ms: 1,
          max_retries: 2
        )

      assert :counters.get(counter, 1) == 1
    end
  end

  describe "maybe_put/3" do
    test "nil → kein Eintrag" do
      assert %{} == CloudHelper.maybe_put(%{}, :temp, nil)
    end

    test "non-nil → put" do
      assert %{temp: 0.5} == CloudHelper.maybe_put(%{}, :temp, 0.5)
    end

    test "0 wird gesetzt (nicht falsy-confused)" do
      assert %{temp: 0} == CloudHelper.maybe_put(%{}, :temp, 0)
    end

    test "false wird gesetzt (nicht falsy-confused)" do
      assert %{flag: false} == CloudHelper.maybe_put(%{}, :flag, false)
    end
  end
end
