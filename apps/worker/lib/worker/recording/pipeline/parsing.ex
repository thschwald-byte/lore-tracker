defmodule Worker.Recording.Pipeline.Parsing do
  @moduledoc """
  Issue #583 (God-Module-Split aus `Worker.Recording.Pipeline`): die Parse-/JSON-/
  Sanitize-Schicht — robustes Dekodieren der LLM-Stage-Outputs (Summary/Epos/
  Chronik), source_refs-Auflösung, Halluzinations-Filter, `<think>`/Code-Fence-
  Strip, Token-Schätzung/Prompt-Guard. Reine Funktionen (stdlib + Jason). Façade
  + Stages erreichen die Publics via import; Test-erreichbare via Façade-defdelegate.
  """
  require Logger

  # Issue #230 (#583: mit fabricated_entry?/1 hierher gezogen): LLM-Sentinel-
  # Strings die selbst-eingestandene Fabrication markieren. Tauchen sie in
  # `in_game_date`/`label`/`summary` eines Chronik-Eintrags auf, droppt
  # `filter_fabricated_chronik/1` den Eintrag. Konservativ — nur explizite
  # Placeholder, keine subjektiven Unsicherheits-Wörter.
  @fabrication_sentinels [
    ~r/nicht im transkript/iu,
    ~r/nicht erwähnt/iu,
    ~r/keine angabe/iu,
    ~r/^unbekannt$/iu,
    ~r/^n\/a$/i,
    ~r/^---+$/
  ]

  def parse_chronik_json(raw) do
    {entries, _notes} = parse_chronik_json_with_notes(raw)
    entries
  end

  # Issue #288: Notes-Variante. Returns {entries, format_notes} damit der
  # Caller (stage4 / probelauf) die Strip-Diagnostik im pipeline_stage-
  # Event mit-publishen kann.
  @doc false
  @spec parse_chronik_json_with_notes(binary() | nil) :: {[map()], binary()}
  def parse_chronik_json_with_notes(raw) when is_binary(raw) do
    case parse_with_notes_decode(raw) do
      {{:ok, %{"entries" => list}}, notes} when is_list(list) -> {list, notes}
      {{:ok, %{"chronik" => list}}, notes} when is_list(list) -> {list, notes}
      {{:ok, %{"timeline" => list}}, notes} when is_list(list) -> {list, notes}
      {{:ok, list}, notes} when is_list(list) -> {list, notes}
      {{:ok, _other}, _notes} -> {[], "parse_failed"}
      {:parse_failed, notes} -> {[], notes}
    end
  end

  def parse_chronik_json_with_notes(_), do: {[], "ok"}

  # Issue #114: Parser für Stage-2-JSON-Output. Erwartetes Schema:
  #   {"content_md": "...", "source_refs": ["utt-id-1", ...]}
  # Robustness analog parse_chronik_json/1 (strip thinking-blocks + fences +
  # JSON-extract). Bei Parse-Fehler: Fallback auf den Trim des Raw-Outputs
  # als content_md mit leeren refs — die Pipeline läuft weiter, nur der
  # Audit-Trail fehlt.
  #
  # `valid_utterance_ids` ist die Whitelist der Utterance-IDs aus der Session.
  # Source-refs die nicht in dieser Liste sind (LLM-Halluzination) werden
  # silent gefiltert — der Output bleibt dadurch konsistent mit dem Repo.
  @doc false
  @spec parse_summary_json(binary() | nil, [map()]) :: {binary(), [binary()]}
  def parse_summary_json(raw, utterances) do
    case parse_summary_json_with_status(raw, utterances) do
      {:parsed, md, refs, _notes} -> {md, refs}
      {:fallback, md, _notes} -> {md, []}
    end
  end

  # Issue #289 Phase 2: Status-Variante. Differenziert zwischen
  # erfolgreichem JSON-Parse (`:parsed`) und Fallback auf raw-Text
  # (`:fallback`). Der Caller (stage2/3) entscheidet auf der Statusbasis
  # ob ein Retry mit Korrektur-Prompt sinnvoll ist.
  # Issue #288: 4. Tupel-Element ist `format_notes` (siehe strip_and_note/1)
  # — propagiert sich ins `pipeline_stage`-Status-Event.
  @doc false
  @spec parse_summary_json_with_status(binary() | nil, [map()]) ::
          {:parsed, binary(), [binary()], binary()} | {:fallback, binary(), binary()}
  def parse_summary_json_with_status(raw, utterances) when is_binary(raw) do
    valid_ids = MapSet.new(utterances, & &1.id)

    case parse_with_notes_decode(raw) do
      {{:ok, %{"content_md" => md} = m}, notes} when is_binary(md) ->
        # Issue #307: Kurz-IDs (`u3`) über die Index-Map zurück auf echte UUIDs
        # auflösen. Dual-akzeptierend, damit echte UUIDs (alte Pfade / Tests)
        # weiterhin durchgehen.
        index_map = utterance_index_map(utterances)
        refs = resolve_source_refs(Map.get(m, "source_refs"), index_map, valid_ids)

        {:parsed, String.trim(md), refs, notes}

      {{:ok, _other}, _notes} ->
        # JSON geparst, aber kein content_md → kein Schema-Match → "parse_failed"
        {:fallback, String.trim(raw), "parse_failed"}

      {:parse_failed, notes} ->
        # Fallback: Modell hat freie Form geantwortet — nimm den ganzen Text
        # als content_md, keine refs.
        {:fallback, String.trim(raw), notes}
    end
  end

  def parse_summary_json_with_status(_, _), do: {:fallback, "", "ok"}

  # Issue #114: Stage-3-JSON-Parser. Robustness analog parse_summary_json.
  # Bei Parse-Fehler: Fallback content_md = trim(raw), refs = fallback_refs
  # (= Vereinigung der einfließenden Summary-Refs aus stage3/3).
  @doc false
  @spec parse_epos_json(binary() | nil, [binary()]) :: {binary(), [binary()]}
  def parse_epos_json(raw, fallback_refs) do
    {md, refs, _notes} = parse_epos_json_with_notes(raw, fallback_refs)
    {md, refs}
  end

  # Issue #288: Notes-Variante (analog parse_chronik_json_with_notes).
  @doc false
  @spec parse_epos_json_with_notes(binary() | nil, [binary()]) ::
          {binary(), [binary()], binary()}
  def parse_epos_json_with_notes(raw, fallback_refs)
      when is_binary(raw) and is_list(fallback_refs) do
    case parse_with_notes_decode(raw) do
      {{:ok, %{"content_md" => md} = m}, notes} when is_binary(md) ->
        refs =
          case Map.get(m, "source_refs") do
            list when is_list(list) ->
              list |> Enum.filter(&is_binary/1) |> Enum.uniq()

            _ ->
              fallback_refs
          end

        {String.trim(md), refs, notes}

      {{:ok, _other}, _notes} ->
        {String.trim(raw), fallback_refs, "parse_failed"}

      {:parse_failed, notes} ->
        {String.trim(raw), fallback_refs, notes}
    end
  end

  def parse_epos_json_with_notes(_, fallback_refs) when is_list(fallback_refs),
    do: {"", fallback_refs, "ok"}

  # Issue #114: pro Chronik-Eintrag die LLM-source_refs robust machen —
  # erwarten Liste of binaries, filtern Junk raus, dedupe, fallback [].
  def normalize_entry_refs(list) when is_list(list) do
    list
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  def normalize_entry_refs(_), do: []

  # Issue #307: Kurz-ID-Mapping. Bildet die Lauf-Indizes `u1`…`uN` (im Prompt)
  # auf die echten Utterance-UUIDs ab — dieselbe `Enum.with_index/2`-Reihenfolge
  # wie der Prompt-Builder, daher muss keine Map durch die Pipeline gereicht
  # werden, der Parser rekonstruiert sie aus der Utterance-Liste.
  def utterance_index_map(utterances) do
    utterances
    |> Enum.with_index(1)
    |> Map.new(fn {u, i} -> {"u#{i}", u.id} end)
  end

  # Issue #307: LLM-source_refs auf echte UUIDs auflösen. Dual: erst Kurz-ID
  # über die Index-Map, sonst Passthrough wenn der Ref schon eine valide echte
  # UUID ist (Robustheit + Backward-Compat zu Tests/alten Pfaden). Alles andere
  # — Halluzinationen, Prompt-Platzhalter wie `<utterance-id-3>` (#114-Leak) —
  # fällt raus.
  def resolve_source_refs(refs, index_map, valid_ids) when is_list(refs) do
    refs
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&normalize_short_ref/1)
    |> Enum.map(fn ref ->
      cond do
        Map.has_key?(index_map, ref) -> Map.fetch!(index_map, ref)
        MapSet.member?(valid_ids, ref) -> ref
        true -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  def resolve_source_refs(_, _, _), do: []

  defp normalize_short_ref(ref) do
    ref
    |> String.trim()
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> String.trim()
  end

  # Issue #307: grobe Token-Schätzung (Deutsch + Kurz-IDs ≈ 3 Bytes/Token,
  # gemessen in docs/Performance.md). Liegt der Prompt über `num_ctx`,
  # trunkiert Ollama den Transkript-ANFANG kommentarlos (behält die jüngsten
  # Token) — wir loggen das wenigstens als Warning, statt unbemerkt ein halbes
  # Transkript zu verarbeiten.
  #
  # Issue #417: Für Stage 2 existiert das Chunking jetzt (Map-Reduce greift,
  # bevor dieser Guard feuert) — der Guard bleibt als Diagnose für den
  # Single-Prompt-Pfad und für Stage 3/4 (noch ohne Chunking).
  def guard_prompt_size(prompt, num_ctx, stage) when is_integer(num_ctx) do
    est = estimate_tokens(prompt)

    if est > num_ctx do
      Logger.warning(
        "Pipeline: #{stage} Prompt ~#{est} tok > num_ctx=#{num_ctx} — " <>
          "Ollama schneidet den Transkript-Anfang still ab."
      )
    end

    :ok
  end

  def guard_prompt_size(_prompt, _num_ctx, _stage), do: :ok

  # Issue #307/#417: gemeinsame grobe Token-Heuristik (≈ 3 Bytes/Token für
  # Deutsch + `[uN]`-Kurz-IDs, gemessen in docs/Performance.md). Genutzt vom
  # Prompt-Größen-Guard UND vom Stage-2-Chunking (chunk_utterances/2).
  def estimate_tokens(text) when is_binary(text), do: div(byte_size(text), 3)

  # Issue #230: drop Einträge die LLM-Sentinel-Strings enthalten (selbst-
  # eingestandene Fabrication wie `in_game_date == "Nicht im Transkript
  # erwähnt"`). Public via @doc false damit der Pipeline-Filter-Test ohne
  # GenServer-Setup direkt callen kann — analog zu `parse_chronik_json/1`.
  @doc false
  def filter_fabricated_chronik(entries) when is_list(entries) do
    {kept, dropped} = Enum.split_with(entries, &(not fabricated_entry?(&1)))

    if dropped != [] do
      sample =
        dropped
        |> List.first()
        |> case do
          %{} = e ->
            Map.get(e, "label") || Map.get(e, "title") || Map.get(e, "in_game_date") || ""

          _ ->
            ""
        end

      Logger.warning(
        "Stage 4: filtered #{length(dropped)} fabricated chronik entries " <>
          "(kept #{length(kept)}). Sample=#{inspect(sample)}"
      )
    end

    kept
  end

  def filter_fabricated_chronik(_), do: []

  defp fabricated_entry?(entry) when is_map(entry) do
    fields = [
      Map.get(entry, "in_game_date") || Map.get(entry, "date") || "",
      Map.get(entry, "label") || Map.get(entry, "title") || "",
      Map.get(entry, "summary") || Map.get(entry, "description") || ""
    ]

    Enum.any?(@fabrication_sentinels, fn pattern ->
      Enum.any?(fields, fn field ->
        is_binary(field) and Regex.match?(pattern, field)
      end)
    end)
  end

  defp fabricated_entry?(_), do: true

  defp strip_think_blocks(s) do
    Regex.replace(~r/<think>.*?<\/think>/s, s, "")
  end

  defp strip_code_fence(s) do
    case Regex.run(~r/```(?:json)?\s*\n?(.+?)\n?```/s, s) do
      [_, inner] -> inner
      _ -> s
    end
  end

  # Issue #288: zentraler Sanitize-Helper. Wendet die Strip-Stufen
  # nacheinander an und akkumuliert welche tatsächlich gegriffen haben als
  # pipe-getrennter String (`"think_stripped|fence_unwrapped"`). Wenn keine
  # Stufe greift → `"ok"`. `extract_json_blob` zählt bewusst nicht (Last-
  # Resort-Prose-Extract, kein diagnostisches Signal — Issue #288 spec).
  @doc false
  def strip_and_note(raw) when is_binary(raw) do
    {after_think, notes_after_think} =
      case strip_think_blocks(raw) do
        ^raw -> {raw, []}
        stripped -> {stripped, ["think_stripped"]}
      end

    {after_fence, notes_after_fence} =
      case strip_code_fence(after_think) do
        ^after_think -> {after_think, notes_after_think}
        stripped -> {stripped, notes_after_think ++ ["fence_unwrapped"]}
      end

    cleaned = extract_json_blob(after_fence)
    notes_str = if notes_after_fence == [], do: "ok", else: Enum.join(notes_after_fence, "|")

    {cleaned, notes_str}
  end

  def strip_and_note(_), do: {"", "ok"}

  # Issue #288: kombiniert strip+notes mit dem Parse-Outcome. Wenn
  # Jason.decode scheitert wird `format_notes` zu `"parse_failed"`
  # promoviert (überstimmt die strip-Notes, die ohnehin nicht persistiert
  # werden wenn der Parse fehlschlägt).
  defp parse_with_notes_decode(raw) do
    {cleaned, strip_notes} = strip_and_note(raw)

    case Jason.decode(cleaned) do
      {:ok, decoded} -> {{:ok, decoded}, strip_notes}
      {:error, _} -> {:parse_failed, "parse_failed"}
    end
  end

  defp extract_json_blob(s) do
    trimmed = String.trim(s)

    cond do
      trimmed == "" ->
        ""

      String.starts_with?(trimmed, "{") or String.starts_with?(trimmed, "[") ->
        trimmed

      true ->
        case Regex.run(~r/(\{.*\}|\[.*\])/s, trimmed) do
          [_, json] -> json
          _ -> trimmed
        end
    end
  end
end
