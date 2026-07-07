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

  describe "cached_list_models/2 — stale-while-revalidate" do
    setup do
      # Eindeutiger Cache-Key pro Test damit parallel-async-Tests sich nicht
      # gegenseitig den `:persistent_term`-Stand klauen.
      key = {__MODULE__, :test, System.unique_integer([:positive])}
      on_exit(fn -> CloudHelper.invalidate_models_cache(key) end)
      {:ok, key: key}
    end

    test "erster Call ist synchron + cached", %{key: key} do
      counter = :counters.new(1, [])

      result =
        CloudHelper.cached_list_models(key, fn ->
          :counters.add(counter, 1, 1)
          {:ok, ["a", "b"]}
        end)

      assert {:ok, ["a", "b"]} = result
      assert :counters.get(counter, 1) == 1

      # Zweiter Call mit gleichem Key returnt sofort cached, OHNE fetch_fun.
      result2 =
        CloudHelper.cached_list_models(key, fn ->
          :counters.add(counter, 1, 1)
          {:ok, ["c"]}
        end)

      assert {:ok, ["a", "b"]} = result2
      assert :counters.get(counter, 1) == 1
    end

    test "Fehler wird NICHT gecached — nächster Call versucht erneut", %{key: key} do
      counter = :counters.new(1, [])

      r1 =
        CloudHelper.cached_list_models(key, fn ->
          :counters.add(counter, 1, 1)
          {:error, :upstream_auth}
        end)

      assert {:error, :upstream_auth} = r1
      assert :counters.get(counter, 1) == 1

      # Zweiter Call: Cache leer (weil Fehler nicht gecached wurde) →
      # synchroner Refetch.
      r2 =
        CloudHelper.cached_list_models(key, fn ->
          :counters.add(counter, 1, 1)
          {:ok, ["recovered"]}
        end)

      assert {:ok, ["recovered"]} = r2
      assert :counters.get(counter, 1) == 2
    end

    test "invalidate_models_cache/1 entfernt den Cache-Eintrag", %{key: key} do
      _ = CloudHelper.cached_list_models(key, fn -> {:ok, ["x"]} end)
      assert :ok = CloudHelper.invalidate_models_cache(key)

      counter = :counters.new(1, [])

      _ =
        CloudHelper.cached_list_models(key, fn ->
          :counters.add(counter, 1, 1)
          {:ok, ["y"]}
        end)

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

  # Issue #615: zentralisierter pricing/1-Lookup + parse_models-Tail.
  describe "pricing_lookup/2" do
    test "bekanntes Modell → Map" do
      table = %{"m" => %{cost_input_per_1m: 1.0, cost_output_per_1m: 2.0}}
      assert %{cost_input_per_1m: 1.0} = CloudHelper.pricing_lookup(table, "m")
    end

    test "unbekanntes Modell → nil" do
      assert nil == CloudHelper.pricing_lookup(%{}, "x")
    end

    test "nicht-binäres Modell → nil (kein crash)" do
      assert nil == CloudHelper.pricing_lookup(%{}, nil)
      assert nil == CloudHelper.pricing_lookup(%{}, :atom)
    end
  end

  describe "parse_model_list/2" do
    test "{:ok, body} + Extractor → sortierte Namen" do
      result =
        CloudHelper.parse_model_list({:ok, %{"d" => ["b", "a"]}}, fn %{"d" => d} -> {:ok, d} end)

      assert {:ok, ["a", "b"]} == result
    end

    test ":no_match → :bad_response_shape mit Body" do
      assert {:error, {:bad_response_shape, %{"x" => 1}}} ==
               CloudHelper.parse_model_list({:ok, %{"x" => 1}}, fn _ -> :no_match end)
    end

    test "durchgereichter Fehler bleibt unverändert" do
      assert {:error, :upstream_auth} ==
               CloudHelper.parse_model_list({:error, :upstream_auth}, fn _ -> {:ok, []} end)
    end
  end

  # Issue #615: zentrale Magic-Number-Getter (#658: Coverage-Floor).
  describe "Konstanten-Getter" do
    test "default_max_tokens/receive_timeout/models_receive_timeout sind positive Ints" do
      assert is_integer(CloudHelper.default_max_tokens()) and CloudHelper.default_max_tokens() > 0
      assert is_integer(CloudHelper.receive_timeout_ms()) and CloudHelper.receive_timeout_ms() > 0

      assert is_integer(CloudHelper.models_receive_timeout_ms()) and
               CloudHelper.models_receive_timeout_ms() > 0

      # Models-List-Timeout ist kurz, Completion-Timeout lang.
      assert CloudHelper.models_receive_timeout_ms() < CloudHelper.receive_timeout_ms()
    end
  end

  describe "model_for_stage/3 — unbekannte Stage" do
    test "raised mit Provider-Label (vor jedem Settings-Hit, daher pure)" do
      assert_raise RuntimeError, ~r/TestProv-Backend: kein Stage-Mapping/, fn ->
        CloudHelper.model_for_stage(:nope, :anthropic, "TestProv")
      end
    end
  end
end
