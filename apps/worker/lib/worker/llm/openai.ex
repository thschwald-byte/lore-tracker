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
  @openai_models_endpoint "https://api.openai.com/v1/models"

  # Pricing-Tabelle (USD pro 1M Tokens) für `Worker.LLM.cost_for/4` (Issue
  # #177 Spend-Tracking). Modell-AUSWAHL kommt live aus `list_models/0`.
  # Unbekannte Modelle bekommen Spend-Tracking auf 0.0 USD (Token-Counts
  # bleiben sichtbar).
  @model_pricing %{
    "gpt-4o" => %{cost_input_per_1m: 2.50, cost_output_per_1m: 10.00},
    "gpt-4o-mini" => %{cost_input_per_1m: 0.15, cost_output_per_1m: 0.60},
    "o1-mini" => %{cost_input_per_1m: 3.00, cost_output_per_1m: 12.00},
    "o1-preview" => %{cost_input_per_1m: 15.00, cost_output_per_1m: 60.00},
    "o1" => %{cost_input_per_1m: 15.00, cost_output_per_1m: 60.00},
    "o3-mini" => %{cost_input_per_1m: 1.10, cost_output_per_1m: 4.40},
    "gpt-4-turbo" => %{cost_input_per_1m: 10.00, cost_output_per_1m: 30.00}
  }

  @models_cache_key {__MODULE__, :list_models_cache}

  @doc """
  Holt die verfügbaren OpenAI-Modelle live aus `GET /v1/models` (Issue
  #463). Cached via `CloudHelper.cached_list_models/2` (30s
  stale-while-revalidate).

  Filtert auf Chat-fähige Modelle (Prefix `gpt-` / `o1` / `o3` / `o4` /
  `chatgpt`; exkludiert `instruct`, `audio`, `tts`, `whisper`, `embed`,
  `moderation`, `realtime`).

  Ohne `OPENAI_API_KEY`-Env-Var: `{:error, :no_key_configured}`.
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
  def pricing(model), do: CloudHelper.pricing_lookup(@model_pricing, model)

  defp do_list_models, do: CloudHelper.with_key(:openai, &fetch_models/1)

  defp fetch_models(key) do
    headers = [{"authorization", "Bearer " <> key}]

    @openai_models_endpoint
    |> Req.get(
      headers: headers,
      receive_timeout: CloudHelper.models_receive_timeout_ms(),
      retry: false
    )
    |> CloudHelper.map_response("OpenAI")
    |> CloudHelper.parse_model_list(&extract_model_names/1)
  end

  @chat_prefixes ["gpt-", "o1", "o3", "o4", "chatgpt"]
  @chat_excludes ["instruct", "audio", "tts", "whisper", "embed", "moderation", "realtime"]

  @doc false
  def extract_model_names(%{"data" => data}) when is_list(data) do
    names =
      data
      |> Enum.map(fn
        %{"id" => id} when is_binary(id) -> id
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&chat_model?/1)

    {:ok, names}
  end

  def extract_model_names(_), do: :no_match

  defp chat_model?(id) do
    lower = String.downcase(id)

    String.starts_with?(lower, @chat_prefixes) and
      not Enum.any?(@chat_excludes, &String.contains?(lower, &1))
  end

  @impl true
  def complete(prompt, opts) do
    # Issue #615: gemeinsamer Orchestrierungs-Rahmen in CloudHelper.
    CloudHelper.run_completion(:openai, "OpenAI", prompt, opts, &do_call/6)
  end

  @impl true
  def transcribe(_audio, _opts), do: {:error, :transcribe_not_supported_by_openai_backend}

  # ─── Direct API call ─────────────────────────────────────────────

  defp do_call(key, model, prompt, max_tokens, temperature, format) do
    body =
      %{
        model: model,
        max_tokens: max_tokens,
        messages: [%{role: "user", content: prompt}]
      }
      |> CloudHelper.maybe_put(:temperature, temperature)
      |> maybe_put_response_format(format, model)

    headers = [
      {"authorization", "Bearer " <> key},
      {"content-type", "application/json"}
    ]

    @openai_endpoint
    |> Req.post(
      json: body,
      headers: headers,
      receive_timeout: CloudHelper.receive_timeout_ms(),
      retry: false
    )
    |> CloudHelper.map_response("OpenAI")
    |> parse_success()
  end

  @doc false
  def parse_success({:ok, %{"choices" => choices} = body}) do
    usage = Map.get(body, "usage", %{})

    {:ok, extract_text(choices),
     %{
       input_tokens: Map.get(usage, "prompt_tokens", 0),
       output_tokens: Map.get(usage, "completion_tokens", 0)
     }}
  end

  def parse_success({:ok, other}), do: {:error, {:bad_response_shape, other}}
  def parse_success(err), do: err

  defp extract_text([%{"message" => %{"content" => content}} | _]) when is_binary(content),
    do: content

  defp extract_text(_), do: ""

  # Issue #518: opts[:format] aus der Pipeline (JSON-Schema-Map oder
  # "json"-String) übersetzen in OpenAI's response_format-Parameter.
  #
  # - "json" → `{type: "json_object"}` (looser JSON-Mode, supported von gpt-4o+/o1+)
  # - Schema-Map → `{type: "json_schema", json_schema: {name, schema, strict}}`
  #   (strikter Mode, supported von gpt-4o-2024-08-06+). Für o1-Modelle
  #   und ältere gpt-4-Turbo fallen wir auf den looseren "json_object"-Mode
  #   zurück (o1 supportet response_format=json_object aber kein strict-schema).
  def maybe_put_response_format(body, nil, _model), do: body
  def maybe_put_response_format(body, "", _model), do: body

  def maybe_put_response_format(body, "json", _model) do
    Map.put(body, :response_format, %{type: "json_object"})
  end

  def maybe_put_response_format(body, %{} = schema, model) do
    if supports_json_schema?(model) do
      Map.put(body, :response_format, %{
        type: "json_schema",
        json_schema: %{name: "stage_output", schema: schema, strict: true}
      })
    else
      # Älteres Modell ohne strict-schema-Support — looser JSON-Mode +
      # Schema im System-Prompt (Caller-Prompt enthält das Schema ohnehin
      # üblicherweise schon, das ist Defensive).
      Map.put(body, :response_format, %{type: "json_object"})
    end
  end

  def maybe_put_response_format(body, _, _model), do: body

  def supports_json_schema?(model) when is_binary(model) do
    # gpt-4o (≥ 2024-08-06), gpt-4.x, o3+ supporten strict json_schema.
    # o1 / o1-preview / o1-mini supporten nur response_format=json_object.
    cond do
      String.starts_with?(model, "o1") -> false
      String.starts_with?(model, "gpt-4-turbo") -> false
      String.starts_with?(model, "gpt-4o") -> true
      String.starts_with?(model, "gpt-4.") -> true
      String.starts_with?(model, "o3") -> true
      String.starts_with?(model, "o4") -> true
      true -> false
    end
  end

  def supports_json_schema?(_), do: false
end
