defmodule Worker.Recording.Pipeline.Verify do
  @moduledoc """
  Issue #651 (Wahrheitsbild, Phase B): das Verify-Gate. Prüft jeden extrahierten
  Fakt gegen seine Quelle und markiert `verified?` — **Flag statt Drop**: kein
  Fakt wird gelöscht, nur `true`/`false` gesetzt. Der Render konsumiert nur
  verifizierte Fakten; unverifizierte bleiben in der Tabelle (Claims-/Quellen-UI).

  Dieser Slice: **Quell-Grounding** via NLI (`Worker.LLM.Faithfulness`-Sidecar) —
  fußt der Claim auf seinen `source_refs`-Utterances (Entailment)? Ein Fakt OHNE
  source_refs gilt als ungeerdet → `verified? = false` (nicht raten, ob er
  irgendwo im Transkript steht).

  **Attribution (richtige Figur)** ist eine eigene Verify-Achse — sie braucht die
  alias→entity-Registry (Folge-Slice) und wird dort ergänzt; bis dahin prüft das
  Gate nur das Grounding.

  Warum NLI fehlbar ist (verfehlt oblique/implizite Belege) → genau deshalb
  Flag-statt-Drop: ein False-Negative verliert keinen Fakt, er landet nur im
  Claims-UI zur menschlichen Sicht.
  """

  alias Worker.{Intents, Repo}
  alias Worker.LLM.Faithfulness

  require Logger

  @doc """
  Setzt `verified?` auf jeden Fakt — PURE, behält ALLE Fakten (Flag statt Drop).
  `verify_fn.(fact, utterances)` liefert einen Wahrheitswert pro Fakt; default ist
  das NLI-Grounding (`nli_verify_one/2`). Injizierbar für Tests ohne Sidecar.
  """
  @spec verify_facts([map()], [map()], (map(), [map()] -> boolean())) :: [map()]
  def verify_facts(facts, utterances, verify_fn \\ &__MODULE__.nli_verify_one/2)
      when is_list(facts) and is_function(verify_fn, 2) do
    Enum.map(facts, fn fact ->
      Map.put(fact, "verified?", verify_fn.(fact, utterances) == true)
    end)
  end

  @doc """
  Per-Fakt-Quell-Grounding: NLI(Claim vs. seine source_refs-Utterances).
  Ungeerdeter Fakt (keine source_refs) oder zu kurzer/leerer Claim → false.
  NLI-Fehler (Sidecar offline o.ä.) → false (defensiv; der Orchestrator
  `verify_session/2` prüft die Sidecar-Verfügbarkeit vorab, damit „alles false"
  nicht mit echtem Offline verwechselt wird).
  """
  @spec nli_verify_one(map(), [map()]) :: boolean()
  def nli_verify_one(fact, utterances) do
    refs = Map.get(fact, "source_refs") || []
    claim = Map.get(fact, "claim") || ""

    cond do
      refs == [] ->
        false

      String.trim(claim) == "" ->
        false

      true ->
        case Faithfulness.score(claim, utterances, refs) do
          {:ok, %{score: s}} -> s >= 1.0
          _ -> false
        end
    end
  end

  @doc """
  Orchestriert das Verify-Gate für eine Session: liest die extrahierten Fakten,
  groundet jeden, schreibt die `verified?`-Flags via SessionFactsExtracted
  zurück (Set-Semantik überschreibt die Fakt-Row). Sidecar offline → `{:error,
  :sidecar_offline}` (kein State-Write — sonst sähe „alles unverifiziert" wie ein
  echtes Verify-Ergebnis aus). NOCH NICHT in die Pipeline verdrahtet (Phase C).
  """
  @spec verify_session(String.t(), map()) :: {:ok, [map()]} | {:error, term()}
  def verify_session(session_id, campaign) do
    cond do
      Worker.Settings.get(:faithfulness_sidecar_url) == nil ->
        {:error, :sidecar_offline}

      true ->
        case Repo.get_session_facts(session_id) do
          nil ->
            {:error, :no_facts}

          %{facts: facts} ->
            utterances = Repo.list_utterances(session_id, limit: :all)
            verified = verify_facts(facts, utterances)

            {:ok, _} =
              Intents.publish(%{
                "kind" => Shared.Events.session_facts_extracted(),
                "session_id" => session_id,
                "campaign_id" => campaign.id,
                "facts" => verified
              })

            n_ok = Enum.count(verified, & &1["verified?"])
            Logger.info("verify_session #{session_id}: #{n_ok}/#{length(verified)} Fakten verifiziert")
            {:ok, verified}
        end
    end
  end
end
