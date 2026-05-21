defmodule Worker.LLM.Local do
  @moduledoc """
  Backend for any local HTTP endpoint that speaks the Ollama API
  (`POST /api/generate`).

  Compatible with: Ollama, llama.cpp's `--server`, vLLM with the
  ollama-compat shim, LM Studio, and most Ollama drop-in alternatives.

  Reads from `Worker.Settings`:
  - `:local_endpoint` (default `http://localhost:11434`)
  - `:model_stage<N>` per stage (e.g. `:model_stage2` for summary)

  Failure modes are mapped to atoms so the pipeline can react sensibly:
  - `:ollama_offline` — connection refused / DNS / network
  - `:model_not_found` — endpoint replied 404 (typical for unpulled models)
  - `{:http, status, body}` — anything else
  """

  @behaviour Worker.LLM.Backend

  require Logger

  alias Worker.Settings

  @stage_to_model_key %{
    transcribe: :model_stage1,
    summary: :model_stage2,
    epos: :model_stage3,
    chronik: :model_stage4
  }

  # HTTP-Timeout default lives in `Worker.Settings` (`:http_timeout_ms`,
  # default 10 min) so users can tune it for the size of their model. The
  # old hard-coded 120s was too tight for 30B-Modelle wie qwen3:30b-a3b auf
  # einem 8 KB Stage-3-Prompt (Issue #75).

  @impl true
  def complete(prompt, opts) do
    stage = Keyword.fetch!(opts, :stage)

    case Settings.get(Map.fetch!(@stage_to_model_key, stage)) do
      nil ->
        {:error, {:no_model_configured, stage}}

      model when is_binary(model) ->
        do_generate(model, prompt, opts)
    end
  end

  @impl true
  def transcribe(_audio, _opts) do
    # Stage-1 over HTTP is uncommon for Ollama (which is text-only). When
    # we add an OpenAI-compatible Whisper endpoint, that's a separate
    # backend (`Worker.LLM.OpenAIWhisper`). For now, refuse explicitly.
    {:error, :transcribe_not_supported_by_local_backend}
  end

  @doc """
  Holt die lokal installierten Modelle vom konfigurierten Ollama-Endpoint
  (`GET /api/tags`). Wird vom Settings-Snapshot aufgerufen, damit das Hub-UI
  die Modell-Combobox pro Stage befüllen kann.

  Returns `{:ok, [model_name, …]}` (alphabetisch sortiert) oder `{:error, reason}`.
  Reason-Atome decken die wahrscheinlichen Failure-Modi:
  - `:ollama_offline` — Verbindung verweigert / DNS / Netz weg
  - `{:http, status, body}` — Endpoint hat geantwortet, aber kein 200
  - `{:bad_json, ...}` / `{:bad_response_shape, ...}` — Antwort unbrauchbar
  """
  @spec list_models() :: {:ok, [String.t()]} | {:error, term()}
  def list_models do
    endpoint = Settings.get(:local_endpoint, "http://localhost:11434")
    url = String.to_charlist("#{endpoint}/api/tags")

    # Tag-Listing ist billig — kurzer Timeout, damit die Settings-Page nicht
    # 120s blockiert wenn Ollama tot ist.
    http_opts = [timeout: 3_000, connect_timeout: 1_500]

    case :httpc.request(:get, {url, []}, http_opts, []) do
      {:ok, {{_, 200, _}, _resp_headers, resp_body}} ->
        case Jason.decode(resp_body) do
          {:ok, %{"models" => models}} when is_list(models) ->
            names =
              models
              |> Enum.map(fn
                %{"name" => name} when is_binary(name) -> name
                _ -> nil
              end)
              |> Enum.reject(&is_nil/1)
              |> Enum.sort()

            {:ok, names}

          {:ok, other} ->
            {:error, {:bad_response_shape, other}}

          {:error, reason} ->
            {:error, {:bad_json, reason}}
        end

      {:ok, {{_, status, _}, _, body}} ->
        {:error, {:http, status, to_string(body)}}

      {:error, {:failed_connect, _}} ->
        {:error, :ollama_offline}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ─── Ollama plumbing ─────────────────────────────────────────────

  defp do_generate(model, prompt, opts) do
    endpoint = Settings.get(:local_endpoint, "http://localhost:11434")
    url = String.to_charlist("#{endpoint}/api/generate")
    headers = [{~c"content-type", ~c"application/json"}]

    payload =
      %{
        model: model,
        prompt: prompt,
        stream: false
      }
      |> maybe_put(:format, Keyword.get(opts, :format))
      |> maybe_put(:options, build_options(opts))

    body = Jason.encode!(payload)
    request = {url, headers, ~c"application/json", body}
    http_opts = [timeout: Settings.get(:http_timeout_ms, 600_000), connect_timeout: 5_000]

    case :httpc.request(:post, request, http_opts, []) do
      {:ok, {{_, 200, _}, _resp_headers, resp_body}} ->
        case Jason.decode(resp_body) do
          {:ok, %{"response" => text}} -> {:ok, text}
          {:ok, other} -> {:error, {:bad_response_shape, other}}
          {:error, reason} -> {:error, {:bad_json, reason}}
        end

      {:ok, {{_, 404, _}, _, _}} ->
        {:error, :model_not_found}

      {:ok, {{_, status, _}, _, body}} ->
        {:error, {:http, status, to_string(body)}}

      {:error, {:failed_connect, _}} ->
        {:error, :ollama_offline}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, _key, m) when m == %{}, do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp build_options(opts) do
    Enum.reduce(
      [:num_ctx, :temperature, :num_predict, :top_p, :top_k, :repeat_penalty],
      %{},
      fn k, acc ->
        case Keyword.get(opts, k) do
          nil -> acc
          v -> Map.put(acc, k, v)
        end
      end
    )
  end
end
