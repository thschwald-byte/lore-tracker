defmodule Worker.LLM.Google do
  @moduledoc """
  Google-Gemini-Cloud-Backend für die LLM-Pipeline (Issue #175, analog
  zum Anthropic-/OpenAI-Pattern aus #27 + #174).

  Wie bei den anderen Cloud-Backends seit Etappe 5b (#162) calld der
  Worker die Gemini-API direkt mit lokalem `GEMINI_API_KEY`-Env-Var statt
  über einen Hub-Proxy. Pro-Worker-Setup: jeder Self-Hoster pflegt seine
  eigenen Keys auf seiner Worker-Maschine.

  Issue #463: Retry-Loop, HTTP-Error-Mapping, Spend-Event-Publish und
  Stage-Mapping leben in `Worker.LLM.CloudHelper`. Backend-spezifisch
  bleibt hier die Gemini-Request-Shape (`contents/parts`,
  `generationConfig.maxOutputTokens`, Auth via `?key=`-Query-Param) und
  das `candidates[].content.parts[].text`-Response-Parsing.

  Stage-Setting `:model_stage{n}` muss ein Gemini-Modell-Name sein (siehe
  `models/0`). Wenn `:backend_stage{n}` auf `:google` steht, dispatcht
  `Worker.LLM` hier rein. Bei Cloud-Fehler bubbled die Pipeline den
  Fehler hoch, **kein silent Fallback auf Ollama**.

  Phase 1: kein Streaming (#176), kein Schema-Constraint via
  `responseSchema` (Stage 4 verlässt sich aktuell auf Prompting + Parser-
  Robustheit).
  """

  @behaviour Worker.LLM.Backend

  alias Worker.LLM.CloudHelper

  @gemini_endpoint_base "https://generativelanguage.googleapis.com/v1beta/models"
  @default_max_tokens 4096
  @receive_timeout_ms 600_000

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
    model = CloudHelper.model_for_stage(stage, "Google")
    max_tokens = Keyword.get(opts, :num_predict) || @default_max_tokens
    temperature = Keyword.get(opts, :temperature)
    session_id = Keyword.get(opts, :session_id)

    case System.get_env("GEMINI_API_KEY") do
      key when is_binary(key) and key != "" ->
        started_at = System.monotonic_time(:millisecond)

        result =
          CloudHelper.with_retry(
            fn -> do_call(key, model, prompt, max_tokens, temperature) end,
            provider: "Google"
          )

        duration_ms = System.monotonic_time(:millisecond) - started_at

        case result do
          {:ok, text, usage} ->
            CloudHelper.publish_spend_event(
              "google",
              model,
              usage,
              session_id,
              stage,
              duration_ms
            )

            {:ok, text}

          other ->
            other
        end

      _ ->
        {:error, :no_key_configured}
    end
  end

  @impl true
  def transcribe(_audio, _opts), do: {:error, :transcribe_not_supported_by_google_backend}

  # ─── Direct API call ─────────────────────────────────────────────

  defp do_call(key, model, prompt, max_tokens, temperature) do
    body = %{
      contents: [%{parts: [%{text: prompt}]}],
      generationConfig:
        %{maxOutputTokens: max_tokens}
        |> CloudHelper.maybe_put(:temperature, temperature)
    }

    url = "#{@gemini_endpoint_base}/#{model}:generateContent?key=#{key}"
    headers = [{"content-type", "application/json"}]

    url
    |> Req.post(json: body, headers: headers, receive_timeout: @receive_timeout_ms, retry: false)
    |> CloudHelper.map_response("Google")
    |> parse_success()
  end

  defp parse_success({:ok, %{"candidates" => candidates} = body}) do
    usage = Map.get(body, "usageMetadata", %{})

    {:ok, extract_text(candidates),
     %{
       input_tokens: Map.get(usage, "promptTokenCount", 0),
       output_tokens: Map.get(usage, "candidatesTokenCount", 0)
     }}
  end

  defp parse_success({:ok, other}), do: {:error, {:bad_response_shape, other}}
  defp parse_success(err), do: err

  defp extract_text([%{"content" => %{"parts" => parts}} | _]) when is_list(parts) do
    parts
    |> Enum.map(fn
      %{"text" => t} when is_binary(t) -> t
      _ -> ""
    end)
    |> Enum.join("")
  end

  defp extract_text(_), do: ""
end
