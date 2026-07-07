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

  alias Worker.Settings

  # Stage-Atom → Stage-Nummer für den pro-Backend-Modell-Lookup
  # (`Settings.model_for/2`, #451 Track C). Stage 1 (transcribe) hat keinen
  # Backend-Stack — Legacy-Key direkt.
  @stage_to_n %{summary: 2, epos: 3, chronik: 4}

  # HTTP-Timeout default lives in `Worker.Settings` (`:http_timeout_ms`,
  # default 10 min) so users can tune it for the size of their model. The
  # old hard-coded 120s was too tight for 30B-Modelle wie qwen3:30b-a3b auf
  # einem 8 KB Stage-3-Prompt (Issue #75).

  @impl true
  def complete(prompt, opts) do
    stage = Keyword.fetch!(opts, :stage)

    # Issue #677: optionaler Modell-Override pro Call (`:model`), sonst das
    # stage-konfigurierte Modell. Erlaubt z.B. einen stärkeren LLM-Judge als den
    # Extraktor, ohne model_stage2 global umzustellen.
    case Keyword.get(opts, :model) || stage_model(stage) do
      nil ->
        {:error, {:no_model_configured, stage}}

      model when is_binary(model) ->
        do_generate(model, prompt, opts)
    end
  end

  defp stage_model(:transcribe), do: Settings.get(:model_stage1)
  defp stage_model(stage), do: Settings.model_for(Map.fetch!(@stage_to_n, stage), :local)

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
  # Issue #50: Cache mit Stale-while-revalidate. Snapshot-Path blockt NIE
  # auf Ollama wenn ein anderer Worker / worker_prod / PR-Test-Worker das
  # selbe `localhost:11434` mit LLM-Stages hämmert. Issue #463: Cache-
  # Mechanik nach `Worker.LLM.CloudHelper.cached_list_models/2` extrahiert
  # — geshared mit den Cloud-Backends (Anthropic/OpenAI/Google).
  @models_cache_key {__MODULE__, :list_models_cache}

  @spec list_models() :: {:ok, [String.t()]} | {:error, term()}
  def list_models do
    Worker.LLM.CloudHelper.cached_list_models(@models_cache_key, &do_list_models/0)
  end

  @doc "Invalidate den list_models-Cache (z.B. nach `ollama pull <name>`)."
  @spec invalidate_models_cache() :: :ok
  def invalidate_models_cache do
    Worker.LLM.CloudHelper.invalidate_models_cache(@models_cache_key)
  end

  defp do_list_models do
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
      |> maybe_put_think(model)
      |> maybe_put(:options, build_options(opts))

    body = Jason.encode!(payload)
    request = {url, headers, ~c"application/json", body}
    # Issue #615: 600_000-Default aus CloudHelper (eine Quelle für die Konstante).
    http_opts = [
      timeout: Settings.get(:http_timeout_ms, Worker.LLM.CloudHelper.receive_timeout_ms()),
      connect_timeout: 5_000
    ]

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

  # Issue #289 Phase 1: Reasoning-Modelle emittieren per Default einen
  # `<think>…</think>`-Block vor der eigentlichen Antwort, was den JSON-Schema-
  # Mode (GBNF) sabotiert — beobachtet als Repetitions-Loops / Sprach-Salat /
  # geleakte Kanal-Marker (#700, gemma4:26b). Ollama akzeptiert seit 0.4+ einen
  # Top-Level-Parameter `think: false`, der den Thinking-Modus serverseitig
  # abschaltet. Die defensive Strip-Logik in den Stage-Parsern
  # (`strip_think_blocks/1`) bleibt als Fallback für Modelle die `think:`
  # ignorieren (qwen3:30b Bug ollama#12610).
  # Issue #589 (Cut 4): die non-binary-Catch-all-Klausel ist defensiv (model
  # kommt aus Settings, sollte binary sein — aber bei nil/Fehlkonfig fällt der
  # think:-Key einfach weg statt zu crashen). Dialyzer hält sie für unerreichbar
  # (cov); bewusst als Boundary-Hygiene behalten, nicht entfernen.
  @dialyzer {:nowarn_function, maybe_put_think: 2}
  defp maybe_put_think(payload, model) when is_binary(model) do
    if thinking_model?(model), do: Map.put(payload, :think, false), else: payload
  end

  defp maybe_put_think(payload, _model), do: payload

  # Issue #700: modell-agnostische Thinking-Detection. Die frühere Namens-
  # Heuristik (qwen3/deepseek-r1) brach bei jedem neuen Thinking-Modell —
  # gemma4 bekam kein think:false und degenerierte unter JSON-Zwang. Ollama
  # meldet die Wahrheit selbst: `POST /api/show` → `capabilities` (Liste,
  # enthält "thinking"). Einmal pro Modell abfragen + in :persistent_term
  # cachen — Capabilities ändern sich nur mit neuem Pull, dann heilt ein
  # Worker-Restart. Lookup-Fehler (Ollama offline, Modell fehlt, altes Ollama
  # ohne capabilities-Feld) werden NICHT gecacht und fallen auf die
  # Namens-Heuristik zurück.
  defp thinking_model?(model) do
    key = {__MODULE__, :thinking?, model}

    case :persistent_term.get(key, :miss) do
      :miss ->
        result = fetch_capabilities(model)

        with {:ok, _} <- result do
          :persistent_term.put(key, think_flag_from(result, model))
        end

        think_flag_from(result, model)

      cached ->
        cached
    end
  end

  # Pur + testbar: entscheidet aus dem Capabilities-Lookup-Resultat, ob
  # think:false gesetzt wird. Fallback bei Fehler = #289-Namens-Heuristik.
  @doc false
  def think_flag_from({:ok, caps}, _model) when is_list(caps), do: "thinking" in caps
  def think_flag_from(_error, model), do: reasoning_model?(model)

  defp reasoning_model?(model) do
    m = String.downcase(model)
    String.contains?(m, "qwen3") or String.contains?(m, "deepseek-r1")
  end

  defp fetch_capabilities(model) do
    endpoint = Settings.get(:local_endpoint, "http://localhost:11434")
    url = String.to_charlist("#{endpoint}/api/show")
    headers = [{~c"content-type", ~c"application/json"}]
    body = Jason.encode!(%{model: model})

    # Kurzer Timeout: der Lookup läuft im Pipeline-Pfad direkt vor dem
    # eigentlichen Generate — ein toter Ollama soll hier nicht minutenlang
    # blocken (der Generate-Call scheitert danach ohnehin mit :ollama_offline).
    http_opts = [timeout: 3_000, connect_timeout: 1_500]

    case :httpc.request(:post, {url, headers, ~c"application/json", body}, http_opts, []) do
      {:ok, {{_, 200, _}, _resp_headers, resp_body}} ->
        case Jason.decode(resp_body) do
          {:ok, %{"capabilities" => caps}} when is_list(caps) -> {:ok, caps}
          {:ok, _other} -> {:error, :no_capabilities_field}
          {:error, reason} -> {:error, {:bad_json, reason}}
        end

      {:ok, {{_, status, _}, _, body}} ->
        {:error, {:http, status, to_string(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

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
