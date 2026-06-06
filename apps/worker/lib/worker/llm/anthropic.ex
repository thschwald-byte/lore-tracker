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

  require Logger

  alias Worker.LLM.CloudHelper

  @anthropic_endpoint "https://api.anthropic.com/v1/messages"
  @anthropic_models_endpoint "https://api.anthropic.com/v1/models"
  @anthropic_api_version "2023-06-01"

  # Pricing-Tabelle (USD pro 1M Tokens) für `Worker.LLM.cost_for/4` (Issue
  # #177 Spend-Tracking). Die Modell-AUSWAHL kommt live aus `list_models/0`
  # via Anthropic-API; diese Tabelle ist nur die statische Preis-Referenz
  # für bekannte Modelle. Unbekannte Modelle (neue Releases zwischen den
  # Tabellen-Updates) bekommen Spend-Tracking auf 0.0 USD — der Spend
  # zeigt dann nur Token-Counts, kein USD (gewünschtes Failure-Mode statt
  # falsche Beträge zu erfinden).
  @model_pricing %{
    "claude-opus-4-7" => %{cost_input_per_1m: 15.00, cost_output_per_1m: 75.00},
    "claude-opus-4-1-20250805" => %{cost_input_per_1m: 15.00, cost_output_per_1m: 75.00},
    "claude-sonnet-4-6" => %{cost_input_per_1m: 3.00, cost_output_per_1m: 15.00},
    "claude-sonnet-4-5-20250929" => %{cost_input_per_1m: 3.00, cost_output_per_1m: 15.00},
    "claude-haiku-4-5-20251001" => %{cost_input_per_1m: 1.00, cost_output_per_1m: 5.00},
    "claude-3-5-sonnet-20241022" => %{cost_input_per_1m: 3.00, cost_output_per_1m: 15.00},
    "claude-3-5-haiku-20241022" => %{cost_input_per_1m: 0.80, cost_output_per_1m: 4.00}
  }

  @models_cache_key {__MODULE__, :list_models_cache}

  @doc """
  Holt die verfügbaren Anthropic-Modelle live aus `GET /v1/models` (Issue
  #463 — kein hardcoded `@models`). Cached via
  `CloudHelper.cached_list_models/2` (30s stale-while-revalidate).

  Ohne `ANTHROPIC_API_KEY`-Env-Var: `{:error, :no_key_configured}`.
  Liste ist sortiert. Returnt nur die Modell-IDs (`"claude-..."`).
  """
  @spec list_models() :: {:ok, [String.t()]} | {:error, term()}
  def list_models do
    CloudHelper.cached_list_models(@models_cache_key, &do_list_models/0)
  end

  @doc "Invalidate den list_models-Cache (z.B. wenn neue Modelle erscheinen)."
  @spec invalidate_models_cache() :: :ok
  def invalidate_models_cache do
    CloudHelper.invalidate_models_cache(@models_cache_key)
  end

  @doc """
  Pricing-Lookup für `Worker.LLM.cost_for/4` (Spend-Tracking). Unbekanntes
  Modell → `nil` (cost_for/4 fällt dann auf 0.0 USD zurück).
  """
  @spec pricing(String.t()) :: %{cost_input_per_1m: float(), cost_output_per_1m: float()} | nil
  def pricing(model), do: CloudHelper.pricing_lookup(@model_pricing, model)

  defp do_list_models, do: CloudHelper.with_key(:anthropic, &fetch_models/1)

  defp fetch_models(key) do
    headers = [
      {"x-api-key", key},
      {"anthropic-version", @anthropic_api_version}
    ]

    @anthropic_models_endpoint
    |> Req.get(
      headers: headers,
      params: [limit: 1000],
      receive_timeout: CloudHelper.models_receive_timeout_ms(),
      retry: false
    )
    |> CloudHelper.map_response("Anthropic")
    |> CloudHelper.parse_model_list(&extract_model_names/1)
  end

  @doc false
  def extract_model_names(%{"data" => data}) when is_list(data) do
    names =
      data
      |> Enum.map(fn
        %{"id" => id} when is_binary(id) -> id
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    {:ok, names}
  end

  def extract_model_names(_), do: :no_match

  @impl true
  def complete(prompt, opts) do
    # Issue #615: gemeinsamer Orchestrierungs-Rahmen in CloudHelper. Anthropic-
    # spezifisch bleibt nur der do_call-Wrapper mit dem Temperature-400-Fallback.
    CloudHelper.run_completion(:anthropic, "Anthropic", prompt, opts, &do_call_temp_fallback/6)
  end

  # Manche neueren Anthropic-Modelle (z.B. Reasoning-/Thinking-Modelle) lehnen
  # `temperature` mit 400 "temperature is deprecated for this model" ab. Statt
  # die Stage hart scheitern zu lassen: genau einmal ohne temperature retrien
  # (modell-agnostisch — kein per-Modell-Flag nötig).
  defp do_call_temp_fallback(key, model, prompt, max_tokens, temperature, format) do
    case do_call(key, model, prompt, max_tokens, temperature, format) do
      {:error, {:http, 400, body}} = err ->
        if not is_nil(temperature) and temperature_deprecated?(body) do
          Logger.warning(
            "Anthropic: Modell #{model} akzeptiert `temperature` nicht mehr " <>
              "(deprecated) — Retry ohne temperature."
          )

          do_call(key, model, prompt, max_tokens, nil, format)
        else
          err
        end

      other ->
        other
    end
  end

  @doc false
  # 400-Body von Anthropic: %{"error" => %{"message" => "..."}}.
  def temperature_deprecated?(%{"error" => %{"message" => msg}}) when is_binary(msg) do
    m = String.downcase(msg)
    String.contains?(m, "temperature") and String.contains?(m, "deprecat")
  end

  def temperature_deprecated?(_), do: false

  @impl true
  def transcribe(_audio, _opts), do: {:error, :transcribe_not_supported_by_anthropic_backend}

  # ─── Direct API call ─────────────────────────────────────────────

  defp do_call(key, model, prompt, max_tokens, temperature, format) do
    body =
      %{
        model: model,
        max_tokens: max_tokens,
        messages: [%{role: "user", content: prompt}]
      }
      |> CloudHelper.maybe_put(:temperature, temperature)
      |> maybe_force_json(format)

    headers = [
      {"x-api-key", key},
      {"anthropic-version", @anthropic_api_version},
      {"content-type", "application/json"}
    ]

    @anthropic_endpoint
    |> Req.post(
      json: body,
      headers: headers,
      receive_timeout: CloudHelper.receive_timeout_ms(),
      retry: false
    )
    |> CloudHelper.map_response("Anthropic")
    |> parse_success()
  end

  @doc false
  # Issue #518: opts[:format] aus der Pipeline (JSON-Schema-Map oder
  # "json"-String) übersetzen. Anthropic hat keinen response_format-Knopf
  # wie OpenAI — prompted-JSON via System-Prompt ist bei Opus/Sonnet 4.x
  # zuverlässig genug. Schema (wenn ein Map) wird im System-Prompt
  # eingebettet, damit Claude die genaue Shape sieht. Public für Tests.
  def maybe_force_json(body, nil), do: body
  def maybe_force_json(body, ""), do: body

  def maybe_force_json(body, "json") do
    Map.put(
      body,
      :system,
      "Antworte AUSSCHLIESSLICH mit einem gültigen JSON-Objekt. " <>
        "Kein Markdown, keine Code-Fences (kein ```json), keine Vorrede, kein Schluss-Satz. " <>
        "Nur das JSON-Objekt selbst."
    )
  end

  def maybe_force_json(body, %{} = schema) do
    schema_json = Jason.encode!(schema, pretty: true)

    Map.put(
      body,
      :system,
      "Antworte AUSSCHLIESSLICH mit einem gültigen JSON-Objekt das dem folgenden JSON-Schema entspricht:\n\n" <>
        schema_json <>
        "\n\nKein Markdown, keine Code-Fences (kein ```json), keine Vorrede, kein Schluss-Satz. " <>
        "Nur das JSON-Objekt selbst."
    )
  end

  def maybe_force_json(body, _), do: body

  @doc false
  def parse_success({:ok, %{"content" => content} = body}) do
    usage = Map.get(body, "usage", %{})

    {:ok, extract_text(content),
     %{
       input_tokens: Map.get(usage, "input_tokens", 0),
       output_tokens: Map.get(usage, "output_tokens", 0)
     }}
  end

  def parse_success({:ok, other}), do: {:error, {:bad_response_shape, other}}
  def parse_success(err), do: err

  defp extract_text(content) when is_list(content) do
    content
    |> Enum.filter(fn part -> Map.get(part, "type") == "text" end)
    |> Enum.map(fn part -> Map.get(part, "text", "") end)
    |> Enum.join("")
  end

  defp extract_text(_), do: ""
end
