defmodule Worker.LLM.Anthropic do
  @moduledoc """
  Anthropic-Claude-Backend für die LLM-Pipeline (Issue #27, Phase 1a).

  Issue #162 (Etappe 5b): Worker calls Anthropic-API direkt mit lokalem
  `ANTHROPIC_API_KEY`-Env-Var statt über den Hub-Proxy. Hub kennt keinen
  Cloud-Key mehr. Pro-Worker-Setup: jeder Self-Hoster pflegt seine eigenen
  Keys auf seiner Worker-Maschine.

  Stage-Setting `:model_stage{n}` muss ein Claude-Modell-Name sein (siehe
  `models/0`). Wenn `:backend_stage{n}` auf `:anthropic` steht, dispatcht
  `Worker.LLM` hier rein.

  Phase 1a: kein Retry, kein Streaming, keine Cost-Events — werden in
  Folge-Issues nachgereicht. Bei Cloud-Fehler bubbled die Pipeline den
  Fehler hoch, **kein silent Fallback auf Ollama** (siehe Issue #27).
  """

  @behaviour Worker.LLM.Backend

  require Logger

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
    model = model_for_stage(stage)
    max_tokens = Keyword.get(opts, :num_predict) || @default_max_tokens
    temperature = Keyword.get(opts, :temperature)

    case System.get_env("ANTHROPIC_API_KEY") do
      nil ->
        {:error, :no_key_configured}

      "" ->
        {:error, :no_key_configured}

      key ->
        do_direct_call(key, model, prompt, max_tokens, temperature)
    end
  end

  @impl true
  def transcribe(_audio, _opts), do: {:error, :transcribe_not_supported_by_anthropic_backend}

  # ─── Direct API call ─────────────────────────────────────────────

  defp do_direct_call(key, model, prompt, max_tokens, temperature) do
    body =
      %{
        model: model,
        max_tokens: max_tokens,
        messages: [%{role: "user", content: prompt}]
      }
      |> maybe_put(:temperature, temperature)

    headers = [
      {"x-api-key", key},
      {"anthropic-version", @anthropic_api_version},
      {"content-type", "application/json"}
    ]

    case Req.post(@anthropic_endpoint,
           json: body,
           headers: headers,
           receive_timeout: @receive_timeout_ms,
           retry: false
         ) do
      {:ok, %{status: 200, body: %{"content" => content}}} ->
        {:ok, extract_text(content)}

      {:ok, %{status: 401, body: body}} ->
        Logger.warning("Anthropic-Direct: 401 — ANTHROPIC_API_KEY ungültig: #{inspect(body)}")
        {:error, :upstream_auth}

      {:ok, %{status: 429, body: body}} ->
        Logger.warning("Anthropic-Direct: 429 rate-limit body=#{inspect(body)}")
        {:error, :upstream_rate_limit}

      {:ok, %{status: status, body: body}} when status >= 500 ->
        Logger.warning("Anthropic-Direct: #{status} upstream-error body=#{inspect(body)}")
        {:error, {:upstream_error, status, upstream_message(body)}}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Anthropic-Direct: unexpected #{status} body=#{inspect(body)}")
        {:error, {:http, status, body}}

      {:error, reason} ->
        Logger.warning("Anthropic-Direct: network #{inspect(reason)}")
        {:error, {:network_error, reason}}
    end
  end

  defp extract_text(content) when is_list(content) do
    content
    |> Enum.filter(fn part -> Map.get(part, "type") == "text" end)
    |> Enum.map(fn part -> Map.get(part, "text", "") end)
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
        other -> raise "Anthropic-Backend: kein Stage-Mapping für #{inspect(other)}"
      end

    Worker.Settings.get(key) ||
      raise "Anthropic-Backend: kein Modell für #{inspect(stage)} gesetzt (Setting #{inspect(key)})"
  end
end
