defmodule Worker.LLM.OpenAI do
  @moduledoc """
  OpenAI-Cloud-Backend für die LLM-Pipeline (Issue #174, analog zum
  Anthropic-Pattern aus #27).

  Wie bei Anthropic seit Etappe 5b (#162) called der Worker die OpenAI-API
  direkt mit lokalem `OPENAI_API_KEY`-Env-Var statt über einen Hub-Proxy.
  Pro-Worker-Setup: jeder Self-Hoster pflegt seine eigenen Keys auf seiner
  Worker-Maschine.

  Stage-Setting `:model_stage{n}` muss ein OpenAI-Modell-Name sein (siehe
  `models/0`). Wenn `:backend_stage{n}` auf `:openai` steht, dispatcht
  `Worker.LLM` hier rein.

  Phase 1: kein Streaming (#176), keine Cost-Events (#177) — werden in
  Folge-Issues nachgereicht. Bei Cloud-Fehler bubbled die Pipeline den
  Fehler hoch, **kein silent Fallback auf Ollama**.

  Retry-Pfad (Issue #174 Akzeptanz): 2× exponentielles Backoff bei
  429 / 5xx, dann hartes Aufgeben mit konkreter Fehlermeldung. 4xx ≠ 429
  retry'd nicht (Client-Fehler).
  """

  @behaviour Worker.LLM.Backend

  require Logger

  @openai_endpoint "https://api.openai.com/v1/chat/completions"
  @default_max_tokens 4096

  @receive_timeout_ms 600_000

  @max_retries 2
  @initial_backoff_ms 500

  @models [
    %{
      name: "gpt-4o",
      label: "GPT-4o — flagship multimodal",
      cost_input_per_1m: 2.50,
      cost_output_per_1m: 10.00
    },
    %{
      name: "gpt-4o-mini",
      label: "GPT-4o mini — cheap + fast",
      cost_input_per_1m: 0.15,
      cost_output_per_1m: 0.60
    },
    %{
      name: "o1-mini",
      label: "o1-mini — reasoning",
      cost_input_per_1m: 3.00,
      cost_output_per_1m: 12.00
    },
    %{
      name: "o1-preview",
      label: "o1-preview — top reasoning",
      cost_input_per_1m: 15.00,
      cost_output_per_1m: 60.00
    }
  ]

  @doc "Statische Liste verfügbarer OpenAI-Modelle (Phase 1)."
  def models, do: @models

  @impl true
  def complete(prompt, opts) do
    stage = Keyword.fetch!(opts, :stage)
    model = model_for_stage(stage)
    max_tokens = Keyword.get(opts, :num_predict) || @default_max_tokens
    temperature = Keyword.get(opts, :temperature)

    case System.get_env("OPENAI_API_KEY") do
      nil ->
        {:error, :no_key_configured}

      "" ->
        {:error, :no_key_configured}

      key ->
        do_direct_call_with_retry(key, model, prompt, max_tokens, temperature, 0)
    end
  end

  @impl true
  def transcribe(_audio, _opts), do: {:error, :transcribe_not_supported_by_openai_backend}

  # ─── Direct API call with retry ───────────────────────────────────

  defp do_direct_call_with_retry(key, model, prompt, max_tokens, temperature, attempt) do
    case do_direct_call(key, model, prompt, max_tokens, temperature) do
      {:error, reason} when reason in [:upstream_rate_limit] and attempt < @max_retries ->
        backoff_and_retry(key, model, prompt, max_tokens, temperature, attempt, reason)

      {:error, {:upstream_error, status, _msg}} when status >= 500 and attempt < @max_retries ->
        backoff_and_retry(key, model, prompt, max_tokens, temperature, attempt, status)

      {:error, {:network_error, _}} when attempt < @max_retries ->
        backoff_and_retry(key, model, prompt, max_tokens, temperature, attempt, :network)

      other ->
        other
    end
  end

  defp backoff_and_retry(key, model, prompt, max_tokens, temperature, attempt, reason) do
    delay = @initial_backoff_ms * Bitwise.bsl(1, attempt)

    Logger.info(
      "OpenAI-Direct: retry #{attempt + 1}/#{@max_retries} after #{delay}ms (reason=#{inspect(reason)})"
    )

    Process.sleep(delay)
    do_direct_call_with_retry(key, model, prompt, max_tokens, temperature, attempt + 1)
  end

  defp do_direct_call(key, model, prompt, max_tokens, temperature) do
    body =
      %{
        model: model,
        max_tokens: max_tokens,
        messages: [%{role: "user", content: prompt}]
      }
      |> maybe_put(:temperature, temperature)

    headers = [
      {"authorization", "Bearer " <> key},
      {"content-type", "application/json"}
    ]

    case Req.post(@openai_endpoint,
           json: body,
           headers: headers,
           receive_timeout: @receive_timeout_ms,
           retry: false
         ) do
      {:ok, %{status: 200, body: %{"choices" => choices}}} ->
        {:ok, extract_text(choices)}

      {:ok, %{status: 401, body: body}} ->
        Logger.warning("OpenAI-Direct: 401 — OPENAI_API_KEY ungültig: #{inspect(body)}")
        {:error, :upstream_auth}

      {:ok, %{status: 429, body: body}} ->
        Logger.warning("OpenAI-Direct: 429 rate-limit body=#{inspect(body)}")
        {:error, :upstream_rate_limit}

      {:ok, %{status: status, body: body}} when status >= 500 ->
        Logger.warning("OpenAI-Direct: #{status} upstream-error body=#{inspect(body)}")
        {:error, {:upstream_error, status, upstream_message(body)}}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("OpenAI-Direct: unexpected #{status} body=#{inspect(body)}")
        {:error, {:http, status, body}}

      {:error, reason} ->
        Logger.warning("OpenAI-Direct: network #{inspect(reason)}")
        {:error, {:network_error, reason}}
    end
  end

  defp extract_text([%{"message" => %{"content" => content}} | _]) when is_binary(content),
    do: content

  defp extract_text(_), do: ""

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp upstream_message(%{"error" => %{"message" => msg}}) when is_binary(msg), do: msg
  defp upstream_message(_), do: nil

  defp model_for_stage(stage) do
    key =
      case stage do
        :summary -> :model_stage2
        :epos -> :model_stage3
        :chronik -> :model_stage4
        other -> raise "OpenAI-Backend: kein Stage-Mapping für #{inspect(other)}"
      end

    Worker.Settings.get(key) ||
      raise "OpenAI-Backend: kein Modell für #{inspect(stage)} gesetzt (Setting #{inspect(key)})"
  end
end
