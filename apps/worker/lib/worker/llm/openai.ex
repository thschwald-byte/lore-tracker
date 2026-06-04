defmodule Worker.LLM.OpenAI do
  @moduledoc """
  OpenAI-Cloud-Backend für die LLM-Pipeline (Issue #174, analog zum
  Anthropic-Pattern aus #27).

  Wie bei Anthropic seit Etappe 5b (#162) called der Worker die OpenAI-API
  direkt mit lokalem `OPENAI_API_KEY`-Env-Var statt über einen Hub-Proxy.
  Pro-Worker-Setup: jeder Self-Hoster pflegt seine eigenen Keys auf seiner
  Worker-Maschine.

  Issue #463: Retry-Loop, HTTP-Error-Mapping, Spend-Event-Publish und
  Stage-Mapping leben in `Worker.LLM.CloudHelper`. Backend-spezifisch
  bleibt hier nur die OpenAI-Request-Shape (`messages` mit `role/content`,
  `Authorization: Bearer`-Header, `choices[].message.content`-Response).

  Stage-Setting `:model_stage{n}` muss ein OpenAI-Modell-Name sein (siehe
  `models/0`). Wenn `:backend_stage{n}` auf `:openai` steht, dispatcht
  `Worker.LLM` hier rein. Bei Cloud-Fehler bubbled die Pipeline den
  Fehler hoch, **kein silent Fallback auf Ollama**.
  """

  @behaviour Worker.LLM.Backend

  alias Worker.LLM.CloudHelper

  @openai_endpoint "https://api.openai.com/v1/chat/completions"
  @default_max_tokens 4096
  @receive_timeout_ms 600_000

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
    model = CloudHelper.model_for_stage(stage, "OpenAI")
    max_tokens = Keyword.get(opts, :num_predict) || @default_max_tokens
    temperature = Keyword.get(opts, :temperature)
    session_id = Keyword.get(opts, :session_id)

    case System.get_env("OPENAI_API_KEY") do
      key when is_binary(key) and key != "" ->
        started_at = System.monotonic_time(:millisecond)

        result =
          CloudHelper.with_retry(
            fn -> do_call(key, model, prompt, max_tokens, temperature) end,
            provider: "OpenAI"
          )

        duration_ms = System.monotonic_time(:millisecond) - started_at

        case result do
          {:ok, text, usage} ->
            CloudHelper.publish_spend_event(
              "openai",
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
  def transcribe(_audio, _opts), do: {:error, :transcribe_not_supported_by_openai_backend}

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
      {"authorization", "Bearer " <> key},
      {"content-type", "application/json"}
    ]

    @openai_endpoint
    |> Req.post(json: body, headers: headers, receive_timeout: @receive_timeout_ms, retry: false)
    |> CloudHelper.map_response("OpenAI")
    |> parse_success()
  end

  defp parse_success({:ok, %{"choices" => choices} = body}) do
    usage = Map.get(body, "usage", %{})

    {:ok, extract_text(choices),
     %{
       input_tokens: Map.get(usage, "prompt_tokens", 0),
       output_tokens: Map.get(usage, "completion_tokens", 0)
     }}
  end

  defp parse_success({:ok, other}), do: {:error, {:bad_response_shape, other}}
  defp parse_success(err), do: err

  defp extract_text([%{"message" => %{"content" => content}} | _]) when is_binary(content),
    do: content

  defp extract_text(_), do: ""
end
