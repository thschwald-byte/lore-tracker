defmodule Worker.Recording.Pipeline.Stages do
  @moduledoc """
  Issue #583 (God-Module-Split aus `Worker.Recording.Pipeline`): die eigentlichen
  Stage-Implementierungen — Stage 2 (Resümee, inkl. Map-Reduce), Stage 3 (Epos),
  Stage 4 (Chronik) + Faithfulness + Stage-4-Publish. Aufgerufen aus dem
  Orchestrator (`run_stages` der Façade) im selben GenServer-Prozess. Nutzt die
  Façade (Status/Publish/Error-Helfer) + `Prompts` (Prompt-Bau) + `Parsing`
  (Output-Dekodierung) via import.
  """
  require Logger

  alias Worker.{Intents, LLM, Repo}

  # Issue #583: die Façade re-exportiert via defdelegate genau die Funktionen, die
  # hier direkt aus Prompts/Parsing/Stages importiert werden → diese aus dem
  # Façade-Import ausnehmen, sonst Import-Ambiguität.
  import Worker.Recording.Pipeline,
    except: [
      parse_chronik_json: 1,
      parse_summary_json: 2,
      parse_epos_json: 2,
      filter_fabricated_chronik: 1,
      strip_and_note: 1,
      preview_prompt: 2,
      effective_flavor: 2,
      default_flavor: 1,
      heading_directive: 2,
      stage_heading: 2,
      epos_structure_block: 1,
      build_epos_prompt: 3,
      build_epos_prompt: 4,
      build_epos_prompt: 5,
      build_epos_prompt: 6,
      stage2_chunking_needed?: 3,
      group_for_reduce: 2,
      chunk_utterances: 3,
      stage4_source_text: 2
    ]

  import Worker.Recording.Pipeline.Prompts
  import Worker.Recording.Pipeline.Parsing

  def stage2(utterances, session_id, campaign) do
    speaker_names = resolve_speaker_names(campaign.id)
    num_ctx = Worker.Settings.get(:ctx_stage2, 8192)
    chunk_budget = Worker.Settings.get(:stage2_chunk_tokens, 6000)
    flavors = campaign[:flavors] || %{}
    heading = heading_directive(stage_heading(campaign, "summary"), "summary")

    # Issue #114: JSON-Mode für strukturierten Output (content_md + source_refs).
    # Pattern analog Stage 4 (parse_chronik_json). Bei Parse-Fehler fällt der
    # Helper auf {trim(raw), []} zurück — Pipeline läuft weiter, Audit-Refs
    # nur fehlend statt Crash.
    # Issue #289 Phase 1: JSON-Schema statt nur "json" — Ollamas GBNF-
    # Grammatik macht invalides JSON token-seitig unmöglich + eliminiert
    # `<think>`-Block-Vorräute strukturell.
    opts = [format: stage2_json_schema(), num_ctx: num_ctx] ++ sampling_opts(2)

    # Issue #289 Phase 2: Bei Parse-Fallback (LLM hat keinen
    # `{"content_md": ...}`-JSON-Output geliefert) ein Retry mit
    # Korrektur-Prompt triggern. Anzahl konfigurierbar via Settings.
    max_retries = Worker.Settings.get(:pipeline_max_format_retries, 1)

    # Issue #417: Dispatch. Passt das gerenderte Transkript ins Chunk-Budget,
    # bleibt der bestehende Single-Prompt-Pfad (keine Verhaltens-/Output-
    # Änderung für normale Sessions). Sonst Map-Reduce (Chunk → Teil-Resümee →
    # reduzieren), damit auch 4-h-Sessions ein vollständiges Resümee bekommen
    # statt von Ollama still trunkiert zu werden.
    generated =
      if stage2_chunking_needed?(utterances, speaker_names, chunk_budget) do
        stage2_map_reduce(
          utterances,
          speaker_names,
          flavors,
          heading,
          opts,
          max_retries,
          chunk_budget
        )
      else
        prompt = build_summary_prompt(utterances, speaker_names, flavors, heading)
        guard_prompt_size(prompt, num_ctx, "stage2")
        stage2_llm_with_retry(prompt, opts, utterances, max_retries)
      end

    case generated do
      {:ok, summary_md, source_refs} ->
        # Issue #430: publish_event gibt immer :ok (Intents.publish failt nie).
        publish_event(%{
          "kind" => Shared.Events.session_summary_generated(),
          "session_id" => session_id,
          "campaign_id" => campaign.id,
          "content_md" => summary_md,
          "source" => "llm",
          "source_refs" => source_refs
        })

        {:ok, %{content_md: summary_md, source_refs: source_refs}}

      {:error, reason} ->
        {:error, {:stage2, reason}}
    end
  end

  # Issue #289 Phase 2: LLM-Call mit Korrektur-Retry. Geht max_retries-mal
  # erneut ans Modell wenn der Parser auf den raw-Fallback fällt (kein
  # `{"content_md": ...}`-JSON geliefert). Returnt im Erfolgsfall die
  # geparste Variante, sonst die Fallback-Variante (raw als content_md,
  # keine refs) — die Pipeline läuft in beiden Fällen weiter, der
  # Unterschied ist nur die Audit-Qualität der source_refs.
  defp stage2_llm_with_retry(prompt, opts, utterances, max_retries) do
    stage2_llm_attempt(prompt, opts, utterances, max_retries, :first_try)
  end

  defp stage2_llm_attempt(prompt, opts, utterances, retries_left, attempt) do
    case LLM.complete(:summary, prompt, opts) do
      {:ok, raw} ->
        case parse_summary_json_with_status(raw, utterances) do
          {:parsed, md, refs, notes} ->
            if attempt != :first_try do
              Logger.info("stage2: format_retry retry_ok (attempt=#{inspect(attempt)})")
            end

            put_format_notes(notes)
            {:ok, md, refs}

          {:fallback, _fallback_md, _notes} when retries_left > 0 ->
            Logger.info(
              "stage2: format-fallback erkannt — Retry mit Korrektur-Prompt " <>
                "(retries_left=#{retries_left})"
            )

            retry_prompt = build_summary_retry_prompt(prompt, raw)
            stage2_llm_attempt(retry_prompt, opts, utterances, retries_left - 1, :retry)

          {:fallback, fallback_md, notes} ->
            if attempt != :first_try do
              Logger.warning(
                "stage2: format_retry retry_failed — Fallback nach #{inspect(attempt)}"
              )
            end

            # Pipeline läuft mit raw-Fallback weiter (heutiges Verhalten ohne #289).
            put_format_notes(notes)
            {:ok, fallback_md, []}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Issue #289 Phase 2: Korrektur-Prompt für Stage 2 nach Format-Fallback.
  # Format genau wie im Issue spezifiziert.

  # ─── Issue #417: Stage-2 Map-Reduce für lange Sessions ──────────────
  #
  # Map: Utterances in token-budget-begrenzte Chunks (an Turn-Grenzen) splitten,
  # pro Chunk ein Teil-Resümee. Reduce: Teil-Resümees → ein Gesamt-Resümee
  # (rekursiv, falls sie selbst das Budget sprengen). source_refs = Union aller
  # erfolgreichen Chunk-Refs (schon echte UUIDs, weil Builder + Parser pro Chunk
  # dieselbe Chunk-Liste sehen — siehe render_transcript-Kommentar).

  # Overlap zwischen Chunks (letzte N Utterances mitnehmen) für narrative
  # Kontinuität. Refs sind UUID-dedupe'd → Overlap doppelt nichts.
  @stage2_chunk_overlap 2
  # Sicherheits-Netz gegen pathologische Reduce-Rekursion (sehr viele/lange
  # Teil-Resümees). Greift praktisch nie — Reduce schrumpft die Menge je Runde.
  @stage2_reduce_max_depth 4

  # Issue #417: Dispatch-Prädikat — sprengt das gerenderte Transkript das
  # Chunk-Budget, schaltet Stage 2 auf Map-Reduce. Public (@doc false) für den
  # Unit-Test der Schwelle ohne LLM-Call.
  @doc false
  def stage2_chunking_needed?(utterances, speaker_names, budget) do
    estimate_tokens(render_transcript(utterances, speaker_names)) > budget
  end

  defp stage2_map_reduce(utterances, speaker_names, flavors, heading, opts, max_retries, budget) do
    chunks = chunk_utterances(utterances, budget, speaker_names)
    n = length(chunks)

    Logger.info(
      "stage2: Map-Reduce — #{length(utterances)} utts → #{n} chunks (budget=#{budget} tok)"
    )

    results =
      chunks
      |> Enum.with_index(1)
      |> Enum.map(fn {chunk, i} ->
        Logger.info("stage2: Map-Chunk #{i}/#{n} (#{length(chunk)} utts)")
        stage2_map_chunk(chunk, speaker_names, flavors, heading, opts, max_retries, i, n)
      end)
      |> Enum.reject(&is_nil/1)

    case results do
      [] ->
        {:error, :all_chunks_failed}

      _ ->
        partials = Enum.map(results, fn {md, _refs} -> md end)
        union_refs = results |> Enum.flat_map(fn {_md, refs} -> refs end) |> Enum.uniq()
        Logger.info("stage2: Reduce über #{length(partials)} Teil-Resümees")
        reduce_summaries(partials, union_refs, flavors, heading, opts, max_retries, budget, 0)
    end
  end

  # Ein Map-Chunk: Teil-Resümee generieren. Gescheiterter LLM-Call (Transport)
  # loggt + gibt nil → Stage läuft mit den übrigen Chunks weiter (Pattern wie
  # CampaignReplay). Format-Fallback ist KEIN Fehler (liefert raw als md).
  defp stage2_map_chunk(chunk, speaker_names, flavors, heading, opts, max_retries, i, n) do
    prompt = build_partial_summary_prompt(chunk, speaker_names, flavors, heading)

    case stage2_llm_with_retry(prompt, opts, chunk, max_retries) do
      {:ok, md, refs} ->
        {md, refs}

      {:error, reason} ->
        Logger.warning(
          "stage2: Map-Chunk #{i}/#{n} fehlgeschlagen (#{inspect(reason)}) — übersprungen"
        )

        nil
    end
  end

  # Reduce: Teil-Resümees zu einem Gesamt-Resümee. Sprengen die Teil-Resümees
  # selbst das Budget, erst gruppenweise zwischen-reduzieren (rekursiv).
  defp reduce_summaries(partials, union_refs, flavors, heading, opts, max_retries, budget, depth) do
    partials = Enum.reject(partials, &blank?/1)

    cond do
      partials == [] ->
        {:error, :all_chunks_failed}

      length(partials) == 1 ->
        # Nur ein (Teil-)Resümee übrig — direkt als Ergebnis, kein Reduce-Call.
        {:ok, hd(partials), union_refs}

      depth >= @stage2_reduce_max_depth ->
        finalize_reduce(partials, union_refs, flavors, heading, opts, max_retries)

      estimate_tokens(Enum.join(partials, "\n\n")) > budget ->
        partials
        |> group_for_reduce(budget)
        |> Enum.map(&reduce_group_or_join(&1, flavors, heading, opts, max_retries))
        |> reduce_summaries(union_refs, flavors, heading, opts, max_retries, budget, depth + 1)

      true ->
        finalize_reduce(partials, union_refs, flavors, heading, opts, max_retries)
    end
  end

  defp finalize_reduce(partials, union_refs, flavors, heading, opts, max_retries) do
    case reduce_once(partials, flavors, heading, opts, max_retries) do
      {:ok, md} -> {:ok, md, union_refs}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reduce_group_or_join(group, flavors, heading, opts, max_retries) do
    case reduce_once(group, flavors, heading, opts, max_retries) do
      {:ok, md} -> md
      # Zwischen-Reduce gescheitert → Gruppe roh zusammenhängen, nächste Runde
      # versucht es erneut (oder das Sicherheits-Netz greift).
      {:error, _} -> Enum.join(group, "\n\n")
    end
  end

  # Ein Reduce-LLM-Call. Parsing gegen leere Utterance-Liste — die Reduce-Phase
  # kennt keine `[uN]`-Marker, die source_refs kommen aus dem Map-Union.
  defp reduce_once(partials, flavors, heading, opts, max_retries) do
    prompt = build_reduce_prompt(partials, flavors, heading)

    case stage2_llm_with_retry(prompt, opts, [], max_retries) do
      {:ok, md, _refs} -> {:ok, md}
      {:error, reason} -> {:error, reason}
    end
  end

  # Teil-Resümees greedy in Gruppen splitten, deren zusammengehängte Schätzung
  # je ≤ budget bleibt. Einzel-Teil > budget bekommt seine eigene Gruppe.
  # Public (@doc false) für Unit-Test.
  @doc false
  def group_for_reduce(partials, budget) do
    do_group(partials, budget, [], 0, [])
  end

  defp do_group([], _budget, [], _tok, acc), do: Enum.reverse(acc)
  defp do_group([], _budget, cur, _tok, acc), do: Enum.reverse([Enum.reverse(cur) | acc])

  defp do_group([md | rest], budget, cur, tok, acc) do
    md_tok = estimate_tokens(md)

    cond do
      cur == [] -> do_group(rest, budget, [md], md_tok, acc)
      tok + md_tok <= budget -> do_group(rest, budget, [md | cur], tok + md_tok, acc)
      true -> do_group(rest, budget, [md], md_tok, [Enum.reverse(cur) | acc])
    end
  end

  # Issue #417: Utterances greedy in Chunks splitten, deren gerenderter
  # Transkript-Anteil je ~budget Token bleibt. Schnitt nur an Utterance-Grenzen
  # (Turns bleiben ganz). Overlap: die letzten @stage2_chunk_overlap Utterances
  # eines Chunks starten den nächsten mit. Eine Einzel-Utterance > Budget
  # bekommt ihren eigenen Chunk (nie mitten im Turn schneiden).
  @doc false
  def chunk_utterances(utterances, budget, speaker_names)
      when is_list(utterances) and is_integer(budget) and budget > 0 do
    utterances
    |> Enum.map(fn u -> {u, estimate_tokens(transcript_line(u, speaker_names))} end)
    |> build_chunks(budget, [], 0, [])
    |> Enum.map(fn chunk -> Enum.map(chunk, fn {u, _tok} -> u end) end)
  end

  defp build_chunks([], _budget, [], _cur_tok, acc), do: Enum.reverse(acc)
  defp build_chunks([], _budget, cur, _cur_tok, acc), do: Enum.reverse([Enum.reverse(cur) | acc])

  defp build_chunks([{_u, tok} = head | rest], budget, cur, cur_tok, acc) do
    cond do
      cur == [] ->
        build_chunks(rest, budget, [head], tok, acc)

      cur_tok + tok <= budget ->
        build_chunks(rest, budget, [head | cur], cur_tok + tok, acc)

      true ->
        finished = Enum.reverse(cur)
        overlap = Enum.take(finished, -@stage2_chunk_overlap)
        overlap_tok = Enum.reduce(overlap, 0, fn {_u, t}, s -> s + t end)
        new_cur = [head | Enum.reverse(overlap)]
        build_chunks(rest, budget, new_cur, overlap_tok + tok, [finished | acc])
    end
  end

  # Map-Prompt: Teil-Resümee EINES Abschnitts. Gleicher JSON-Contract wie der
  # Single-Prompt (content_md + source_refs über die `[uN]`-Marker), damit
  # parse_summary_json_with_status/2 die Refs auf echte UUIDs auflöst.

  # Reduce-Prompt: mehrere Teil-Resümees → ein kohärentes Gesamt-Resümee.

  # Issue #11 Phase 2: Faithfulness-Score gegen Quell-Transkript.
  # Sidecar-Aufruf ist optional — bei Fehler/Offline läuft die Pipeline
  # ohne Score weiter (Status-Notifikation als "ended" mit warning).
  def stage_faithfulness(summary, utterances, session_id, campaign_id) do
    notify_status(campaign_id, "faithfulness", "started", nil)

    %{content_md: summary_md, source_refs: source_refs} = summary

    case Worker.LLM.Faithfulness.score(summary_md, utterances, source_refs) do
      {:ok, %{score: score, claims: claims}} ->
        # Faithfulness ist optional — Publish-Failure soll die Pipeline nicht
        # blocken, nur als warning loggen.
        _ =
          publish_event(%{
            "kind" => Shared.Events.session_faithfulness_scored(),
            "session_id" => session_id,
            "campaign_id" => campaign_id,
            "score" => score,
            "claims" => Enum.map(claims, &Map.new(&1, fn {k, v} -> {to_string(k), v} end)),
            "scored_at" => DateTime.utc_now() |> DateTime.to_iso8601()
          })

        notify_status(campaign_id, "faithfulness", "ended", nil)
        :ok

      {:error, :sidecar_offline} ->
        Logger.info("Pipeline: faithfulness sidecar offline — skipping for session=#{session_id}")
        notify_status(campaign_id, "faithfulness", "ended", "sidecar offline")
        :ok

      {:error, reason} ->
        Logger.warning(
          "Pipeline: faithfulness scoring failed for session=#{session_id}: #{inspect(reason)}"
        )

        notify_status(campaign_id, "faithfulness", "ended", "scoring failed")
        :ok
    end
  end

  def stage3(_summary_md, campaign, opts) do
    force? = Keyword.get(opts, :force?, false)

    # Issue #277: Bei force=true (manueller „🔄 neu generieren") wird der
    # bestehende Epos NICHT mehr als Referenz mitgegeben. User-Intent ist
    # Reset, nicht Kontinuität — wenn der existing_md vergiftet ist (z.B.
    # Wortsalat aus einem Modellwechsel), würde der Re-Run das Pattern
    # sonst als Stil-Vorlage übernehmen und reproduzieren.
    existing_md =
      if force? do
        ""
      else
        existing = Repo.get_epos_entry(campaign.id)
        (existing && existing.content_md) || ""
      end

    # Use all summaries of the campaign, not just the just-generated one —
    # so the Epos has the full chronological context.
    all_summaries =
      Repo.list_session_summaries(campaign.id)
      |> Enum.sort_by(& &1.generated_at, {:asc, DateTime})

    # Issue #313: Darstellungsform (Fließtext|Stichpunkte) aus der Campaign-
    # Vorgabe für die epos-Stage; default Fließtext.
    darstellungsform =
      case campaign[:vorgaben] do
        %{"epos" => %{darstellungsform: f}} when is_binary(f) and f != "" -> f
        _ -> "fliesstext"
      end

    prompt =
      build_epos_prompt(
        existing_md,
        all_summaries,
        campaign[:flavors] || %{},
        force?,
        darstellungsform,
        heading_directive(stage_heading(campaign, "epos"), "epos")
      )

    # Issue #226: Diagnostik IMMER aktiv (auch ohne force?). Macht künftig
    # diagnostizierbar ob "same prompt → same output" (LLM-Determinismus bei
    # niedrig-temp) oder "different prompt → same output" (echtes Caching
    # irgendwo, was wir heute nicht haben aber sicherheitshalber checken).
    Logger.info(
      "Pipeline: Stage 3 prompt sha=#{short_sha(prompt)} #{byte_size(prompt)} bytes #{length(all_summaries)} summaries force=#{force?}"
    )

    # Issue #114: JSON-Mode für strukturierten Output (content_md + source_refs).
    # Issue #373: strict JSON-Schema (GBNF-Constraint) statt loser format: "json" —
    # eliminiert <think>-Block-Lecks, Markdown-Code-Fence-Wrapping und Vorrede-Output.
    # Double-Wrap-Vermeidung passiert zusätzlich im Prompt (build_epos_prompt).
    num_ctx = Worker.Settings.get(:ctx_stage3, 16384)
    guard_prompt_size(prompt, num_ctx, "stage3")
    base_llm_opts = [format: stage3_json_schema(), num_ctx: num_ctx] ++ sampling_opts(3)

    # Issue #226: bei manuellem Re-Run temperature hochsetzen — sonst
    # bleibt das LLM bei temp=0.2 + nahezu identischem Prompt deterministisch
    # auf dem bisherigen Output kleben.
    llm_opts =
      if force?, do: Keyword.put(base_llm_opts, :temperature, 0.5), else: base_llm_opts

    # Issue #114: Fallback-Source-Refs sind die Union aller einfließenden
    # Summary-Refs (deduped). Falls Stage-3-LLM den JSON-Output nicht sauber
    # liefert, behält der Epos wenigstens die Audit-Spur seiner Quell-Resümees.
    fallback_refs =
      all_summaries
      |> Enum.flat_map(fn s -> Map.get(s, :source_refs, []) end)
      |> Enum.uniq()

    case LLM.complete(:epos, prompt, llm_opts) do
      {:ok, raw} ->
        {new_md, source_refs, notes} = parse_epos_json_with_notes(raw, fallback_refs)
        put_format_notes(notes)

        Logger.info(
          "Pipeline: Stage 3 output sha=#{short_sha(new_md)} #{byte_size(new_md)} bytes refs=#{length(source_refs)}"
        )

        # Issue #430: publish_event gibt immer :ok (Intents.publish failt nie).
        publish_event(%{
          "kind" => Shared.Events.epos_entry_edited(),
          "entry_id" => campaign.id,
          "campaign_id" => campaign.id,
          "new_md" => new_md,
          "edited_by" => "llm",
          "source" => "llm",
          "source_refs" => source_refs
        })

        {:ok, new_md}

      {:error, reason} ->
        {:error, {:stage3, reason}}
    end
  end

  defp short_sha(text) do
    :crypto.hash(:sha256, text)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 12)
  end

  def stage4(epos_md, session_id, campaign) do
    # Issue #289 Phase 1: JSON-Schema-Mode (statt nur "json"), siehe stage2/3.
    opts =
      [format: stage4_json_schema(), num_ctx: Worker.Settings.get(:ctx_stage4, 8192)] ++
        sampling_opts(4)

    flavors = campaign[:flavors] || %{}
    heading = heading_directive(stage_heading(campaign, "chronik"), "chronik")

    # Issue #114/#436: source_refs sollen auf utterance_ids DIESER Session
    # zeigen. Wir geben dem LLM die Utterance-IDs der triggernden Session als
    # Whitelist + Hint, welche Refs in welche Chronik-Einträge gehören. Der
    # Materializer filtert eh nochmal über normalize_entry_refs (kein
    # junk-passthrough). (Der Extraktions-Text ist seit #436 session-scoped,
    # siehe stage4_source_text/2 unten — vorher der campaign-weite Epos.)
    session_utterances = Repo.list_utterances(session_id)

    # Issue #436: Extraktions-Quelle ist das SESSION-EIGENE Resümee, NICHT der
    # campaign-weite Epos. Der Epos aggregiert alle Sessions (stage3 by design,
    # „full chronological context") — Stage 4 zog daraus sonst Plot-Beats
    # späterer Sessions in die Chronik dieser einen Session (Future-Plot-Leak,
    # #436 Musketiere-Befund). Das Session-Resümee ist session-scoped → der Leak
    # verschwindet strukturell statt nur per Prompt-Instruktion. Fallback auf
    # den Epos nur, wenn (noch) kein Session-Resümee existiert (besser als leer).
    source_md = stage4_source_text(session_id, epos_md)

    # Issue #307: Index-Map deckungsgleich mit der Whitelist im Prompt
    # (Enum.take(60) + 1-basierter Index). valid_ids über alle Utterances für
    # den UUID-Passthrough (Robustheit).
    index_map = utterance_index_map(Enum.take(session_utterances, 60))
    valid_ids = MapSet.new(session_utterances, & &1.id)

    with {:ok, entries} <-
           stage4_extract(source_md, opts, :first_try, flavors, session_utterances, heading),
         {:ok, entries} <-
           maybe_retry_stage4(entries, source_md, opts, flavors, session_utterances, heading) do
      entries
      |> resolve_entry_refs(index_map, valid_ids)
      |> stage4_publish(session_id, campaign)
    else
      {:error, reason} -> {:error, {:stage4, reason}}
    end
  end

  # Issue #436: session-scoped Extraktions-Text für Stage 4. Das Session-eigene
  # Resümee (Stage-2-Output) ist auf genau diese Sitzung begrenzt; der
  # campaign-weite Epos ist es nicht. Fallback auf den Epos, wenn (noch) kein
  # Resümee da ist (z.B. Stage 2 übersprungen/fehlgeschlagen) — ein voller Epos
  # ist immer noch besser als gar kein Material.
  @doc false
  def stage4_source_text(session_id, epos_md) do
    case Repo.get_session_summary(session_id) do
      %{content_md: md} when is_binary(md) and md != "" -> md
      _ -> epos_md
    end
  end

  # Issue #307: pro Chronik-Eintrag die Kurz-ID-source_refs auf echte UUIDs
  # auflösen + gegen die Whitelist filtern. Ersetzt den ungeprüften
  # normalize_entry_refs-Passthrough, durch den der Prompt-Platzhalter
  # `<utterance-id-3>` (#114) in eine prod-Chronik durchgeleakt ist.
  defp resolve_entry_refs(entries, index_map, valid_ids) do
    Enum.map(entries, fn
      %{} = entry ->
        resolved = resolve_source_refs(Map.get(entry, "source_refs"), index_map, valid_ids)
        Map.put(entry, "source_refs", resolved)

      other ->
        other
    end)
  end

  defp stage4_extract(epos_md, opts, attempt, flavors, session_utterances, heading) do
    prompt = build_chronik_prompt(epos_md, attempt, flavors, session_utterances, heading)
    guard_prompt_size(prompt, Keyword.get(opts, :num_ctx, 8192), "stage4")

    case LLM.complete(:chronik, prompt, opts) do
      {:ok, json_str} ->
        {raw_entries, notes} = parse_chronik_json_with_notes(json_str)
        put_format_notes(notes)
        entries = filter_fabricated_chronik(raw_entries)

        if entries == [] do
          Logger.warning(
            "Stage 4 (#{attempt}): LLM returned 0 entries (after fabrication-filter). " <>
              "Raw output (truncated): " <> String.slice(json_str || "", 0, 400)
          )
        end

        {:ok, entries}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ─── Issue #289 Phase 1: JSON-Schema-Maps für Ollama-Strict-Mode ────
  #
  # Ollama akzeptiert für `format` entweder den String `"json"` (loser
  # JSON-Mode) oder eine JSON-Schema-Map (GBNF-Grammatik-Enforcement —
  # invalides JSON ist token-seitig unmöglich, Think-Blocks werden als
  # Nebeneffekt eliminiert). Die Schemata decken genau das ab, was
  # `parse_summary_json/2` und `parse_chronik_json/1` als kanonische Form
  # erwarten. Die defensiven Parser-Fallbacks (think-strip, code-fence-
  # strip, JSON-extract, Alt-Wrapper wie "chronik"/"timeline") bleiben für
  # Cloud-Backends (Anthropic/OpenAI) und ältere Modelle, die ohne
  # Schema-Mode laufen.
  defp stage2_json_schema do
    %{
      "type" => "object",
      "properties" => %{
        "content_md" => %{"type" => "string"},
        "source_refs" => %{"type" => "array", "items" => %{"type" => "string"}}
      },
      "required" => ["content_md"]
    }
  end

  # Issue #373: Identisch zu stage2_json_schema/0 — Stage 2 und Stage 3
  # haben denselben Output-Shape (content_md + optional source_refs). Vorher
  # nur loser format: "json", was zu double-wrapped Outputs führte (siehe
  # Folger-Replay 2026-05-30).
  defp stage3_json_schema do
    %{
      "type" => "object",
      "properties" => %{
        "content_md" => %{"type" => "string"},
        "source_refs" => %{"type" => "array", "items" => %{"type" => "string"}}
      },
      "required" => ["content_md"]
    }
  end

  defp stage4_json_schema do
    %{
      "type" => "object",
      "properties" => %{
        "entries" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "in_game_date" => %{"type" => "string"},
              "label" => %{"type" => "string"},
              "summary" => %{"type" => "string"},
              "source_refs" => %{"type" => "array", "items" => %{"type" => "string"}}
            },
            "required" => ["in_game_date", "label", "summary"]
          }
        }
      },
      "required" => ["entries"]
    }
  end

  # Retry once with a sharper prompt if the first pass yielded no entries —
  # qwen2.5 sometimes returns {} on its first JSON-mode answer and resolves
  # with one nudge.
  defp maybe_retry_stage4([] = _empty, epos_md, opts, flavors, session_utterances, heading) do
    case stage4_extract(epos_md, opts, :retry, flavors, session_utterances, heading) do
      {:ok, entries} -> {:ok, entries}
      err -> err
    end
  end

  defp maybe_retry_stage4(entries, _epos_md, _opts, _flavors, _session_utterances, _heading),
    do: {:ok, entries}

  # Tries hard to extract a JSON array of chronik entries from arbitrary LLM
  # output. Issue #75: qwen3 (Thinking-Mode) prefixes every answer with a
  # `<think>...</think>` block, which busts Ollama's strict `format: "json"`
  # mode AND defeats `Jason.decode/1` if the model falls back to free-form
  # text. We strip the thinking-block, peel off Markdown code-fences, and
  # finally regex out the first JSON object/array if it's still embedded in
  # prose. Empty input or undecodable output return [], which the caller
  # treats as a stage failure (`stage4_publish/2`).
  @doc false

  # pipeline still reports `ended` — masking real model-incompatibility.
  defp stage4_publish([], _session_id, _campaign) do
    Logger.warning("Stage 4: LLM returned no usable chronik entries even after retry")
    {:error, :empty_chronik}
  end

  # Issue #227: Re-Run-Cleanup. Vor neuen ChronikEntryChanged-Events räumen
  # wir die bestehenden Chronik-Rows derselben session_id aus — sonst
  # akkumulieren Halluzinationen über jeden Re-Run hinweg, weil die
  # SHA-abgeleiteten IDs auf (date, label) sich ändern und alte Rows nie
  # überschrieben werden.
  defp stage4_publish(entries, session_id, campaign) do
    # Issue #430: Intents.publish/1 gibt immer {:ok, …} (kein toter {:error}-Branch).
    {:ok, _} =
      Intents.publish(%{
        "kind" => Shared.Events.chronik_cleared_for_session(),
        "campaign_id" => campaign.id,
        "session_id" => session_id,
        "cleared_by" => "llm"
      })

    results =
      Enum.map(entries, fn entry ->
        Intents.publish(%{
          "kind" => Shared.Events.chronik_entry_changed(),
          "id" => derive_chronik_id(entry),
          "campaign_id" => campaign.id,
          "in_game_date" => Map.get(entry, "in_game_date") || Map.get(entry, "date"),
          "label" => Map.get(entry, "label") || Map.get(entry, "title") || "",
          "summary" => Map.get(entry, "summary") || Map.get(entry, "description"),
          "session_id" => session_id,
          # Issue #114: source_refs pro Eintrag aus dem Stage-4-JSON.
          # Bei alten Modellen die kein refs-Feld liefern: leer (Audit-Spur
          # fehlt, Pipeline läuft normal weiter).
          "source_refs" => normalize_entry_refs(Map.get(entry, "source_refs"))
        })
      end)

    failures = Enum.reject(results, &match?({:ok, _}, &1))

    if failures == [] do
      Logger.info("Stage 4: wrote #{length(entries)} chronik entries (session=#{session_id})")
      :ok
    else
      Logger.warning(
        "Stage 4: #{length(failures)} of #{length(entries)} chronik publishes failed: " <>
          inspect(List.first(failures))
      )

      {:error, {:stage4_publish, List.first(failures)}}
    end
  end

  # Hard-Match auf `{:ok, _seq}` wird vermieden: bei Hub-Outage liefert
  # `Intents.publish` `{:error, :not_connected}` (oder Timeout), was ohne diesen
  # Wrapper einen MatchError in der Stage werfen würde. Stattdessen wird der
  # Fehler geloggt und an den Caller propagiert, der entscheidet ob die Stage
  # damit als fehlgeschlagen gilt (z.B. Stage 2/3) oder ob die Pipeline trotzdem
  # weiterläuft (z.B. Faithfulness, weil optional).
  # Issue #430: Intents.publish/1 gibt immer {:ok, …} → publish_event gibt immer
  # :ok. Die {:publish_failed, …}-Sub-Branches der Stages (stage2/stage3) sind
  # damit tot und entfernt; echte Stage-Fehler (LLM/Parse) propagieren weiterhin
  # über die übrigen {:error, {:stageN, reason}}-Pfade.
  defp publish_event(payload) do
    {:ok, _seq} = Intents.publish(payload)
    :ok
  end

  defp derive_chronik_id(entry) do
    seed =
      [
        Map.get(entry, "in_game_date") || Map.get(entry, "date") || "",
        Map.get(entry, "label") || Map.get(entry, "title") || ""
      ]
      |> Enum.join("|")

    "chronik-" <>
      (:crypto.hash(:sha, seed) |> Base.encode16(case: :lower) |> binary_part(0, 12))
  end

  # ─── Prompt builders ─────────────────────────────────────────────

  # Issue #307: Kurz-IDs `[u1]…[uN]` statt voller UUID. Eine UUID tokenisiert
  # zu ~30 Token, ein `[uN]`-Marker zu ~3 — gemessen ~60% Prompt-Ersparnis,
  # was das Context-Ceiling von ~1600 auf ~4000 Utterances schiebt (siehe
  # docs/Performance.md). Der Parser (parse_summary_json/2) mappt die Kurz-IDs
  # über dieselbe `Enum.with_index/2`-Reihenfolge zurück auf echte UUIDs —
  # daher MUSS dieselbe Utterance-Liste in Builder UND Parser gehen (Issue #417
  # Chunking: pro Chunk dieselbe Chunk-Liste → source_refs als globale UUIDs).
end
