defmodule Worker.Recording.Pipeline.Parsing do
  @moduledoc """
  Issue #583 (God-Module-Split aus `Worker.Recording.Pipeline`): die Parse-/JSON-/
  Sanitize-Schicht — robustes Dekodieren des Extraktions-Outputs (#651),
  source_refs-Auflösung, `<think>`/Code-Fence-Strip, Token-Schätzung/Prompt-
  Guard. Reine Funktionen (stdlib + Jason). Façade + Stages erreichen die
  Publics via import; Test-erreichbare via Façade-defdelegate. Die Chain-Parser
  (Summary/Epos/Chronik + Fabrication-Filter) sind seit #786 entfernt.
  """
  require Logger

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

  # Issue #651 (Wahrheitsbild, Phase A): Parser für den Extraktions-Output.
  # Erwartet `%{"facts" => [%{"claim", "character", "in_game_date", "source_refs"}]}`.
  # Normalisiert jeden Fakt auf das persistierte Shape (id, claim, entity_id,
  # character_alias, in_game_date, source_refs, verified?). source_refs werden
  # via Index-Map auf echte UUIDs aufgelöst (Halluzinationen rausgefiltert).
  #
  # FLAG STATT DROP: ein Fakt mit leeren source_refs wird NICHT verworfen —
  # ob er belegt ist, entscheidet das Phase-B-Verify-Gate. Verworfen wird nur
  # Junk ohne `claim`. `verified?` startet false (Phase B setzt es).
  # `entity_id` = minimal normalisierter Alias (die kanonische alias→entity-
  # Registry ist Phase B); das Feld-Shape steht aber jetzt.
  @doc false
  @spec parse_facts_json(binary() | nil, [map()]) :: {:ok, [map()]} | {:error, atom()}
  def parse_facts_json(raw, utterances) when is_binary(raw) do
    index_map = utterance_index_map(utterances)
    valid_ids = MapSet.new(utterances, & &1.id)

    case parse_with_notes_decode(raw) do
      {{:ok, %{"facts" => list}}, _notes} when is_list(list) ->
        facts =
          list
          |> Enum.with_index(1)
          |> Enum.map(fn {f, i} -> normalize_fact(f, i, index_map, valid_ids) end)
          |> Enum.reject(&is_nil/1)

        {:ok, facts}

      {{:ok, _other}, _notes} ->
        {:error, :no_facts_key}

      {:parse_failed, _notes} ->
        {:error, :parse_failed}
    end
  end

  def parse_facts_json(_, _), do: {:error, :parse_failed}

  defp normalize_fact(f, i, index_map, valid_ids) when is_map(f) do
    claim = f |> Map.get("claim") |> trim_or_empty()

    if claim == "" do
      nil
    else
      alias_name = f |> Map.get("character") |> trim_or_empty()

      %{
        "id" => "f#{i}",
        "claim" => claim,
        "entity_id" => normalize_entity_id(alias_name),
        "character_alias" => alias_name,
        "in_game_date" => nil_if_blank(f["in_game_date"]),
        # Issue #724 Slice D: temporale Felder. narration_time Whitelist mit
        # Default "present" (nie crashen bei Modell-Garbage); time_offset nur wenn
        # {value:int, unit:string} valide, sonst nil; precision Whitelist|nil.
        "narration_time" => normalize_narration(f["narration_time"]),
        "time_offset" => normalize_offset(f["time_offset"]),
        "precision" => normalize_precision(f["precision"]),
        "source_refs" => resolve_source_refs(f["source_refs"], index_map, valid_ids),
        "verified?" => false
      }
    end
  end

  defp normalize_fact(_, _, _, _), do: nil

  @narration_times ~w(present flashback future unknown)
  defp normalize_narration(t) when is_binary(t) do
    d = String.downcase(String.trim(t))
    if d in @narration_times, do: d, else: "present"
  end

  defp normalize_narration(_), do: "present"

  @precisions ~w(day month season year decade)
  defp normalize_precision(p) when is_binary(p) do
    d = String.downcase(String.trim(p))
    if d in @precisions, do: d, else: nil
  end

  defp normalize_precision(_), do: nil

  # {value:int, unit:string} — nur valide Kombinationen durchlassen, sonst nil
  # (der Resolver behandelt ein vorhandenes-aber-kaputtes Offset konservativ).
  defp normalize_offset(%{"value" => v, "unit" => u}) when is_integer(v) and is_binary(u) do
    %{"value" => v, "unit" => String.downcase(String.trim(u))}
  end

  defp normalize_offset(_), do: nil

  defp trim_or_empty(s) when is_binary(s), do: String.trim(s)
  defp trim_or_empty(_), do: ""

  defp nil_if_blank(s) when is_binary(s),
    do: if(String.trim(s) == "", do: nil, else: String.trim(s))

  defp nil_if_blank(_), do: nil

  # Minimal-Canonicalization des Alias als entity_id-Platzhalter (Phase-B-
  # Registry ersetzt das durch echte Identitäts-Auflösung): lowercase +
  # Whitespace zusammenfassen. Leerer Alias → "".
  defp normalize_entity_id(""), do: ""

  defp normalize_entity_id(alias_name) do
    alias_name |> String.downcase() |> String.replace(~r/\s+/u, " ") |> String.trim()
  end

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
  # Issue #417/#683: die Extraktion chunked, bevor dieser Guard feuert — er
  # bleibt als Diagnose für den Single-Prompt-Pfad.
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
  # Prompt-Größen-Guard UND vom Extraktions-Chunking (chunk_utterances/3).
  def estimate_tokens(text) when is_binary(text), do: div(byte_size(text), 3)

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
