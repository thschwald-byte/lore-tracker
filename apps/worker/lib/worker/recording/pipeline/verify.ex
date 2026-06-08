defmodule Worker.Recording.Pipeline.Verify do
  @moduledoc """
  Issue #651 (Wahrheitsbild, Phase B): das Verify-Gate. Prüft jeden extrahierten
  Fakt gegen seine Quelle und markiert `verified?` — **Flag statt Drop**: kein
  Fakt wird gelöscht, nur `true`/`false` gesetzt. Der Render konsumiert nur
  verifizierte Fakten; unverifizierte bleiben in der Tabelle (Claims-/Quellen-UI).

  **Zwei orthogonale Verify-Achsen** (`verified? = grounded? AND attributed?`):

  1. **Quell-Grounding** (#666) via NLI (`Worker.LLM.Faithfulness`-Sidecar) — fußt
     der Claim auf seinen `source_refs`-Utterances (Entailment)? Ein Fakt OHNE
     source_refs gilt als ungeerdet → `grounded? = false` (nicht raten, ob er
     irgendwo im Transkript steht).
  2. **Attribution** (#669) — ist der Fakt der RICHTIGEN Figur zugeordnet? Eine
     eigene Fehlerachse, die ein reiner Propositions-Check nicht fängt: „u17
     stützt die Aussage" sagt nichts darüber, ob die Aussage dem König oder Irene
     gehört. Beim Skandal-Fixture (der EINE SL spricht alle NPCs, die Figur lebt
     nur im Text) haben „der König beauftragt Holmes" und „Irene beauftragt
     Holmes" dieselbe Quelle, aber nur eine Attribution ist korrekt. Prüft pro
     Fakt, ob die im Quell-Kontext handelnde/sprechende Figur die zugeordnete ist
     — unter Berücksichtigung der **Koreferenz** (König = Graf von Kramm), die aus
     der alias→entity-Registry (#667) stammt: Fakten mit gleicher kanonischer
     `entity_id` sind die Guise-Gruppe, ihre `character_alias`-Oberflächenformen
     speisen den Attributions-Prompt. Kein Extra-Registry-Call zur Verify-Zeit.

  Beide Sub-Flags (`grounded?` / `attributed?`) werden zusätzlich zu `verified?`
  persistiert, damit das Claims-/Quellen-UI zeigen kann, an WELCHER Achse ein
  Fakt scheiterte.

  Warum die LLM-/NLI-Urteile fehlbar sind (verfehlen oblique/implizite Belege) →
  genau deshalb Flag-statt-Drop: ein False-Negative verliert keinen Fakt, er
  landet nur im Claims-UI zur menschlichen Sicht.

  NOCH NICHT in die Pipeline verdrahtet (Phase C).
  """

  alias Worker.{Intents, Repo}
  alias Worker.LLM
  alias Worker.LLM.Faithfulness

  require Logger

  @doc """
  Setzt `grounded?` / `attributed?` / `verified?` auf jeden Fakt — PURE, behält
  ALLE Fakten (Flag statt Drop). `opts`:

  - `:ground_fn` — `(fact, utterances -> boolean())`, default NLI-Grounding
    (`nli_verify_one/2`).
  - `:attr_fn` — `(fact, utterances, aliases -> boolean())`, default
    LLM-Attribution (`attribution_verify_one/3`).

  Beide injizierbar für Tests ohne Sidecar/LLM. Die Koreferenz-Aliase pro Fakt
  werden aus den Fakten selbst abgeleitet (`alias_groups/1`).

  **Short-Circuit**: Attribution wird nur geprüft, wenn der Fakt geerdet ist — ein
  ungeerdeter Fakt ist ohnehin `verified? = false`, der (teure) Attributions-Call
  entfällt. `attributed?` ist damit für ungeerdete Fakten immer `false`; `verified?`
  bleibt das maßgebliche Konsum-Flag.
  """
  @spec verify_facts([map()], [map()], keyword()) :: [map()]
  def verify_facts(facts, utterances, opts \\ []) when is_list(facts) and is_list(opts) do
    ground_fn = Keyword.get(opts, :ground_fn, &__MODULE__.nli_verify_one/2)
    attr_fn = Keyword.get(opts, :attr_fn, &__MODULE__.attribution_verify_one/3)
    groups = alias_groups(facts)

    Enum.map(facts, fn fact ->
      grounded = ground_fn.(fact, utterances) == true

      aliases =
        Map.get(
          groups,
          Map.get(fact, "entity_id"),
          List.wrap(blank_to_nil(fact["character_alias"]))
        )

      attributed = grounded and attr_fn.(fact, utterances, aliases) == true

      fact
      |> Map.put("grounded?", grounded)
      |> Map.put("attributed?", attributed)
      |> Map.put("verified?", grounded and attributed)
    end)
  end

  @doc """
  Koreferenz-Gruppen: `%{entity_id => [distinkte character_alias-Oberflächenformen]}`.
  Die Registry (#667) hat `entity_id` bereits kanonisiert — Fakten mit gleicher
  `entity_id` SIND die Guise-Gruppe, ihre `character_alias`-Werte die
  Oberflächenformen (König, Graf von Kramm, der König …). PURE.
  """
  @spec alias_groups([map()]) :: %{optional(String.t()) => [String.t()]}
  def alias_groups(facts) when is_list(facts) do
    facts
    |> Enum.reduce(%{}, fn fact, acc ->
      case blank_to_nil(Map.get(fact, "entity_id")) do
        nil ->
          acc

        entity_id ->
          surface = blank_to_nil(Map.get(fact, "character_alias"))
          Map.update(acc, entity_id, List.wrap(surface), &maybe_prepend(surface, &1))
      end
    end)
    |> Map.new(fn {k, v} -> {k, v |> Enum.reverse() |> Enum.uniq()} end)
  end

  defp maybe_prepend(nil, list), do: list
  defp maybe_prepend(surface, list), do: [surface | list]

  defp blank_to_nil(s) when is_binary(s) do
    case String.trim(s) do
      "" -> nil
      t -> t
    end
  end

  defp blank_to_nil(_), do: nil

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
  Per-Fakt-Attribution: gehört der Claim der RICHTIGEN Figur? Liest die
  `source_refs`-Utterances (auf diese restringiert) und fragt das LLM, ob die im
  Quelltext handelnde/sprechende Figur die zugeordnete ist — `aliases` ist die
  Koreferenz-Gruppe (alle Oberflächenformen derselben kanonischen Entität, via
  `alias_groups/1`), damit „der König" und „Graf von Kramm" als dieselbe Figur
  zählen. JSON `{"match": bool}`.

  Defensiv → `false`: kein Alias (Fakt ohne zugeordnete Figur ist nicht
  attribuierbar), keine source_refs (ungeerdet — wird wegen Short-Circuit ohnehin
  nicht erreicht), leerer Claim, LLM-/Parse-Fehler. Konsistent mit
  `nli_verify_one/2`: im Zweifel nicht durchwinken (Flag-statt-Drop fängt das
  False-Negative im Claims-UI ab). Injizierbar — der LLM-Call ist die I/O-Grenze.
  """
  @spec attribution_verify_one(map(), [map()], [String.t()]) :: boolean()
  def attribution_verify_one(fact, utterances, aliases) do
    refs = Map.get(fact, "source_refs") || []
    claim = String.trim(Map.get(fact, "claim") || "")
    figures = Enum.filter(List.wrap(aliases), &(is_binary(&1) and String.trim(&1) != ""))

    cond do
      figures == [] -> false
      refs == [] -> false
      claim == "" -> false
      true -> llm_attribution(claim, restrict_to_refs(utterances, refs), figures)
    end
  end

  # Quelltext auf die source_refs-Utterances einschränken (analog
  # Faithfulness.restrict_utterances/2): ist keine ref im Set wiederfindbar (z.B.
  # gelöschte Utterance), fällt es auf die volle Liste zurück — besser ein
  # breiterer Kontext als gar keiner.
  defp restrict_to_refs(utterances, refs) do
    ref_set = MapSet.new(refs)

    filtered =
      Enum.filter(utterances, fn u ->
        id = Map.get(u, :id) || Map.get(u, "id")
        is_binary(id) and MapSet.member?(ref_set, id)
      end)

    if filtered == [], do: utterances, else: filtered
  end

  defp llm_attribution(claim, utterances, figures) do
    prompt = attribution_prompt(claim, utterances, figures)
    opts = [format: attribution_json_schema(), num_ctx: Worker.Settings.get(:ctx_stage2, 8192)]

    with {:ok, raw} <- LLM.complete(:summary, prompt, opts),
         {:ok, %{"match" => match}} <- Jason.decode(raw) do
      match == true
    else
      _ -> false
    end
  end

  @doc false
  def attribution_prompt(claim, utterances, figures) do
    source = utterances |> Enum.map_join("\n", fn u -> "- " <> utterance_text(u) end)
    names = Enum.join(figures, ", ")

    """
    Unten steht ein QUELLTEXT (Mitschnitt-Ausschnitt) und eine AUSSAGE, die einer
    bestimmten Figur zugeordnet wurde. Prüfe NUR die Attribution: Ist die Figur,
    die im Quelltext die in der Aussage beschriebene Handlung ausführt bzw. die
    Aussage trifft, dieselbe wie die zugeordnete Figur?

    Die zugeordnete Figur kann im Quelltext unter verschiedenen Bezeichnungen
    auftreten (Titel, Eigenname, Verkleidung) — alle gelten als DIESELBE Figur:
    #{names}

    Antworte mit JSON `{"match": true}`, wenn die handelnde/sprechende Figur im
    Quelltext eine dieser Bezeichnungen ist. `{"match": false}`, wenn die Handlung
    im Quelltext einer ANDEREN Figur gehört oder der Quelltext die Zuordnung nicht
    stützt.

    QUELLTEXT:
    #{source}

    AUSSAGE (zugeordnet an: #{names}):
    #{claim}
    """
  end

  defp attribution_json_schema do
    %{
      "type" => "object",
      "properties" => %{"match" => %{"type" => "boolean"}},
      "required" => ["match"]
    }
  end

  defp utterance_text(u) when is_map(u), do: Map.get(u, :text) || Map.get(u, "text") || ""
  defp utterance_text(_), do: ""

  @doc """
  Orchestriert das Verify-Gate für eine Session: liest die extrahierten Fakten,
  prüft beide Achsen (Grounding + Attribution), schreibt `verified?` + die
  Sub-Flags `grounded?`/`attributed?` via SessionFactsExtracted zurück (Set-
  Semantik überschreibt die Fakt-Row). Sidecar offline → `{:error,
  :sidecar_offline}` (kein State-Write — sonst sähe „alles unverifiziert" wie ein
  echtes Verify-Ergebnis aus); das Grounding ist Voraussetzung, ohne es greift der
  Attributions-Short-Circuit ohnehin. NOCH NICHT in die Pipeline verdrahtet (Phase C).
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

            Logger.info(
              "verify_session #{session_id}: #{n_ok}/#{length(verified)} Fakten verifiziert"
            )

            {:ok, verified}
        end
    end
  end
end
