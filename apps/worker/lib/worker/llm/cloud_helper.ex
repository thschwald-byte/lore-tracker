defmodule Worker.LLM.CloudHelper do
  @moduledoc """
  Gemeinsamer Code-Pfad für die drei Cloud-LLM-Backends
  (`Worker.LLM.Anthropic`, `Worker.LLM.OpenAI`, `Worker.LLM.Google`).

  Issue #463: zentralisiert was vorher byte-identisch in allen drei Modulen
  stand — Retry-Loop, HTTP-Error-Mapping, Spend-Event-Publish, Stage-→-Model-
  Setting-Lookup. Backend-spezifisch bleibt nur die Request-Body-Shape, das
  Response-Parsing aus dem 200-Body und die Auth-Mechanik (Header vs.
  Query-Param).

  Auch ein **Vertrags-Fix**: 401 UND 403 mappen jetzt überall auf
  `:upstream_auth` — vorher tat das nur Google (`google.ex:168`), Anthropic
  und OpenAI ließen 403 in die generische `{:http, 403, _}`-Klausel fallen,
  obwohl CLAUDE.md den 401/403-Vertrag für alle drei behauptet.
  """

  require Logger

  alias Worker.LLM

  @default_max_retries 2
  @default_initial_backoff_ms 500

  # Issue #615: Magic-Number-Konstanten zentral (vorher je dreifach in
  # anthropic/openai/google + die 600_000 nochmal als local.ex-Default).
  @default_max_tokens 4096
  # Completion-Call-Timeout (lange Stage-3/4-Outputs). Pendant zum
  # local.ex-`:http_timeout_ms`-Default.
  @receive_timeout_ms 600_000
  # Models-List-Call-Timeout (kurz — nur Metadaten).
  @models_receive_timeout_ms 5_000

  @doc "Default max_tokens für Cloud-Completions (#615)."
  @spec default_max_tokens() :: pos_integer()
  def default_max_tokens, do: @default_max_tokens

  @doc "Receive-Timeout (ms) für Cloud-Completion-Calls (#615)."
  @spec receive_timeout_ms() :: pos_integer()
  def receive_timeout_ms, do: @receive_timeout_ms

  @doc "Receive-Timeout (ms) für Models-List-Calls (#615)."
  @spec models_receive_timeout_ms() :: pos_integer()
  def models_receive_timeout_ms, do: @models_receive_timeout_ms

  @doc """
  Generischer Retry-Loop. `fun` ist eine 0-arity-Funktion die
  `{:ok, …}` oder `{:error, reason}` liefert.

  Retried bei `:upstream_rate_limit`, `{:upstream_error, status, _}` mit
  `status >= 500` und `{:network_error, _}`. Alles andere (incl. 4xx ≠ 429
  und `:upstream_auth`) bubbled sofort hoch — Client-Fehler sind nicht
  retry-würdig.

  Opts:
  - `:provider` — String fürs Logging (z.B. `"Anthropic"`). Default `"Cloud"`.
  - `:max_retries` — Default 2.
  - `:initial_backoff_ms` — Default 500. Exp-Backoff: 500ms / 1s / 2s / …
  """
  @spec with_retry((-> term()), keyword()) :: term()
  def with_retry(fun, opts \\ []) when is_function(fun, 0) do
    provider = Keyword.get(opts, :provider, "Cloud")
    max_retries = Keyword.get(opts, :max_retries, @default_max_retries)
    initial = Keyword.get(opts, :initial_backoff_ms, @default_initial_backoff_ms)
    do_retry(fun, provider, max_retries, initial, 0)
  end

  defp do_retry(fun, provider, max, initial, attempt) do
    case fun.() do
      {:error, :upstream_rate_limit} when attempt < max ->
        backoff(provider, initial, attempt, max, :rate_limit)
        do_retry(fun, provider, max, initial, attempt + 1)

      {:error, {:upstream_error, status, _msg}} when status >= 500 and attempt < max ->
        backoff(provider, initial, attempt, max, status)
        do_retry(fun, provider, max, initial, attempt + 1)

      {:error, {:network_error, _}} when attempt < max ->
        backoff(provider, initial, attempt, max, :network)
        do_retry(fun, provider, max, initial, attempt + 1)

      other ->
        other
    end
  end

  defp backoff(provider, initial, attempt, max, reason) do
    delay = initial * Bitwise.bsl(1, attempt)

    Logger.info(
      "#{provider}-Direct: retry #{attempt + 1}/#{max} after #{delay}ms (reason=#{inspect(reason)})"
    )

    Process.sleep(delay)
  end

  @doc """
  Mappt ein `Req.post`-Resultat auf das gemeinsame Atom-Schema.

  - `{:ok, %{status: 200, body: body}}` → `{:ok, body}` (Backend parsed weiter)
  - `{:ok, %{status: 401|403, …}}` → `{:error, :upstream_auth}`
  - `{:ok, %{status: 429, …}}` → `{:error, :upstream_rate_limit}`
  - `{:ok, %{status: status, …}}` mit `status >= 500` → `{:error, {:upstream_error, status, msg}}`
  - sonst 4xx → `{:error, {:http, status, body}}`
  - `{:error, reason}` → `{:error, {:network_error, reason}}`

  `provider` ist nur fürs Logging — pure Function in jeder anderen Hinsicht
  (keine GenServer-Calls, kein Mnesia-Hit), deshalb gut testbar.
  """
  @spec map_response({:ok, term()} | {:error, term()}, String.t()) ::
          {:ok, term()} | {:error, term()}
  def map_response({:ok, %{status: 200, body: body}}, _provider), do: {:ok, body}

  def map_response({:ok, %{status: status, body: body}}, provider) when status in [401, 403] do
    Logger.warning(
      "#{provider}-Direct: #{status} — API-Key ungültig oder verweigert: #{inspect(body)}"
    )

    {:error, :upstream_auth}
  end

  def map_response({:ok, %{status: 429, body: body}}, provider) do
    Logger.warning("#{provider}-Direct: 429 rate-limit body=#{inspect(body)}")
    {:error, :upstream_rate_limit}
  end

  def map_response({:ok, %{status: status, body: body}}, provider) when status >= 500 do
    Logger.warning("#{provider}-Direct: #{status} upstream-error body=#{inspect(body)}")
    {:error, {:upstream_error, status, upstream_message(body)}}
  end

  def map_response({:ok, %{status: status, body: body}}, provider) do
    Logger.warning("#{provider}-Direct: unexpected #{status} body=#{inspect(body)}")
    {:error, {:http, status, body}}
  end

  def map_response({:error, reason}, provider) do
    Logger.warning("#{provider}-Direct: network #{inspect(reason)}")
    {:error, {:network_error, reason}}
  end

  @doc "Map.put nur wenn value nicht nil — spart Verzweigung an Call-Sites."
  @spec maybe_put(map(), atom(), term()) :: map()
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc """
  Publisht ein `LLMCallBilled`-Event (Issue #177) nach erfolgreichem
  Cloud-Call. Crash-resistent via `try/rescue` — wenn `Worker.Intents.publish`
  oder `Worker.Repo.get_state` failed, geht das Spend-Event still verloren,
  aber der Pipeline-Flow stört es nicht (Issue #463 Edge: vorher unsupervised
  Task.start → Crash hätte das Event still verloren, Spend-Cap unterzählt).

  `provider` ist `"anthropic"` / `"openai"` / `"google"` (der Provider-String
  wie in `LLM.cost_for/4`-Lookup verwendet).
  """
  @spec publish_spend_event(
          String.t(),
          String.t(),
          map(),
          term(),
          atom(),
          non_neg_integer()
        ) :: :ok
  def publish_spend_event(provider, model, usage, session_id, stage, duration_ms) do
    # Issue #571: Worker.TaskSupervisor statt bare Task.start — Spend-
    # Tracking ist load-bearing (Spend-Cap-Underflow ist genau der Drift,
    # den #475/#177 ausschließen wollen). try/rescue im Body fängt schon
    # Application-Level-Errors; der Supervisor fängt die OS-Level-Klasse
    # (Memory, Limits) und Spawn-Failures, die Task.start still verschluckt.
    Task.Supervisor.start_child(Worker.TaskSupervisor, fn ->
      try do
        input = Map.get(usage, :input_tokens, 0)
        output = Map.get(usage, :output_tokens, 0)
        cost = LLM.cost_for(provider, model, input, output)
        admin = Worker.Repo.get_state(:admin_discord_id)

        _ =
          Worker.Intents.publish(%{
            "kind" => Shared.Events.llm_call_billed(),
            "provider" => provider,
            "model" => model,
            "input_tokens" => input,
            "output_tokens" => output,
            "cost_usd" => cost,
            "requested_by_discord_id" => admin,
            "session_id" => session_id,
            "stage" => LLM.stage_label(stage),
            "duration_ms" => duration_ms
          })
      rescue
        e ->
          Logger.warning(
            "CloudHelper.publish_spend_event crashed (provider=#{provider}, model=#{model}): #{Exception.message(e)}"
          )
      end
    end)

    :ok
  end

  @doc """
  Stage-Atom → pro-Backend-Modell-Lookup (`Settings.model_for/2`, #451 Track C),
  mit klarem Raise wenn weder Stage-Mapping noch Modell konfiguriert sind.
  Seit #786 gibt es nur noch den `:summary`-Slot. `provider` ist das
  Backend-Atom (`:anthropic | :openai | :google`); `provider_label` geht nur
  in die Fehlermeldung.
  """
  @spec model_for_stage(atom(), atom(), String.t()) :: String.t()
  def model_for_stage(stage, provider, provider_label) do
    n =
      case stage do
        :summary -> 2
        other -> raise "#{provider_label}-Backend: kein Stage-Mapping für #{inspect(other)}"
      end

    Worker.Settings.model_for(n, provider) ||
      raise "#{provider_label}-Backend: kein Modell für #{inspect(stage)} gesetzt " <>
              "(Setting model_stage#{n}_#{provider})"
  end

  @doc """
  Issue #615: API-Key-Lookup (Settings-first via `LLM.ApiKey.get/1`, ENV-
  Fallback) mit dem gemeinsamen `:no_key_configured`-Vertrag. `fun` bekommt
  den Key und liefert das Resultat — sonst `{:error, :no_key_configured}`.
  Genutzt von `run_completion/5` und den `do_list_models`-Schalen.
  """
  @spec with_key(atom(), (String.t() -> term())) :: term()
  def with_key(provider, fun) when is_atom(provider) and is_function(fun, 1) do
    case LLM.ApiKey.get(provider) do
      nil -> {:error, :no_key_configured}
      key -> fun.(key)
    end
  end

  @doc """
  Issue #615: der gemeinsame `complete/2`-Orchestrierungs-Rahmen aller drei
  Cloud-Backends. Kapselt Key-Lookup, Opts-Parsing (Stage→Modell — ein
  expliziter `:model`-Override wie `judge_model`/`render_model` gewinnt, #783 —
  max_tokens, temperature, session_id, format), Timing, Retry-Wrapper,
  Spend-Event und Unwrap `{:ok, text, usage}` → `{:ok, text}`.

  Backend-spezifisch bleibt nur `do_call_fn`, eine 6-arity-Funktion
  `(key, model, prompt, max_tokens, temperature, format) -> {:ok, text, usage}
  | {:error, reason}` (die Request-Shape + das Response-Parsing). Anthropic
  reicht hier seinen Temperature-400-Fallback-Wrapper rein.

  - `provider` — `:anthropic | :openai | :google` (für ApiKey + Spend-String).
  - `label` — `"Anthropic"` etc. (Logging + Stage-Mapping-Fehlertext).
  """
  @spec run_completion(
          atom(),
          String.t(),
          String.t(),
          keyword(),
          (String.t(), String.t(), String.t(), pos_integer(), float() | nil, term() ->
             {:ok, String.t(), map()} | {:error, term()})
        ) :: {:ok, String.t()} | {:error, term()}
  def run_completion(provider, label, prompt, opts, do_call_fn)
      when is_atom(provider) and is_function(do_call_fn, 6) do
    stage = Keyword.fetch!(opts, :stage)
    # #783: expliziter :model-Override (judge_model/render_model) schlägt den
    # Stage-Lookup — vorher wirkten die Overrides nur auf dem Local-Backend
    # (Worker.LLM.Local honoriert opts[:model] seit jeher, dieser Pfad nicht).
    model = Keyword.get(opts, :model) || model_for_stage(stage, provider, label)
    max_tokens = Keyword.get(opts, :num_predict) || @default_max_tokens
    temperature = Keyword.get(opts, :temperature)
    session_id = Keyword.get(opts, :session_id)
    format = Keyword.get(opts, :format)

    with_key(provider, fn key ->
      started_at = System.monotonic_time(:millisecond)

      result =
        with_retry(
          fn -> do_call_fn.(key, model, prompt, max_tokens, temperature, format) end,
          provider: label
        )

      duration_ms = System.monotonic_time(:millisecond) - started_at

      case result do
        {:ok, text, usage} ->
          publish_spend_event(
            Atom.to_string(provider),
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
    end)
  end

  @doc """
  Issue #615: gemeinsamer `pricing/1`-Lookup. Unbekanntes/nicht-binäres Modell
  → `nil` (cost_for/4 fällt dann auf 0.0 USD zurück). `table` ist die backend-
  spezifische `@model_pricing`-Map.
  """
  @spec pricing_lookup(map(), term()) :: map() | nil
  def pricing_lookup(table, model) when is_binary(model), do: Map.get(table, model)
  def pricing_lookup(_table, _model), do: nil

  @doc """
  Issue #615: gemeinsamer `parse_models`-Tail. `extractor` zieht aus dem
  200-Body die Modell-Namen (`{:ok, [name]}`) oder `:no_match` bei fremder
  Shape. Ergebnis wird sortiert; `:no_match` → `{:error, {:bad_response_shape,
  body}}`; ein durchgereichter `{:error, _}` bleibt unverändert.
  """
  @spec parse_model_list(
          {:ok, term()} | {:error, term()},
          (term() -> {:ok, [String.t()]} | :no_match)
        ) :: {:ok, [String.t()]} | {:error, term()}
  def parse_model_list({:ok, body}, extractor) when is_function(extractor, 1) do
    case extractor.(body) do
      {:ok, names} -> {:ok, Enum.sort(names)}
      :no_match -> {:error, {:bad_response_shape, body}}
    end
  end

  def parse_model_list(err, _extractor), do: err

  defp upstream_message(%{"error" => %{"message" => msg}}) when is_binary(msg), do: msg
  defp upstream_message(_), do: nil

  # ─── list_models/0 Cache (Issue #463 — Backend-aware Model-Picker) ────

  @list_models_cache_ttl_ms 30_000

  @doc """
  Stale-while-revalidate-Cache für `list_models/0`-Calls. Erster Call ist
  synchron, nachfolgende returns cached, stale Calls refreshen im
  Hintergrund. Fehler werden NICHT gecached — die letzte gute Antwort
  bleibt erhalten (verhindert flackernde UI bei kurzem API-Aussetzer).

  `cache_key` ist ein `:persistent_term`-Key (typisch `{Module, :list_models}`).
  `fetch_fun` ist eine 0-arity-Funktion die `{:ok, list} | {:error, reason}`
  liefert.

  Vorher inline in `Worker.LLM.Local` (Issue #50); mit den Cloud-list_models
  (Anthropic/OpenAI/Google) in CloudHelper extrahiert.
  """
  @spec cached_list_models(term(), (-> {:ok, list()} | {:error, term()})) ::
          {:ok, list()} | {:error, term()}
  def cached_list_models(cache_key, fetch_fun) when is_function(fetch_fun, 0) do
    case :persistent_term.get(cache_key, nil) do
      {ts, cached} when is_integer(ts) ->
        age = System.monotonic_time(:millisecond) - ts

        if age > @list_models_cache_ttl_ms do
          # Issue #571: fire-and-forget — stale-while-revalidate. Crash der
          # Refresh-Task hält den Cache stale bis zum nächsten Call (UI sieht
          # noch valid cached). Supervisor würde Reload nicht verbessern.
          # credo:disable-for-next-line LoreTracker.Credo.Check.UnsupervisedTaskStart
          Task.start(fn -> do_fetch_and_cache(cache_key, fetch_fun) end)
        end

        cached

      _ ->
        do_fetch_and_cache(cache_key, fetch_fun)
    end
  end

  @doc "Invalidate den list_models-Cache für `cache_key`."
  @spec invalidate_models_cache(term()) :: :ok
  def invalidate_models_cache(cache_key) do
    :persistent_term.erase(cache_key)
    :ok
  end

  defp do_fetch_and_cache(cache_key, fetch_fun) do
    result = fetch_fun.()

    case result do
      {:ok, _} ->
        :persistent_term.put(cache_key, {System.monotonic_time(:millisecond), result})

      _ ->
        :ok
    end

    result
  end
end
