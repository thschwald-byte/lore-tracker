defmodule HubWeb.LLMProxyController do
  @moduledoc """
  Hub-Proxy für Cloud-LLM-Calls (Issue #27, Phase 1a — Anthropic only).

  Worker pingt `POST /api/llm/proxy` mit Bearer-Token (siehe
  `HubWeb.WorkerAuthPlug`). Hub lädt den verschlüsselten API-Key aus
  `Hub.CloudKeys`, ruft den Provider auf, gibt Output durch.

  Phase 1a:
  - Provider `"anthropic"` only.
  - Kein Retry, kein Streaming, kein LLMCallBilled-Event — Folge-Issues.
  - Fehler-Mapping: 401 vom Provider → 502 `:upstream_auth`, 429 → 502
    `:upstream_rate_limit`, 5xx → 502 `:upstream_error`, Netz/Timeout → 504.
  """

  use HubWeb, :controller

  require Logger

  @anthropic_endpoint "https://api.anthropic.com/v1/messages"
  @anthropic_api_version "2023-06-01"
  @default_max_tokens 4096

  # Generation can take a while; req's default 30s is too tight for long
  # Stage-3-Prompts. Tune via Application config later if needed.
  @http_receive_timeout_ms 600_000

  def proxy(conn, %{"provider" => "anthropic", "model" => model, "prompt" => prompt} = params)
      when is_binary(model) and is_binary(prompt) do
    opts = Map.get(params, "opts", %{})

    case Hub.CloudKeys.get("anthropic") do
      :error ->
        conn |> put_status(:bad_request) |> json(%{error: "no_key_configured"})

      {:ok, key} ->
        case call_anthropic(key, model, prompt, opts) do
          {:ok, text, usage} ->
            json(conn, %{text: text, usage: usage})

          {:error, status, body} ->
            Logger.warning("Anthropic-Proxy: upstream #{status} body=#{inspect(body)}")
            conn |> put_status(:bad_gateway) |> json(%{error: error_code(status), status: status})

          {:network_error, reason} ->
            Logger.warning("Anthropic-Proxy: network #{inspect(reason)}")
            conn |> put_status(:gateway_timeout) |> json(%{error: "network_error"})
        end
    end
  end

  def proxy(conn, %{"provider" => provider}) do
    conn |> put_status(:not_implemented) |> json(%{error: "unknown_provider", provider: provider})
  end

  def proxy(conn, _) do
    conn |> put_status(:bad_request) |> json(%{error: "missing_params"})
  end

  # ─── Anthropic-Call ──────────────────────────────────────────────

  defp call_anthropic(key, model, prompt, opts) do
    max_tokens = Map.get(opts, "max_tokens", @default_max_tokens)
    temperature = Map.get(opts, "temperature")

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
           receive_timeout: @http_receive_timeout_ms,
           retry: false
         ) do
      {:ok, %{status: 200, body: %{"content" => content} = resp}} ->
        text = extract_text(content)
        usage = resp["usage"] || %{}
        {:ok, text, usage}

      {:ok, %{status: status, body: body}} ->
        {:error, status, body}

      {:error, reason} ->
        {:network_error, reason}
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

  defp error_code(401), do: "upstream_auth"
  defp error_code(429), do: "upstream_rate_limit"
  defp error_code(status) when status >= 500, do: "upstream_error"
  defp error_code(_), do: "upstream_other"
end
