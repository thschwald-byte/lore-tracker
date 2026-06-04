defmodule Worker.LLM.Anthropic do
  @moduledoc """
  Anthropic-Claude-Backend für die LLM-Pipeline (Issue #27, Phase 1a).

  Issue #162 (Etappe 5b): Worker calls Anthropic-API direkt mit lokalem
  `ANTHROPIC_API_KEY`-Env-Var statt über den Hub-Proxy. Hub kennt keinen
  Cloud-Key mehr. Pro-Worker-Setup: jeder Self-Hoster pflegt seine eigenen
  Keys auf seiner Worker-Maschine.

  Issue #463: Retry-Loop, HTTP-Error-Mapping, Spend-Event-Publish und
  Stage-Mapping leben in `Worker.LLM.CloudHelper`. Backend-spezifisch
  bleibt hier nur die Anthropic-Request-Shape (`messages` mit `role/content`,
  `x-api-key`-Header, `content`-Array-Response).

  Stage-Setting `:model_stage{n}` muss ein Claude-Modell-Name sein (siehe
  `models/0`). Wenn `:backend_stage{n}` auf `:anthropic` steht, dispatcht
  `Worker.LLM` hier rein. Bei Cloud-Fehler bubbled die Pipeline den
  Fehler hoch, **kein silent Fallback auf Ollama**.
  """

  @behaviour Worker.LLM.Backend

  alias Worker.LLM.CloudHelper

  @anthropic_endpoint "https://api.anthropic.com/v1/messages"
  @anthropic_api_version "2023-06-01"
  @default_max_tokens 4096
  @receive_timeout_ms 600_000

  @models [
    %{
      name: "claude-opus-4-7",
      label: "Claude Opus 4.7 — strongest reasoning",
      cost_input_per_1m: 15.00,
      cost_output_per_1m: 75.00
    },
    %{
      name: "claude-sonnet-4-6",
      label: "Claude Sonnet 4.6 — balanced default",
      cost_input_per_1m: 3.00,
      cost_output_per_1m: 15.00
    },
    %{
      name: "claude-haiku-4-5-20251001",
      label: "Claude Haiku 4.5 — fast + cheap",
      cost_input_per_1m: 1.00,
      cost_output_per_1m: 5.00
    }
  ]

  @doc "Statische Liste verfügbarer Anthropic-Modelle (Phase 1a)."
  def models, do: @models

  @impl true
  def complete(prompt, opts) do
    stage = Keyword.fetch!(opts, :stage)
    model = CloudHelper.model_for_stage(stage, "Anthropic")
    max_tokens = Keyword.get(opts, :num_predict) || @default_max_tokens
    temperature = Keyword.get(opts, :temperature)
    session_id = Keyword.get(opts, :session_id)

    case System.get_env("ANTHROPIC_API_KEY") do
      key when is_binary(key) and key != "" ->
        started_at = System.monotonic_time(:millisecond)

        result =
          CloudHelper.with_retry(
            fn -> do_call(key, model, prompt, max_tokens, temperature) end,
            provider: "Anthropic"
          )

        duration_ms = System.monotonic_time(:millisecond) - started_at

        # Issue #177: bei Erfolg ein LLMCallBilled-Event publishen.
        # Failed calls (4xx/5xx/network) emittieren NICHT — kein USD-Verbrauch.
        # Issue #463: publish_spend_event lebt im CloudHelper (geshared mit
        # OpenAI/Google), nicht mehr local in jedem Backend-Modul.
        case result do
          {:ok, text, usage} ->
            CloudHelper.publish_spend_event(
              "anthropic",
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
  def transcribe(_audio, _opts), do: {:error, :transcribe_not_supported_by_anthropic_backend}

  # ─── Direct API call ─────────────────────────────────────────────

  defp do_call(key, model, prompt, max_tokens, temperature) do
    body =
      %{
        model: model,
        max_tokens: max_tokens,
        messages: [%{role: "user", content: prompt}]
      }
      |> CloudHelper.maybe_put(:temperature, temperature)

    headers = [
      {"x-api-key", key},
      {"anthropic-version", @anthropic_api_version},
      {"content-type", "application/json"}
    ]

    @anthropic_endpoint
    |> Req.post(json: body, headers: headers, receive_timeout: @receive_timeout_ms, retry: false)
    |> CloudHelper.map_response("Anthropic")
    |> parse_success()
  end

  defp parse_success({:ok, %{"content" => content} = body}) do
    usage = Map.get(body, "usage", %{})

    {:ok, extract_text(content),
     %{
       input_tokens: Map.get(usage, "input_tokens", 0),
       output_tokens: Map.get(usage, "output_tokens", 0)
     }}
  end

  defp parse_success({:ok, other}), do: {:error, {:bad_response_shape, other}}
  defp parse_success(err), do: err

  defp extract_text(content) when is_list(content) do
    content
    |> Enum.filter(fn part -> Map.get(part, "type") == "text" end)
    |> Enum.map(fn part -> Map.get(part, "text", "") end)
    |> Enum.join("")
  end

  defp extract_text(_), do: ""
end
