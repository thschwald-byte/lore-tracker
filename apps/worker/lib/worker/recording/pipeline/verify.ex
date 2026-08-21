defmodule Worker.Recording.Pipeline.Verify do
  @moduledoc """
  Issue #651 (Wahrheitsbild, Phase B): das Verify-Gate. Prüft jeden extrahierten
  Fakt gegen seine Quelle und markiert `verified?` — **Flag statt Drop**: kein
  Fakt wird gelöscht, nur `true`/`false` gesetzt. Der Render konsumiert nur
  verifizierte Fakten; unverifizierte bleiben in der Tabelle (Claims-/Quellen-UI).

  **Zwei orthogonale Verify-Achsen** (`verified? = grounded? AND attributed?`):

  1. **Quell-Grounding** (#666, seit #1124 als LLM-as-Judge) — fußt
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

     **#762-Kalibrierung** (Free-Seattle-Referenz-Lauf: 100/192 grounded Fakten
     fielen an dieser Achse, davon 85 Sprecher-Attributionen + 11 figurenlose):

     - Der Attributions-QUELLTEXT trägt **Sprecher-Labels** (`Name: Text`, via
       `speaker_names`) — ohne sie kann der Judge eine Sprecher-Attribution
       („Skrapnik erklärte die Drachen-Historie") strukturell nie bestätigen,
       weil der nackte Utterance-Text den Sprecher nicht enthält.
     - **Figurenlose Fakten** (kein `character_alias`) sind attributions-
       **frei**, nicht attributions-gescheitert: es gibt keine Zuordnung, die
       falsch sein könnte — der Inhalt ist bereits über das Grounding geprüft.
       `attributed? = true` (vacuous), `verified?` hängt nur am Grounding.

  Beide Sub-Flags (`grounded?` / `attributed?`) werden zusätzlich zu `verified?`
  persistiert, damit das Claims-/Quellen-UI zeigen kann, an WELCHER Achse ein
  Fakt scheiterte.

  Warum die LLM-Urteile fehlbar sind (verfehlen oblique/implizite Belege) →
  genau deshalb Flag-statt-Drop: ein False-Negative verliert keinen Fakt, er
  landet nur im Claims-UI zur menschlichen Sicht.

  NOCH NICHT in die Pipeline verdrahtet (Phase C).
  """

  alias Worker.Recording.Pipeline.Fortschritt
  alias Worker.{Intents, Repo}
  alias Worker.LLM

  require Logger

  @doc """
  Setzt `grounded?` / `attributed?` / `verified?` auf jeden Fakt — PURE, behält
  ALLE Fakten (Flag statt Drop). `opts`:

  - `:ground_fn` — `(fact, utterances -> boolean())`, default
    `llm_grounding_one/2`.
  - `:attr_fn` — `(fact, utterances, aliases -> boolean())`, default
    LLM-Attribution (`attribution_verify_one/4`, mit `:speaker_names` gebunden).
  - `:speaker_names` — `%{discord_id => Anzeigename}` (#762): labelt die
    Quelltext-Zeilen im Attributions-Prompt, damit Sprecher-Attributionen
    prüfbar sind. Default `%{}` (Zeilen bleiben ungelabelt).

  Beide Fns injizierbar für Tests ohne Sidecar/LLM. Die Koreferenz-Aliase pro
  Fakt werden aus den Fakten selbst abgeleitet (`alias_groups/1`).

  - `:coref_facts` — Korpus für die Koreferenz-Gruppen, Default: `facts` selbst.
    Entkoppelt „welche Fakten werden verifiziert" von „welcher Korpus bildet die
    Guise-Gruppen" (Issue #996): der Dirty-`:reextract`-Pfad (#866) verifiziert
    NUR die neu adoptierten Fakten — Oberflächenformen, die ausschließlich in den
    carry-over-Fakten stehen, wären für deren Attributions-Prüfung sonst
    unsichtbar und kippen Guise-Fälle in falsche Negative.

  **Short-Circuit**: Attribution wird nur geprüft, wenn der Fakt geerdet ist — ein
  ungeerdeter Fakt ist ohnehin `verified? = false`, der (teure) Attributions-Call
  entfällt. `attributed?` ist damit für ungeerdete Fakten immer `false`; `verified?`
  bleibt das maßgebliche Konsum-Flag.
  """
  @spec verify_facts([map()], [map()], keyword()) :: [map()]
  def verify_facts(facts, utterances, opts \\ []) when is_list(facts) and is_list(opts) do
    ground_fn = Keyword.get(opts, :ground_fn, &__MODULE__.ground_one/2)
    speaker_names = Keyword.get(opts, :speaker_names, %{})

    attr_fn =
      Keyword.get(opts, :attr_fn, fn fact, utts, aliases ->
        attribution_verify_one(fact, utts, aliases, speaker_names)
      end)

    groups = opts |> Keyword.get(:coref_facts, facts) |> alias_groups()

    # Issue #1122: die Prüfung ist die Stufe mit den meisten Einheiten (ein
    # Fakt = ein Grounding-Call, bei geerdeten zusätzlich Attribution). Ohne
    # Zahl steht die Anzeige minutenlang auf „Prüfung" ohne Regung.
    ctx = %{session_id: Keyword.get(opts, :session_id)}
    Fortschritt.gesamt(ctx, "verify", length(facts))

    facts
    |> Enum.with_index(1)
    |> Enum.map(fn {fact, idx} ->
      grounded = ground_fn.(fact, utterances) == true

      aliases =
        Map.get(
          groups,
          Map.get(fact, "entity_id"),
          List.wrap(blank_to_nil(fact["character_alias"]))
        )

      attributed = grounded and attr_fn.(fact, utterances, aliases) == true

      Fortschritt.fertig(ctx, "verify", idx)

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
  Per-Fakt-Quell-Grounding: stützt der Quelltext die Aussage?

  Issue #1124: hier stand eine Weiche zwischen NLI-Entailment und LLM-as-Judge
  (`grounding_method`). Sie ist entfallen — seit #677 stand sie ohnehin dauerhaft
  auf dem Judge, weil NLI auf deutschen Real-World-Sessions nahezu nichts als
  geerdet erkannte: abstraktive Fakten („bittet um Hilfe" → „beauftragt Holmes")
  entailen mit ~0.08, während inhaltlich falsche Decoys mit ~0.96 entailen —
  per Schwelle nicht trennbar.
  """
  @spec ground_one(map(), [map()]) :: boolean()
  def ground_one(fact, utterances), do: llm_grounding_one(fact, utterances)

  @doc """
  Per-Fakt-Grounding via LLM-as-Judge (#677): fragt das Stage-Modell, ob der
  QUELLTEXT (auf die `source_refs`-Utterances eingeschränkt) die AUSSAGE stützt.
  JSON `{"grounded": bool}`, `temperature: 0` für reproduzierbare Urteile.

  Defensiv → `false`: keine source_refs (ungeerdet), leerer Claim, LLM-/Parse-
  Fehler — defensiv: Flag-statt-Drop fängt das False-
  Negative im Claims-UI). Injizierbar via `verify_facts/3`-`:ground_fn`; der
  LLM-Call ist die I/O-Grenze.
  """
  @spec llm_grounding_one(map(), [map()]) :: boolean()
  def llm_grounding_one(fact, utterances) do
    refs = Map.get(fact, "source_refs") || []
    claim = String.trim(Map.get(fact, "claim") || "")

    cond do
      refs == [] -> false
      claim == "" -> false
      true -> llm_grounding(claim, restrict_to_refs(utterances, refs))
    end
  end

  @doc """
  #755 Reopen: die LLM-Optionen BEIDER Verify-Judge-Calls (Grounding +
  Attribution) — Stage-3-ctx + Stage-3-Sampling-Settings. Vorher hartcodierten
  beide Callsites `temperature: 0` und die Stage-3-Sampling-UI-Knöpfe waren
  wirkungslos; die Settings-Defaults (0.0/1.0/1.0 = greedy) erhalten das
  deterministische Judge-Verhalten für unkonfigurierte Worker. Public
  (@doc false-Stil wie `Render.render_opts/0`), damit der Reader-Beweis
  („UI-Knopf → wirkt im Call") testbar ist — die LLM-I/O-Grenze in
  llm_grounding/llm_attribution selbst ist es nicht.
  """
  @spec judge_opts(term()) :: keyword()
  def judge_opts(format_schema) do
    [
      format: format_schema,
      num_ctx: Worker.Settings.get(:ctx_stage3, 8192)
    ] ++
      Worker.Recording.Pipeline.Prompts.sampling_opts(3) ++
      Worker.Recording.Pipeline.Prompts.num_predict_opt(3)
  end

  defp llm_grounding(claim, utterances) do
    prompt = grounding_prompt(claim, utterances)
    opts = judge_opts(grounding_json_schema())

    # Issue #1045 (Review-Fund): Fakten aus Riesen-Blöcken gibt es erst, seit
    # der Extraktions-Split sie liefert — deren source_refs zeigen auf die
    # GANZE Block-ID, restrict_to_refs lädt also den vollen Block-Text hierher.
    # Sprengt der ctx_stage3, schneidet Ollama still den Prompt-ANFANG ab →
    # grounded=false → die #1045-Ernte würde downstream lautlos entwertet.
    # Gleicher Warn-Guard wie beim Single-Prompt-Pfad der Extraktion (#417);
    # ein #889-artiger Fail-loud-Umbau (Fehlerklasse statt Warnung, oder
    # gefensterte Grounding-Prompts) ist bewusst Folge-Arbeit — ein Fakt, der
    # hier scheitert, bleibt sichtbar-unverifiziert statt still verloren.
    Worker.Recording.Pipeline.Parsing.guard_prompt_size(
      prompt,
      Keyword.get(opts, :num_ctx),
      "verify_grounding"
    )

    with {:ok, raw} <- LLM.complete(:verify, prompt, opts),
         {:ok, %{"grounded" => grounded}} <- Jason.decode(raw) do
      grounded == true
    else
      _ -> false
    end
  end

  @doc false
  def grounding_prompt(claim, utterances) do
    source = utterances |> Enum.map_join("\n", fn u -> "- " <> utterance_text(u) end)

    """
    Unten steht ein QUELLTEXT (Mitschnitt-Ausschnitt) und eine AUSSAGE, die aus
    dem Quelltext extrahiert wurde. Prüfe, ob der INHALT der Aussage durch den
    Quelltext gestützt wird.

    Die Aussage darf den Quelltext verdichten, paraphrasieren oder
    zusammenfassen — entscheidend ist allein, ob ihr Inhalt aus dem Quelltext
    hervorgeht oder daraus folgt.

    Stützung großzügig auslegen, solange der INHALT übereinstimmt:
    - Perspektive/Pronomen auflösen: spricht der Quelltext eine Person mit
      „du"/„ich"/„er"/„Sie" an und die Aussage benennt sie (z.B. Quelltext „du
      bist verheiratet" → Aussage „Watson ist verheiratet"), zählt das als
      gestützt.
    - Andere Worte, andere Satzform, Zusammenfassung mehrerer Turns: gestützt,
      wenn der Sinn derselbe ist.

    Antworte `{"grounded": true}`, wenn der Quelltext die Aussage inhaltlich
    stützt. Antworte `{"grounded": false}` NUR, wenn die Aussage etwas inhaltlich
    ANDERES behauptet, dem Quelltext WIDERSPRICHT, oder im Quelltext gar nicht
    vorkommt (bloße Wort-Überschneidung ohne inhaltliche Deckung ist NICHT
    gestützt).

    QUELLTEXT:
    #{source}

    AUSSAGE:
    #{claim}
    """
  end

  defp grounding_json_schema do
    %{
      "type" => "object",
      "properties" => %{"grounded" => %{"type" => "boolean"}},
      "required" => ["grounded"]
    }
  end

  @doc """
  Per-Fakt-Attribution: gehört der Claim der RICHTIGEN Figur? Liest die
  `source_refs`-Utterances (auf diese restringiert) und fragt das LLM, ob die im
  Quelltext handelnde/sprechende Figur die zugeordnete ist — `aliases` ist die
  Koreferenz-Gruppe (alle Oberflächenformen derselben kanonischen Entität, via
  `alias_groups/1`), damit „der König" und „Graf von Kramm" als dieselbe Figur
  zählen. `speaker_names` (#762) labelt die Quelltext-Zeilen (`Name: Text`),
  damit auch Sprecher-Attributionen prüfbar sind (die Figur SAGT den Inhalt,
  steht aber nicht im Utterance-Text). JSON `{"match": bool}`.

  **Kein Alias → `true`** (#762): ein Fakt ohne zugeordnete Figur hat keine
  Attribution, die falsch sein könnte — die Achse ist nicht anwendbar, der
  Inhalt ist bereits über das Grounding geprüft. Vorher `false`, was
  figurenlose Welt-Fakten strukturell unverifizierbar machte (11/100 der
  abgelehnten grounded Fakten im Free-Seattle-Referenz-Lauf).

  Defensiv → `false` bleibt für: keine source_refs (ungeerdet — wird wegen
  Short-Circuit ohnehin nicht erreicht), leerer Claim, LLM-/Parse-Fehler.
  Im Zweifel nicht durchwinken
  (Flag-statt-Drop fängt das False-Negative im Claims-UI ab). Injizierbar —
  der LLM-Call ist die I/O-Grenze.
  """
  @spec attribution_verify_one(map(), [map()], [String.t()], map()) :: boolean()
  def attribution_verify_one(fact, utterances, aliases, speaker_names \\ %{}) do
    refs = Map.get(fact, "source_refs") || []
    claim = String.trim(Map.get(fact, "claim") || "")
    figures = Enum.filter(List.wrap(aliases), &(is_binary(&1) and String.trim(&1) != ""))

    cond do
      figures == [] -> true
      refs == [] -> false
      claim == "" -> false
      true -> llm_attribution(claim, restrict_to_refs(utterances, refs), figures, speaker_names)
    end
  end

  # Quelltext auf die source_refs-Utterances einschränken (analog
  # (ehemals Faithfulness.restrict_utterances/2, #1124 entfallen): ist keine
  # ref im Set wiederfindbar (z.B.
  # gelöschte Utterance), fällt es auf die volle Liste zurück — besser ein
  # breiterer Kontext als gar keiner.
  #
  # Issue #815: zusätzlich ±grounding_context_window Nachbar-Turns je Treffer
  # (Index-Nähe in der übergebenen, transkript-geordneten Liste — NICHT die
  # source_refs selbst, nur der Judge-Kontext wird breiter). Der Extraktions-
  # Prompt zitiert bewusst so wenige Refs wie möglich (prompts.ex); ein einzelner
  # knapp daneben liegender Zitat-Turn reichte bisher, um einen wahren Fakt beim
  # Grounding/Attribution abzulehnen, weil der erhellende Nachbar-Turn dem Judge
  # gar nicht vorlag. window=0 → altes Verhalten (exakte Refs, keine Erweiterung).
  # Public weil per Test direkt aufgerufen (Issue #815) — die I/O-Grenze
  # (LLM.complete) macht llm_grounding_one/attribution_verify_one selbst
  # nicht deterministisch unit-testbar, die Kontext-Fenster-Logik hier ist es.
  @doc false
  def restrict_to_refs(utterances, refs) do
    ref_set = MapSet.new(refs)
    window = Worker.Settings.get(:grounding_context_window, 1)

    indexed = Enum.with_index(utterances)

    matched_indices =
      indexed
      |> Enum.filter(fn {u, _idx} ->
        id = Map.get(u, :id) || Map.get(u, "id")
        is_binary(id) and MapSet.member?(ref_set, id)
      end)
      |> Enum.map(fn {_u, idx} -> idx end)

    case matched_indices do
      [] ->
        utterances

      _ ->
        keep =
          matched_indices
          |> Enum.flat_map(&((&1 - window)..(&1 + window)))
          |> MapSet.new()

        indexed
        |> Enum.filter(fn {_u, idx} -> MapSet.member?(keep, idx) end)
        |> Enum.map(fn {u, _idx} -> u end)
    end
  end

  defp llm_attribution(claim, utterances, figures, speaker_names) do
    prompt = attribution_prompt(claim, utterances, figures, speaker_names)

    # #755 Reopen: geteilte Judge-Opts (Stage-3-ctx + -Sampling, s. judge_opts/1).
    opts = judge_opts(attribution_json_schema())

    with {:ok, raw} <- LLM.complete(:verify, prompt, opts),
         {:ok, %{"match" => match}} <- Jason.decode(raw) do
      match == true
    else
      _ -> false
    end
  end

  @doc false
  def attribution_prompt(claim, utterances, figures, speaker_names \\ %{}) do
    source =
      Enum.map_join(utterances, "\n", fn u ->
        "- " <> speaker_label(u, speaker_names) <> utterance_text(u)
      end)

    names = Enum.join(figures, ", ")

    """
    Unten steht ein QUELLTEXT (Mitschnitt-Ausschnitt, Zeilen als `Sprecher: Text`)
    und eine AUSSAGE, die einer bestimmten Figur zugeordnet wurde. Prüfe NUR die
    Attribution: Gehört die Aussage dieser Figur?

    Die Zuordnung ist RICHTIG (`{"match": true}`), wenn EINES gilt:
    - die Figur SPRICHT den Inhalt der Aussage im Quelltext (Sprecher-Label), oder
    - die Figur führt die in der Aussage beschriebene Handlung im Quelltext aus.

    Die Zuordnung ist FALSCH (`{"match": false}`), wenn der Inhalt im Quelltext
    einer ANDEREN Figur gehört (andere Figur spricht/handelt) oder der Quelltext
    die Zuordnung nicht stützt.

    Die zugeordnete Figur kann im Quelltext unter verschiedenen Bezeichnungen
    auftreten (Titel, Eigenname, Verkleidung, Sprecher-Label) — alle gelten als
    DIESELBE Figur: #{names}

    QUELLTEXT:
    #{source}

    AUSSAGE (zugeordnet an: #{names}):
    #{claim}
    """
  end

  # #762: Quelltext-Zeile mit Sprecher-Label prefixen, wenn der Sprecher
  # auflösbar ist — ohne Label sind Sprecher-Attributionen für den Judge
  # strukturell unentscheidbar. Kein Name auflösbar → kein Label (wie vorher).
  defp speaker_label(u, speaker_names) do
    did = Map.get(u, :discord_id) || Map.get(u, "discord_id")

    case Map.get(speaker_names, did) do
      name when is_binary(name) and name != "" -> name <> ": "
      _ -> ""
    end
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
  Semantik überschreibt die Fakt-Row).

  #1133: hier stand eine Vorab-Prüfung auf `faithfulness_sidecar_url`, die mit
  #1124 gegenstandslos wurde — das Setting existiert nicht mehr, `Settings.get/1`
  lieferte also dauerhaft `nil`, und JEDER Verify-Lauf brach mit
  `{:error, :sidecar_offline}` ab (in Prod: eine halbe Stunde Extraktion vor dem
  Nichts). Grounding und Attribution laufen seit #677 über das Stage-3-Modell;
  es gibt keinen Sidecar mehr, dessen Verfügbarkeit vorab zu prüfen wäre. Ein
  LLM-Fehler wird pro Fakt defensiv zu `false` — Flag-statt-Drop fängt ihn im
  Claims-UI.
  """
  @spec verify_session(String.t(), map(), [map()] | nil) ::
          {:ok, [map()]} | {:error, term()}
  def verify_session(session_id, campaign, context \\ nil) do
    case Repo.get_session_facts(session_id) do
      nil ->
        {:error, :no_facts}

      %{facts: facts} = row ->
        # Issue #864 (Epic #861 Slice C): der Grounding-/Attributions-Kontext
        # sind die BLÖCKE des Laufs (source_refs zitieren Block-IDs). Der
        # Pipeline-Lauf reicht seine Kontext-Blöcke durch (Einmal-Resolve,
        # B2 — nie effective_text(now)); Standalone-Aufrufer (Eval, Republish)
        # fallen auf den persistierten Snapshot zurück, davor auf Roh-
        # Utterances (Pre-Block-Bestandssessions).
        utterances =
          context || persisted_block_context(session_id) ||
            Repo.list_utterances(session_id, limit: :all)

        # #762: Sprecher-Labels für den Attributions-Quelltext — dieselbe
        # Auflösung wie im Extraktions-Prompt (character_name > display_name).
        speaker_names = Worker.Recording.Pipeline.Prompts.resolve_speaker_names(campaign.id)

        # #917 (Cut 3): die #865-Gap-Klemme ist ENTFERNT — „vertrauen-aber-
        # markieren" statt klemmen. `verified?` = nur grounded? AND attributed?
        # (das Verify-Gate). Eine uncurierte ASR-Lücke hält keine Fakten mehr
        # zurück; der reader-sichtbare 🕳-Marker (Slice 1) + die #915-⚠-
        # Falsifikation sind die Mitigation (Axiom „null Input ⇒ brauchbar").
        verified =
          verify_facts(facts, utterances,
            speaker_names: speaker_names,
            session_id: session_id
          )

        # #783 Phase 2 (Design E, Provenance-Stempel): backend_stage3 ist
        # jetzt frei drehbar (jederzeit im laufenden Betrieb änderbar) —
        # ohne diesen Stempel wäre ein Verify-Backend-Wechsel zwischen zwei
        # Sessions unsichtbar (Faithfulness-/Verify-Werte über Sessions
        # sind nur vergleichbar, wenn man weiß, mit welchem Judge sie
        # entstanden). KEIN Pin-Mechanismus (macht Drift nur sichtbar,
        # verhindert ihn nicht — der Pin selbst ist Phase 4 der Multi-
        # Worker-Architektur-Arbeit, nicht Teil dieses PRs).
        verify_backend = Worker.Settings.get(:backend_stage3, :local)

        {:ok, _} =
          Intents.publish(%{
            "kind" => Shared.Events.session_facts_extracted(),
            "session_id" => session_id,
            "campaign_id" => campaign.id,
            "facts" => verified,
            "verify_backend" => Atom.to_string(verify_backend),
            "verify_model" => Worker.Settings.model_for(3, verify_backend),
            # #864: Zeit-Adresse FELDKONSERVATIV mitschleppen — der Republish
            # ersetzt die Row (LWW); ohne das verlöre die Dirty-Weiche ihren
            # Vergleichsanker und jede Kuration routete fail-closed auf
            # Re-Extract statt aufs billige Re-Verify.
            "extraction_saw" => Map.get(row, :extraction_saw, %{})
          })

        n_ok = Enum.count(verified, & &1["verified?"])

        Logger.info(
          "verify_session #{session_id}: #{n_ok}/#{length(verified)} Fakten verifiziert"
        )

        {:ok, verified}
    end
  end

  # #864: persistierter Block-Kontext für Standalone-Aufrufer (nil wenn die
  # Session noch nie geglättet wurde — Pre-Block-Bestand).
  defp persisted_block_context(session_id) do
    case Repo.get_smoothed_blocks(session_id) do
      %{blocks: blocks} when blocks != [] ->
        Worker.Recording.Pipeline.Smoothing.to_context(blocks)

      _ ->
        nil
    end
  end
end
