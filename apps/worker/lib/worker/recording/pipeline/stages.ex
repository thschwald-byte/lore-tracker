defmodule Worker.Recording.Pipeline.Stages do
  @moduledoc """
  Issue #583 (God-Module-Split aus `Worker.Recording.Pipeline`): die
  Extraktions-Implementierung des Wahrheitsbild-Pfads — `extract_facts/3`
  inkl. Map-Reduce für lange Sessions (#683) + Halbierungs-Retry (#763).
  Aufgerufen aus dem Orchestrator (`run_wahrheitsbild` der Façade) im selben
  GenServer-Prozess. Nutzt die Façade + `Prompts` (Prompt-Bau) + `Parsing`
  (Output-Dekodierung) via import. Die Chain-Stages (2/3/4) sind seit #786
  entfernt.
  """
  require Logger

  alias Worker.{Intents, LLM}
  alias Worker.Recording.Pipeline.Ooc

  # Issue #583: die Façade-Helfer (with_status/notify_status) werden hier seit
  # #786 nicht mehr gebraucht — die Extraktion meldet Status über den
  # Orchestrator (`run_wahrheitsbild`), daher kein Façade-Import mehr.
  import Worker.Recording.Pipeline.Prompts
  import Worker.Recording.Pipeline.Parsing

  # Issue #651 (Wahrheitsbild, Phase A): der Extraktions-Step — Original-
  # Utterances → strukturierte Fakten, publisht als SessionFactsExtracted.
  # Der EINE gegatete Generativschritt; Resümee/Epos/Timeline rendern als
  # Geschwister daraus (seit #786 der einzige Pipeline-Pfad).
  # Issue #683: lange Sessions laufen über Map-Reduce (Chunk → Fakten pro Chunk →
  # mergen, analog #417 für Stage 2), damit ein starker Extraktor sie ohne
  # Timeout verarbeitet; kurze Sessions bleiben Single-Prompt.
  def extract_facts(utterances, session_id, campaign) do
    case extract_facts_raw(utterances, session_id, campaign) do
      {:ok, facts, extraction_saw} ->
        publish_event(%{
          "kind" => Shared.Events.session_facts_extracted(),
          "session_id" => session_id,
          "campaign_id" => campaign.id,
          "facts" => facts,
          "extraction_saw" => extraction_saw
        })

        {:ok, facts}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Issue #866 (Slice F): die reine Extraktion OHNE Publish — der Carry-over-
  Re-Extract mischt das LLM-Ergebnis erst mit dem Bestand (verbatim-Übernahme
  unveränderter Blöcke) und publisht selbst. Returns `{:ok, facts,
  extraction_saw}` (Zeit-Adresse des Laufs) oder `{:error, reason}`.
  """
  def extract_facts_raw(utterances, session_id, campaign) do
    # Issue #680: klare OOC-/Würfel-Turns VOR der Extraktion rauswerfen, damit der
    # Extraktor sie nicht als source_refs zitieren kann. Gefilterte Liste für
    # Prompt UND Parsing nutzen, damit die [uN]-Indizes übereinstimmen.
    all_count = length(utterances)
    utterances = Ooc.filter(utterances)

    if length(utterances) < all_count,
      do:
        Logger.debug(
          "extract_facts: #{all_count - length(utterances)} OOC-Turns gefiltert (#{session_id})"
        )

    speaker_names = resolve_speaker_names(campaign.id)
    num_ctx = Worker.Settings.get(:ctx_stage2, 8192)
    # num_predict: NICHT das Stage-2-Cap (400, für 3-6-Satz-Resümees — würde den
    # langen Fakt-JSON abschneiden, #683), aber seit #763 auch nicht MEHR ohne
    # Obergrenze: im Free-Seattle-Lauf kippten 2/11 Chunks in endloses Generieren
    # und fraßen je ~55 min Timeout+Retry-Zyklus. Der Deckel (Default 4096 ≈ 3×
    # legitimer Chunk-Output) kappt degenerierte Läufe nach ~3 min; der gekappte
    # Output wäre ohnehin :parse_failed, es geht nichts Gültiges verloren.
    extract_cap = Worker.Settings.get(:extract_num_predict_cap, 4096)

    opts =
      [format: facts_json_schema(), num_ctx: num_ctx] ++
        Keyword.delete(sampling_opts(2), :num_predict) ++ [num_predict: extract_cap]

    # Issue #683: eigenes, kleineres Extraktions-Chunk-Budget (dichterer Output
    # pro Token als ein Resümee → kleinere Chunks halten jeden Map-Call schnell).
    budget = Worker.Settings.get(:extract_chunk_tokens, 3500)

    # Issue #683: Map-Reduce für lange Sessions. Single-Prompt timeoutet (Long-
    # Context-Generierung beim starken Extraktor; Bloat beim schwachen) und ist
    # damit an ein schwaches Modell gebunden → dünne source_refs → Verify-TPR-
    # Deckel (#677/#680). Bei langem Transkript chunken (reuse #417-Infra),
    # Fakten pro Chunk extrahieren (source_refs lösen pro Chunk korrekt auf, da
    # der Chunk echte Utterance-UUIDs hält), dann mergen + dedupen.
    result =
      if stage2_chunking_needed?(utterances, speaker_names, budget) do
        extract_facts_map_reduce(utterances, speaker_names, opts, budget)
      else
        prompt = build_facts_extraction_prompt(utterances, speaker_names)
        guard_prompt_size(prompt, num_ctx, "extraction")

        with {:ok, raw} <- LLM.complete(:summary, prompt, opts) do
          parse_facts_json(raw, utterances)
        end
      end

    case result do
      {:ok, facts} when facts != [] ->
        # Issue #864 (Epic #861 Slice C): die ZEIT-ADRESSE — welchen effektiven
        # Text sah die Extraktion pro Kontext-Einheit (Block-ID → text_hash)?
        # Die Dirty-Weiche (Slice F) keyt auf Text-Identität dagegen, NIE aufs
        # Kurations-Status-Label (async-Gemma-Zeitloch).
        extraction_saw =
          Map.new(utterances, fn u ->
            {u.id, Worker.Recording.Pipeline.Smoothing.text_hash(u.text || "")}
          end)

        {:ok, facts, extraction_saw}

      {:ok, _empty} ->
        Logger.warning("extract_facts: 0 Fakten für session=#{session_id} — als failed behandelt")
        {:error, {:extraction, :empty}}

      {:error, reason} ->
        {:error, {:extraction, reason}}
    end
  end

  # Issue #683: Map-Reduce-Extraktion. Chunken → Fakten pro Chunk → mergen.
  # Deterministischer Merge (Concat + Dedup + Neu-Index), KEIN Reduce-LLM-Call —
  # Fakten verschiedener Chunks sind chronologisch verschieden, nur der Chunk-
  # Overlap (#417, N=2) erzeugt Duplikate. Gescheiterte Chunks werden seit #763
  # EINMAL halbiert erneut versucht (die Degeneration ist input-abhängig — ein
  # kleinerer Input entschärft den Trigger oft), erst dann übersprungen; die
  # Stage läuft mit den übrigen weiter.
  defp extract_facts_map_reduce(utterances, speaker_names, opts, budget) do
    chunks = chunk_utterances(utterances, budget, speaker_names)
    n = length(chunks)

    Logger.info(
      "extract_facts: Map-Reduce — #{length(utterances)} utts → #{n} chunks (budget=#{budget})"
    )

    facts =
      chunks
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {chunk, i} ->
        Logger.info("extract_facts: Map-Chunk #{i}/#{n} (#{length(chunk)} utts)")

        case extract_facts_chunk(chunk, speaker_names, opts) do
          {:ok, fs} ->
            fs

          {:error, reason} ->
            Logger.warning(
              "extract_facts: Chunk #{i}/#{n} fehlgeschlagen (#{inspect(reason)}) — halbiere + retry (#763)"
            )

            retry_chunk_halves(chunk, i, n, speaker_names, opts)
        end
      end)
      |> merge_chunk_facts()

    {:ok, facts}
  end

  # #763: EIN Halbierungs-Retry pro gescheitertem Chunk (keine Rekursion — zwei
  # Ebenen Retry würden den Wall-Clock-Deckel wieder aufweichen). Scheitert auch
  # eine Hälfte, wird nur sie übersprungen — die andere liefert trotzdem.
  defp retry_chunk_halves(chunk, i, n, speaker_names, opts) do
    chunk
    |> split_chunk_for_retry()
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {half, h} ->
      case extract_facts_chunk(half, speaker_names, opts) do
        {:ok, fs} ->
          Logger.info("extract_facts: Chunk #{i}/#{n} Hälfte #{h}/2 ok (#{length(fs)} Fakten)")
          fs

        {:error, reason} ->
          Logger.warning(
            "extract_facts: Chunk #{i}/#{n} Hälfte #{h}/2 fehlgeschlagen (#{inspect(reason)}) — übersprungen"
          )

          []
      end
    end)
  end

  @doc """
  #763: PURE — teilt einen gescheiterten Extraktions-Chunk in zwei Hälften für
  den Halbierungs-Retry. Ein-Element-Chunks sind nicht teilbar → `[]` (kein
  Retry; derselbe Input würde identisch scheitern, temp 0).
  """
  @spec split_chunk_for_retry([map()]) :: [[map()]]
  def split_chunk_for_retry(chunk) when is_list(chunk) do
    case length(chunk) do
      len when len <= 1 -> []
      len -> chunk |> Enum.split(div(len, 2)) |> Tuple.to_list()
    end
  end

  defp extract_facts_chunk(chunk, speaker_names, opts) do
    prompt = build_facts_extraction_prompt(chunk, speaker_names)

    with {:ok, raw} <- LLM.complete(:summary, prompt, opts) do
      parse_facts_json(raw, chunk)
    end
  end

  @doc """
  Issue #683: PURE Merge der per-Chunk-Fakt-Listen — Boundary-Overlap-Duplikate
  (gleicher normalisierter Claim) entfernen (erstes Vorkommen behalten) + die
  `id`-Felder global neu durchindizieren (die per-Chunk-IDs `f1`.. kollidieren
  sonst). source_refs sind bereits auf echte UUIDs aufgelöst → kollisionsfrei.
  """
  @spec merge_chunk_facts([map()]) :: [map()]
  def merge_chunk_facts(facts) when is_list(facts) do
    {kept, _seen} =
      Enum.reduce(facts, {[], MapSet.new()}, fn f, {acc, seen} ->
        key = normalize_claim(Map.get(f, "claim", ""))

        if key == "" or MapSet.member?(seen, key),
          do: {acc, seen},
          else: {[f | acc], MapSet.put(seen, key)}
      end)

    # #864: KEIN Neu-Indizieren mehr — die IDs sind content-adressiert
    # (Parsing.fact_content_id, stabil über Chunks/Läufe); per-Chunk-Kollisionen
    # gibt es nicht (gleiche ID ⇒ derselbe Fakt ⇒ vom Dedup oben gefangen).
    Enum.reverse(kept)
  end

  # ─── Chunking-Infrastruktur (#417, seit #786 nur noch von der ────────
  # Extraktion genutzt)

  # Overlap zwischen Chunks (letzte N Utterances mitnehmen) für narrative
  # Kontinuität. Refs sind UUID-dedupe'd → Overlap doppelt nichts.
  @stage2_chunk_overlap 2

  # Issue #417: Dispatch-Prädikat — sprengt das gerenderte Transkript das
  # Chunk-Budget, schaltet die Extraktion auf Map-Reduce. Public (@doc false)
  # für den Unit-Test der Schwelle ohne LLM-Call. (Name behält das historische
  # stage2-Präfix — die Keys/Helfer der Extraktion teilen ihn, s. #786.)
  @doc false
  def stage2_chunking_needed?(utterances, speaker_names, budget) do
    estimate_tokens(render_transcript(utterances, speaker_names)) > budget
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

  # ─── JSON-Schema (Ollama-Strict-Mode, #289 Phase 1) ─────────────────
  #
  # Ollama akzeptiert für `format` entweder den String `"json"` (loser
  # JSON-Mode) oder eine JSON-Schema-Map (GBNF-Grammatik-Enforcement —
  # invalides JSON ist token-seitig unmöglich, Think-Blocks werden als
  # Nebeneffekt eliminiert). Die defensiven Parser-Fallbacks (think-strip,
  # code-fence-strip, JSON-extract) bleiben für Cloud-Backends
  # (Anthropic/OpenAI) und ältere Modelle, die ohne Schema-Mode laufen.

  # Issue #651 (Wahrheitsbild, Phase A): token-seitiges Schema für den
  # Extraktions-Output — Array atomarer Fakten.
  #
  # Issue #676: ALLE vier Felder sind `required`. Vorher waren `character` und
  # `in_game_date` optional → die GBNF-Grammar erlaubte sie wegzulassen, und
  # das taten qwen2.5:7b UND qwen3:30b auf 100 % der Fakten (0/28, 0/23, 0/18 —
  # modell-unabhängig). Damit fielen Timeline (Render.timeline/1 filtert auf
  # in_game_date) und Attribution (verify.ex braucht character_alias) tot.
  # Jetzt zwingt das Schema pro Fakt eine Entscheidung; Leerstring "" ist die
  # explizit-nicht-anwendbar-Escape (parsing.ex nullif't den in_game_date-Slot).
  defp facts_json_schema do
    %{
      "type" => "object",
      "properties" => %{
        "facts" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "claim" => %{"type" => "string"},
              "character" => %{"type" => "string"},
              # Issue #724 Slice D: Erzählzeit vs. erzählte Zeit. required (wie die
              # #676-Felder) — eine 3-Wege-Klassifikation, die die Modelle
              # zuverlässig treffen; optional würde sie zu 100 % weggelassen.
              "narration_time" => %{"type" => "string"},
              "in_game_date" => %{"type" => "string"},
              # Relativer Offset zur Session-Gegenwart („vor 10 Jahren" →
              # {value:-10, unit:"year"}). Optional — nur wenn eine Distanz fällt.
              "time_offset" => %{
                "type" => "object",
                "properties" => %{
                  "value" => %{"type" => "integer"},
                  "unit" => %{"type" => "string"}
                }
              },
              "precision" => %{"type" => "string"},
              # Issue #831 (Epic #829 Slice B): Handlungsbogen-Felder. Beide
              # required (wie die #676-Felder) — optional würde qwen sie zu
              # 100 % weglassen und der Blob bekäme nie ein Label. `fact_type`
              # als Enum (die 6 Klassen erzwingt die GBNF token-seitig);
              # `thread` als String mit Leerstring-Escape (kein Strang).
              "fact_type" => %{
                "type" => "string",
                "enum" => ~w(ereignis zustandsänderung beziehung absicht enthüllung auflösung)
              },
              "thread" => %{"type" => "string"},
              "source_refs" => %{"type" => "array", "items" => %{"type" => "string"}}
            },
            "required" => [
              "claim",
              "character",
              "narration_time",
              "in_game_date",
              "fact_type",
              "thread",
              "source_refs"
            ]
          }
        }
      },
      "required" => ["facts"]
    }
  end

  # Issue #430: Intents.publish/1 gibt immer {:ok, …} → publish_event gibt immer
  # :ok. Echte Extraktions-Fehler (LLM/Parse) propagieren über die
  # {:error, {:extraction, reason}}-Pfade.
  defp publish_event(payload) do
    {:ok, _seq} = Intents.publish(payload)
    :ok
  end
end
