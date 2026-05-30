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
  @spec score(String.t(), [map()], [binary()]) :: {:ok, score_result()} | {:error, term()}
  def score(generated_md, utterances, source_refs \\ []) do
    # Issue #114: wenn `source_refs` nicht leer ist, schränken wir die
    # Premise-Menge fürs NLI auf genau diese Utterances ein (die Stage 2
    # explizit als Quelle ausgewiesen hat). Trigram-Span-Matching auf der
    # vollen Utterance-Liste bleibt der Fallback wenn keine refs verfügbar
    # sind — z.B. bei Pre-#114-Resümees oder wenn das LLM keinen JSON-Output
    # liefern konnte.
    case Worker.Settings.get(:faithfulness_sidecar_url) do
      nil ->
        {:error, :sidecar_offline}

      url ->
        claims = split_claims(generated_md)

        if claims == [] do
          # Issue #290 (Bug 3): leerer LLM-Output ist im Sweep-Kontext immer
          # ein Fehler (das LLM hat seinen Job nicht erledigt) — leere
          # Claims dürfen nicht Bestnote 1.0 bekommen.
          {:ok, %{score: 0.0, claims: []}}
        else
          score_claims(claims, restrict_utterances(utterances, source_refs), url)
        end
    end
  end

  # Issue #114: wenn source_refs nicht leer und mindestens eine ref im
  # utterances-Set wiederfindet, schränken wir auf diese ein. Sonst fallback
  # auf full set (z.B. wenn LLM eine refs gemacht hat die der User inzwischen
  # gelöscht hat, oder refs ist leer/missing).
  defp restrict_utterances(utterances, source_refs)
       when is_list(source_refs) and source_refs != [] do
    ref_set = MapSet.new(source_refs)

    filtered =
      Enum.filter(utterances, fn u ->
        id = Map.get(u, :id) || Map.get(u, "id")
        is_binary(id) and MapSet.member?(ref_set, id)
      end)

    if filtered == [], do: utterances, else: filtered
  end

  defp restrict_utterances(utterances, _), do: utterances

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

  @doc """
  Sidecar-loser Coverage-Score [0.0, 1.0]: durchschnittlicher
  Trigram-Overlap pro Claim mit den Quell-Utterances. Ein Wert nahe 1.0
  heißt „fast alle Trigramme der Summary kommen auch im Transkript vor"
  (= wenig erfundenes/halluziniertes); ein niedriger Wert markiert
  Token-Collapse oder Wortsalat.

  Issue #281b: gedacht als Fallback fürs Probelauf-Quality-Rating wenn
  der NLI-Sidecar lokal nicht läuft. Kein 1:1-Ersatz für die NLI-
  Entailment-Semantik, aber gut genug um Pipeline-Vergiftungen
  (`Mit-Mit-Mit-Mit-Mit`) von brauchbarem Output zu unterscheiden.
  """
  @spec coverage_score(String.t(), [map()]) :: float()
  def coverage_score(generated_md, utterances) when is_binary(generated_md) do
    claims = split_claims(generated_md)

    cond do
      claims == [] and String.trim(generated_md) == "" ->
        0.0

      claims == [] ->
        1.0

      true ->
        source_trigrams =
          utterances
          |> Enum.map(fn u -> trigrams(utterance_text(u)) end)
          |> Enum.reduce(MapSet.new(), &MapSet.union/2)

        per_claim =
          Enum.map(claims, fn claim ->
            claim_trigrams = trigrams(claim)
            trigram_overlap(claim_trigrams, source_trigrams)
          end)

        Enum.sum(per_claim) / length(per_claim)
    end
  end

  def coverage_score(_, _), do: 0.0

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
