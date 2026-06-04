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
    Logger.warning("#{provider}-Direct: #{status} — API-Key ungültig oder verweigert: #{inspect(body)}")
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
    Task.start(fn ->
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
  Stage-Atom → Settings-Key + Modell-Name-Lookup, mit klarem Raise wenn
  weder Stage-Mapping noch Modell konfiguriert sind. `provider_label` geht
  nur in die Fehlermeldung.
  """
  @spec model_for_stage(atom(), String.t()) :: String.t()
  def model_for_stage(stage, provider_label) do
    key =
      case stage do
        :summary -> :model_stage2
        :epos -> :model_stage3
        :chronik -> :model_stage4
        other -> raise "#{provider_label}-Backend: kein Stage-Mapping für #{inspect(other)}"
      end

    Worker.Settings.get(key) ||
      raise "#{provider_label}-Backend: kein Modell für #{inspect(stage)} gesetzt (Setting #{inspect(key)})"
  end

  defp upstream_message(%{"error" => %{"message" => msg}}) when is_binary(msg), do: msg
  defp upstream_message(_), do: nil
end
