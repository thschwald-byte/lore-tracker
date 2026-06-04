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
  @gemini_models_endpoint "https://generativelanguage.googleapis.com/v1beta/models"
  @default_max_tokens 4096
  @receive_timeout_ms 600_000

  # Pricing-Tabelle (USD pro 1M Tokens) für `Worker.LLM.cost_for/4` (Issue
  # #177 Spend-Tracking). Stand 2026-05. Quelle: https://ai.google.dev/pricing.
  # Modell-AUSWAHL kommt live aus `list_models/0` — diese Tabelle ist nur
  # die statische Preis-Referenz. Unbekannte Modelle: 0.0 USD Spend.
  @model_pricing %{
    "gemini-2.5-pro" => %{cost_input_per_1m: 1.25, cost_output_per_1m: 10.00},
    "gemini-2.5-flash" => %{cost_input_per_1m: 0.30, cost_output_per_1m: 2.50},
    "gemini-2.0-flash" => %{cost_input_per_1m: 0.075, cost_output_per_1m: 0.30},
    "gemini-2.0-flash-lite" => %{cost_input_per_1m: 0.075, cost_output_per_1m: 0.30},
    "gemini-1.5-pro" => %{cost_input_per_1m: 1.25, cost_output_per_1m: 5.00},
    "gemini-1.5-flash" => %{cost_input_per_1m: 0.075, cost_output_per_1m: 0.30}
  }

  @models_cache_key {__MODULE__, :list_models_cache}

  @doc """
  Holt die verfügbaren Gemini-Modelle live aus `GET /v1beta/models?key=…`
  (Issue #463). Cached via `CloudHelper.cached_list_models/2` (30s
  stale-while-revalidate).

  Filtert auf Modelle die `generateContent` in `supportedGenerationMethods`
  führen — Embedding-Modelle, TTS etc. fallen raus. Strippt den
  `models/`-Präfix aus dem API-Response, damit der Modell-Name direkt als
  Stage-Setting genutzt werden kann.

  Ohne `GEMINI_API_KEY`-Env-Var: `{:error, :no_key_configured}`.
  """
  @spec list_models() :: {:ok, [String.t()]} | {:error, term()}
  def list_models do
    CloudHelper.cached_list_models(@models_cache_key, &do_list_models/0)
  end

  @doc "Invalidate den list_models-Cache."
  @spec invalidate_models_cache() :: :ok
  def invalidate_models_cache do
    CloudHelper.invalidate_models_cache(@models_cache_key)
  end

  @doc """
  Pricing-Lookup für `Worker.LLM.cost_for/4`. Unbekanntes Modell → `nil`.
  """
  @spec pricing(String.t()) :: %{cost_input_per_1m: float(), cost_output_per_1m: float()} | nil
  def pricing(model) when is_binary(model), do: Map.get(@model_pricing, model)
  def pricing(_), do: nil

  defp do_list_models do
    # Issue #510: ApiKey-Lookup (Settings-first, ENV-Fallback).
    case Worker.LLM.ApiKey.get(:google) do
      nil -> {:error, :no_key_configured}
      key -> fetch_models(key)
    end
  end

  defp fetch_models(key) do
    url = "#{@gemini_models_endpoint}?key=#{key}&pageSize=1000"

    url
    |> Req.get(receive_timeout: 5_000, retry: false)
    |> CloudHelper.map_response("Google")
    |> parse_models()
  end

  defp parse_models({:ok, %{"models" => models}}) when is_list(models) do
    names =
      models
      |> Enum.filter(fn
        %{"supportedGenerationMethods" => methods} when is_list(methods) ->
          "generateContent" in methods

        _ ->
          false
      end)
      |> Enum.map(fn
        %{"name" => "models/" <> name} -> name
        %{"name" => name} when is_binary(name) -> name
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort()

    {:ok, names}
  end

  defp parse_models({:ok, other}), do: {:error, {:bad_response_shape, other}}
  defp parse_models(err), do: err

  @impl true
  def complete(prompt, opts) do
    stage = Keyword.fetch!(opts, :stage)
    model = CloudHelper.model_for_stage(stage, "Google")
    max_tokens = Keyword.get(opts, :num_predict) || @default_max_tokens
    temperature = Keyword.get(opts, :temperature)
    session_id = Keyword.get(opts, :session_id)
    format = Keyword.get(opts, :format)

    # Issue #510: erst Worker.Settings, dann Env-Var-Fallback.
    case Worker.LLM.ApiKey.get(:google) do
      nil ->
        {:error, :no_key_configured}

      key ->
        started_at = System.monotonic_time(:millisecond)

        result =
          CloudHelper.with_retry(
            fn -> do_call(key, model, prompt, max_tokens, temperature, format) end,
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
    end
  end

  @impl true
  def transcribe(_audio, _opts), do: {:error, :transcribe_not_supported_by_google_backend}

  # ─── Direct API call ─────────────────────────────────────────────

  defp do_call(key, model, prompt, max_tokens, temperature, format) do
    body = %{
      contents: [%{parts: [%{text: prompt}]}],
      generationConfig:
        %{maxOutputTokens: max_tokens}
        |> CloudHelper.maybe_put(:temperature, temperature)
        |> maybe_put_response_format(format)
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

  # Issue #518: opts[:format] aus der Pipeline (JSON-Schema-Map oder
  # "json"-String) übersetzen in Gemini's `generationConfig`-Felder.
  #
  # - "json" → `responseMimeType: "application/json"` (lockerer JSON-Mode)
  # - Schema-Map → `responseMimeType` + `responseSchema` (strikter Mode)
  def maybe_put_response_format(cfg, nil), do: cfg
  def maybe_put_response_format(cfg, ""), do: cfg

  def maybe_put_response_format(cfg, "json") do
    Map.put(cfg, :responseMimeType, "application/json")
  end

  def maybe_put_response_format(cfg, %{} = schema) do
    cfg
    |> Map.put(:responseMimeType, "application/json")
    |> Map.put(:responseSchema, to_gemini_schema(schema))
  end

  def maybe_put_response_format(cfg, _), do: cfg

  # JSON-Schema → Gemini-Schema-Konverter. Gemini erwartet OpenAPI-3-style
  # mit großgeschriebenen Type-Strings ("STRING"/"OBJECT"/…) statt JSON-
  # Schema-Konventionen ("string"/"object"/…). Subset reicht für unsere
  # Stage-2/3/4-Schemas (object/array/string/number/integer/boolean).
  def to_gemini_schema(%{} = schema) do
    Enum.reduce(schema, %{}, fn
      {"type", t}, acc when is_binary(t) -> Map.put(acc, :type, String.upcase(t))
      {"properties", props}, acc when is_map(props) ->
        Map.put(acc, :properties, Enum.into(props, %{}, fn {k, v} -> {k, to_gemini_schema(v)} end))

      {"items", items}, acc when is_map(items) -> Map.put(acc, :items, to_gemini_schema(items))
      {"required", req}, acc when is_list(req) -> Map.put(acc, :required, req)
      {"description", d}, acc when is_binary(d) -> Map.put(acc, :description, d)
      {"enum", e}, acc when is_list(e) -> Map.put(acc, :enum, e)
      # Andere JSON-Schema-Keys (additionalProperties, format, pattern, etc.)
      # ignoriert — Gemini supportet sie teils nicht, teils anders. Bei Bedarf
      # nachziehen.
      _, acc -> acc
    end)
  end
end
