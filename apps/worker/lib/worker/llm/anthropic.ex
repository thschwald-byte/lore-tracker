defmodule Worker.LLM.Anthropic do
  @moduledoc """
  Anthropic-Claude-Backend für die LLM-Pipeline (Issue #27, Phase 1a).

  Der Worker macht den LLM-Call **nicht direkt**, sondern via Hub-Proxy
  (`POST /api/llm/proxy`). API-Keys leben ausschließlich im Hub, verschlüsselt
  via `Hub.Vault` — der Worker sieht sie nie. Worker-Auth via dem schon
  vorhandenen Worker-Token (`Bearer <token>`).

  Stage-Setting `:model_stage{n}` muss ein Claude-Modell-Name sein (siehe
  `models/0`). Wenn `:backend_stage{n}` auf `:anthropic` steht, dispatcht
  `Worker.LLM` hier rein.

  Phase 1a: kein Retry, kein Streaming, keine Cost-Events — werden in
  Folge-Issues nachgereicht. Bei Cloud-Fehler bubbled die Pipeline den
  Fehler hoch, **kein silent Fallback auf Ollama** (siehe Issue #27).
  """

  @behaviour Worker.LLM.Backend

  require Logger

  alias Worker.Repo

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

    payload =
      %{
        provider: "anthropic",
        model: model,
        prompt: prompt,
        opts: build_opts(opts)
      }

    do_proxy_call(payload)
  end

  @impl true
  def transcribe(_audio, _opts), do: {:error, :transcribe_not_supported_by_anthropic_backend}

  # ─── Proxy-Call ─────────────────────────────────────────────────

  defp do_proxy_call(payload) do
    url = proxy_url()
    token = Repo.get_state(:hub_token)

    if is_nil(token) do
      {:error, :no_worker_token}
    else
      headers = [{"authorization", "Bearer #{token}"}, {"content-type", "application/json"}]

      case Req.post(url,
             json: payload,
             headers: headers,
             receive_timeout: @receive_timeout_ms,
             retry: false
           ) do
        {:ok, %{status: 200, body: %{"text" => text}}} ->
          {:ok, text}

        {:ok, %{status: 400, body: %{"error" => "no_key_configured"}}} ->
          {:error, :no_key_configured}

        {:ok, %{status: 502, body: %{"error" => code} = body}} ->
          Logger.warning(
            "Anthropic backend: upstream code=#{code} status=#{body["status"]} msg=#{body["message"]}"
          )

          {:error, {:upstream, code, body["status"], body["message"]}}

        {:ok, %{status: 504, body: %{"error" => "network_error"}}} ->
          {:error, :network_error}

        {:ok, %{status: status, body: body}} ->
          Logger.warning("Anthropic backend: unexpected #{status} body=#{inspect(body)}")
          {:error, {:http, status, body}}

        {:error, reason} ->
          {:error, {:transport, reason}}
      end
    end
  end

  defp proxy_url do
    base = Application.get_env(:worker, :hub_base_url) || "http://localhost:4000"
    base <> "/api/llm/proxy"
  end

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

  defp build_opts(opts) do
    %{
      "max_tokens" => Keyword.get(opts, :num_predict) || 4096,
      "temperature" => Keyword.get(opts, :temperature)
    }
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Enum.into(%{})
  end
end
