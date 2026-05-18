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

  # Generation can be slow on small CPUs; give the call generous headroom.
  @http_timeout_ms 120_000

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

  # ─── Ollama plumbing ─────────────────────────────────────────────

  defp do_generate(model, prompt, _opts) do
    endpoint = Settings.get(:local_endpoint, "http://localhost:11434")
    url = String.to_charlist("#{endpoint}/api/generate")
    headers = [{~c"content-type", ~c"application/json"}]

    body =
      Jason.encode!(%{
        model: model,
        prompt: prompt,
        stream: false
      })

    request = {url, headers, ~c"application/json", body}
    http_opts = [timeout: @http_timeout_ms, connect_timeout: 5_000]

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
end
