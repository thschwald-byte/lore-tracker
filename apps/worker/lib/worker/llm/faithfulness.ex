defmodule Worker.LLM.Faithfulness do
  @moduledoc """
  Faithfulness-Scoring for generated session summaries (Issue #11 Phase 2).

  Calls the NLI sidecar (apps/worker/priv/sidecar/faithfulness_sidecar.py)
  once per claim extracted from the generated text, checking whether each
  claim is entailed by the source transcript.

  Score = fraction of claims whose NLI top label is "entailment".

  Graceful fallback: if the sidecar URL is not configured or the sidecar is
  unreachable, returns {:error, :sidecar_offline}.  Callers should treat this
  as a non-fatal skip, not a pipeline failure.
  """

  require Logger

  @sidecar_timeout_ms 10_000

  @type claim_result :: %{
          text: String.t(),
          span: String.t(),
          label: String.t()
        }

  @type score_result :: %{
          score: float(),
          claims: [claim_result()]
        }

  @doc """
  Score `generated_md` against `utterances` (list of maps with "text" key).

  Returns `{:ok, %{score: float, claims: [...]}}` or `{:error, reason}`.
  """
  @spec score(String.t(), [map()]) :: {:ok, score_result()} | {:error, term()}
  def score(generated_md, utterances) do
    case Worker.Settings.get(:faithfulness_sidecar_url) do
      nil ->
        {:error, :sidecar_offline}

      url ->
        claims = split_claims(generated_md)

        if claims == [] do
          {:ok, %{score: 1.0, claims: []}}
        else
          score_claims(claims, utterances, url)
        end
    end
  end

  # ─── Claim segmentation ──────────────────────────────────────────────

  @doc false
  def split_claims(text) do
    text
    |> String.replace(~r/\n+/, " ")
    |> String.split(~r/(?<=[.!?])\s+/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(fn s -> String.length(s) < 8 end)
  end

  # ─── Span matching ───────────────────────────────────────────────────

  @doc false
  def best_span(claim, utterances) do
    claim_trigrams = trigrams(claim)

    utterances
    |> Enum.max_by(
      fn utt ->
        utt_trigrams = trigrams(utterance_text(utt))
        trigram_overlap(claim_trigrams, utt_trigrams)
      end,
      fn -> %{} end
    )
    |> utterance_text()
  end

  # Repo.list_utterances/1 liefert atom-key Maps; Snapshots/JSON-Wire-Daten
  # bringen string-keys — beide Fälle akzeptieren, damit die Faithfulness-
  # Stage auch in Snapshot-Tests ohne Mnesia-Roundtrip funktioniert.
  defp utterance_text(utt) when is_map(utt) do
    Map.get(utt, :text) || Map.get(utt, "text") || ""
  end

  defp utterance_text(_), do: ""

  defp trigrams(text) do
    words = text |> String.downcase() |> String.split(~r/\s+/, trim: true)

    if length(words) < 3 do
      MapSet.new(words)
    else
      words
      |> Enum.chunk_every(3, 1, :discard)
      |> Enum.map(&Enum.join(&1, " "))
      |> MapSet.new()
    end
  end

  defp trigram_overlap(set_a, set_b) do
    if MapSet.size(set_a) == 0 do
      0.0
    else
      intersection = MapSet.intersection(set_a, set_b) |> MapSet.size()
      intersection / MapSet.size(set_a)
    end
  end

  # ─── NLI scoring ─────────────────────────────────────────────────────

  defp score_claims(claims, utterances, sidecar_url) do
    pairs =
      Enum.map(claims, fn claim ->
        span = best_span(claim, utterances)
        {claim, span}
      end)

    url = String.to_charlist("#{sidecar_url}/score_batch")
    headers = [{~c"content-type", ~c"application/json"}]

    body =
      Jason.encode!(
        Enum.map(pairs, fn {claim, span} ->
          %{premise: span, hypothesis: claim}
        end)
      )

    request = {url, headers, ~c"application/json", body}
    http_opts = [timeout: @sidecar_timeout_ms, connect_timeout: 3_000]

    case :httpc.request(:post, request, http_opts, []) do
      {:ok, {{_, 200, _}, _resp_headers, resp_body}} ->
        parse_batch_response(resp_body, pairs)

      {:ok, {{_, status, _}, _, resp_body}} ->
        Logger.warning("Faithfulness sidecar returned #{status}: #{resp_body}")
        {:error, {:sidecar_error, status}}

      {:error, {:failed_connect, _}} ->
        {:error, :sidecar_offline}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_batch_response(resp_body, pairs) do
    case Jason.decode(resp_body) do
      {:ok, results} when is_list(results) ->
        claims =
          Enum.zip(pairs, results)
          |> Enum.map(fn {{claim_text, span}, result} ->
            %{
              text: claim_text,
              span: span,
              label: result["label"] || "neutral"
            }
          end)

        entailment_count =
          Enum.count(claims, fn c -> c.label == "entailment" end)

        score = if length(claims) > 0, do: entailment_count / length(claims), else: 1.0

        {:ok, %{score: Float.round(score, 3), claims: claims}}

      {:ok, other} ->
        {:error, {:bad_response_shape, other}}

      {:error, reason} ->
        {:error, {:bad_json, reason}}
    end
  end
end
