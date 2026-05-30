defmodule Worker.LLM.Google do
  @moduledoc """
  Google-Gemini-Cloud-Backend für die LLM-Pipeline (Issue #175, analog
  zum Anthropic-/OpenAI-Pattern aus #27 + #174).

  Wie bei den anderen Cloud-Backends seit Etappe 5b (#162) calld der
  Worker die Gemini-API direkt mit lokalem `GEMINI_API_KEY`-Env-Var statt
  über einen Hub-Proxy. Pro-Worker-Setup: jeder Self-Hoster pflegt seine
  eigenen Keys auf seiner Worker-Maschine.

  Stage-Setting `:model_stage{n}` muss ein Gemini-Modell-Name sein (siehe
  `models/0`). Wenn `:backend_stage{n}` auf `:google` steht, dispatcht
  `Worker.LLM` hier rein.

  Phase 1: kein Streaming (#176), keine Cost-Events (#177), kein Schema-
  Constraint via `responseSchema` (Stage 4 verlässt sich aktuell auf
  Prompting + Parser-Robustheit). Bei Cloud-Fehler bubbled die Pipeline
  den Fehler hoch, **kein silent Fallback auf Ollama**.

  Retry-Pfad: 2× exponentielles Backoff bei 429 / 5xx, dann hartes
  Aufgeben mit konkreter Fehlermeldung. 4xx ≠ 429 retry'd nicht
  (Client-Fehler).

  API-Shape-Unterschied zu OpenAI/Anthropic: Gemini erwartet die
  Prompts als `contents: [%{parts: [%{text: prompt}]}]` und sampling-
  Knöpfe unter `generationConfig`. Auth via `?key=<KEY>`-Query-Param,
  nicht via Header. Response liegt in
  `candidates[0].content.parts[0].text`.
  """

  @behaviour Worker.LLM.Backend

  require Logger

  @gemini_endpoint_base "https://generativelanguage.googleapis.com/v1beta/models"
  @default_max_tokens 4096

  @receive_timeout_ms 600_000

  @max_retries 2
  @initial_backoff_ms 500

  # Pricing-Stand 2026-05 (USD pro 1M Tokens). Quelle:
  # https://ai.google.dev/pricing — Werte ändern sich, periodisch nachziehen.
  @models [
    %{
      name: "gemini-2.5-pro",
      label: "Gemini 2.5 Pro — top reasoning",
      cost_input_per_1m: 1.25,
      cost_output_per_1m: 10.00
    },
    %{
      name: "gemini-2.5-flash",
      label: "Gemini 2.5 Flash — fast + capable",
      cost_input_per_1m: 0.30,
      cost_output_per_1m: 2.50
    },
    %{
      name: "gemini-2.0-flash",
      label: "Gemini 2.0 Flash — cheap workhorse",
      cost_input_per_1m: 0.075,
      cost_output_per_1m: 0.30
    },
    %{
      name: "gemini-2.0-flash-lite",
      label: "Gemini 2.0 Flash-Lite — cheapest",
      cost_input_per_1m: 0.075,
      cost_output_per_1m: 0.30
    }
  ]

  @doc "Statische Liste verfügbarer Gemini-Modelle (Phase 1)."
  def models, do: @models

  @impl true
  def complete(prompt, opts) do
    stage = Keyword.fetch!(opts, :stage)
    model = model_for_stage(stage)
    max_tokens = Keyword.get(opts, :num_predict) || @default_max_tokens
    temperature = Keyword.get(opts, :temperature)

    case System.get_env("GEMINI_API_KEY") do
      nil ->
        {:error, :no_key_configured}

      "" ->
        {:error, :no_key_configured}

      key ->
        do_direct_call_with_retry(key, model, prompt, max_tokens, temperature, 0)
    end
  end

  @impl true
  def transcribe(_audio, _opts), do: {:error, :transcribe_not_supported_by_google_backend}

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
      "Google-Direct: retry #{attempt + 1}/#{@max_retries} after #{delay}ms (reason=#{inspect(reason)})"
    )

    Process.sleep(delay)
    do_direct_call_with_retry(key, model, prompt, max_tokens, temperature, attempt + 1)
  end

  defp do_direct_call(key, model, prompt, max_tokens, temperature) do
    body =
      %{
        contents: [%{parts: [%{text: prompt}]}],
        generationConfig:
          %{maxOutputTokens: max_tokens}
          |> maybe_put(:temperature, temperature)
      }

    url = "#{@gemini_endpoint_base}/#{model}:generateContent?key=#{key}"

    headers = [{"content-type", "application/json"}]

    case Req.post(url,
           json: body,
           headers: headers,
           receive_timeout: @receive_timeout_ms,
           retry: false
         ) do
      {:ok, %{status: 200, body: %{"candidates" => candidates}}} ->
        {:ok, extract_text(candidates)}

      {:ok, %{status: status, body: body}} when status in [401, 403] ->
        Logger.warning("Google-Direct: #{status} — GEMINI_API_KEY ungültig: #{inspect(body)}")
        {:error, :upstream_auth}

      {:ok, %{status: 429, body: body}} ->
        Logger.warning("Google-Direct: 429 rate-limit body=#{inspect(body)}")
        {:error, :upstream_rate_limit}

      {:ok, %{status: status, body: body}} when status >= 500 ->
        Logger.warning("Google-Direct: #{status} upstream-error body=#{inspect(body)}")
        {:error, {:upstream_error, status, upstream_message(body)}}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Google-Direct: unexpected #{status} body=#{inspect(body)}")
        {:error, {:http, status, body}}

      {:error, reason} ->
        Logger.warning("Google-Direct: network #{inspect(reason)}")
        {:error, {:network_error, reason}}
    end
  end

  defp extract_text([%{"content" => %{"parts" => parts}} | _]) when is_list(parts) do
    parts
    |> Enum.map(fn
      %{"text" => t} when is_binary(t) -> t
      _ -> ""
    end)
    |> Enum.join("")
  end

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
        other -> raise "Google-Backend: kein Stage-Mapping für #{inspect(other)}"
      end

    Worker.Settings.get(key) ||
      raise "Google-Backend: kein Modell für #{inspect(stage)} gesetzt (Setting #{inspect(key)})"
  end
end
