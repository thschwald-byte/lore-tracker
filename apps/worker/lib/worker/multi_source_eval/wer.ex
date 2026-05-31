defmodule Worker.MultiSourceEval.Wer do
  @moduledoc """
  Edit-Distance-Alignment + Backtrace-Attribution für WER (Issue #377 Plan v5
  Section C).

  Eine einzige DP-Berechnung pro Sprecher (Levenshtein auf Token-Ebene),
  Aggregation als Micro-Average über alle Sprecher. Bucket-Aufschlüsselung
  via Backtrace auf der Referenz-Seite — Insertions zwischen ref_i und
  ref_{i+1} werden ref_{i+1} zugeordnet (Konvention).
  """

  alias Worker.MultiSourceEval.Normalize

  @doc """
  Aligniert die erwarteten Turns eines Sprechers gegen seine tatsächlichen
  Utterances.

  `expected_turns` — Liste der Session-JSON-Turn-Maps für diesen Sprecher
  (mit `"expected"` + `"length_bucket"`-Feldern). `actual_utterances` — Liste
  der Worker-Repo-Utterance-Maps für diesen Sprecher (mit `"content"`-Feld,
  zeitlich sortiert).

  Rückgabe-Struktur:

      %{
        ref_words: [%{word: String.t(), turn_idx: integer, length_bucket: String.t()}, ...],
        hyp_words: [String.t(), ...],
        alignment: [{:match | :sub | :del | :ins, ref_idx | nil, hyp_idx | nil}, ...],
        edit_count: integer  # Anzahl Edits (sub + del + ins)
      }
  """
  def align_speaker(expected_turns, actual_utterances) do
    ref_words = expand_turns_to_words(expected_turns)
    hyp_words = expand_utterances_to_words(actual_utterances)

    r_tokens = Enum.map(ref_words, & &1.word)
    {alignment, edits} = edit_align(r_tokens, hyp_words)

    %{
      ref_words: ref_words,
      hyp_words: hyp_words,
      alignment: alignment,
      edit_count: edits
    }
  end

  @doc """
  Micro-Average-WER über alle Sprecher: Σ Edits / Σ Referenz-Wörter.
  KEIN Macro-Mittel von Per-Sprecher-Raten.
  """
  def global_wer(per_speaker) when is_map(per_speaker) do
    {total_edits, total_refs} =
      Enum.reduce(per_speaker, {0, 0}, fn {_spk, %{edit_count: e, ref_words: rw}}, {te, tr} ->
        {te + e, tr + length(rw)}
      end)

    cond do
      total_refs == 0 -> 0.0
      true -> total_edits / total_refs
    end
  end

  @doc """
  Bucket-Aufschlüsselung via Backtrace-Attribution. Konvention für
  Insertions: eine ins-Op zwischen ref_i und ref_{i+1} wird ref_{i+1}
  zugerechnet (nächstes Referenz-Wort). Trailing insertions (nach letztem
  ref-Wort) gehen an ref_last.

  Rückgabe:

      %{"short" => %{wer: float, edits: int, ref_words: int}, ...}
  """
  def bucket_wer(per_speaker) when is_map(per_speaker) do
    per_speaker
    |> Enum.reduce(%{}, fn {_spk, alignment}, acc ->
      accumulate_buckets(alignment.alignment, alignment.ref_words, acc)
    end)
    |> Map.new(fn {bucket, %{edits: e, refs: r}} ->
      wer = if r == 0, do: 0.0, else: e / r
      {bucket, %{wer: wer, edits: e, ref_words: r}}
    end)
  end

  # ─── Internals ──────────────────────────────────────────────────────

  defp expand_turns_to_words(turns) do
    turns
    |> Enum.with_index()
    |> Enum.flat_map(fn {turn, idx} ->
      bucket = field(turn, "length_bucket")
      expected = field(turn, "expected") || ""

      expected
      |> Normalize.words()
      |> Enum.map(fn w -> %{word: w, turn_idx: idx, length_bucket: bucket} end)
    end)
  end

  defp expand_utterances_to_words(utts) do
    utts
    |> Enum.flat_map(fn utt ->
      text = field(utt, "text") || ""
      Normalize.words(text)
    end)
  end

  defp field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  end

  # ── Edit-Distance DP + Backtrace ────────────────────────────────────

  defp edit_align([], []), do: {[], 0}

  defp edit_align(ref, hyp) do
    r = length(ref)
    h = length(hyp)
    ref_arr = to_index_map(ref)
    hyp_arr = to_index_map(hyp)

    d = build_dp(r, h, ref_arr, hyp_arr)
    alignment = backtrace(d, r, h, ref_arr, hyp_arr, [])
    {alignment, Map.fetch!(d, {r, h})}
  end

  defp to_index_map(list) do
    list
    |> Enum.with_index()
    |> Map.new(fn {w, i} -> {i, w} end)
  end

  defp build_dp(r, h, ref_arr, hyp_arr) do
    Enum.reduce(0..r, %{}, fn i, acc ->
      Enum.reduce(0..h, acc, fn j, acc2 ->
        cost =
          cond do
            i == 0 ->
              j

            j == 0 ->
              i

            true ->
              same? = ref_arr[i - 1] == hyp_arr[j - 1]
              diag = acc2[{i - 1, j - 1}]
              sub_cost = if same?, do: diag, else: diag + 1
              del_cost = acc2[{i - 1, j}] + 1
              ins_cost = acc2[{i, j - 1}] + 1
              Enum.min([sub_cost, del_cost, ins_cost])
          end

        Map.put(acc2, {i, j}, cost)
      end)
    end)
  end

  defp backtrace(_d, 0, 0, _ref, _hyp, acc), do: acc

  defp backtrace(d, i, 0, ref, hyp, acc) do
    backtrace(d, i - 1, 0, ref, hyp, [{:del, i - 1, nil} | acc])
  end

  defp backtrace(d, 0, j, ref, hyp, acc) do
    backtrace(d, 0, j - 1, ref, hyp, [{:ins, nil, j - 1} | acc])
  end

  defp backtrace(d, i, j, ref, hyp, acc) do
    curr = d[{i, j}]
    same? = ref[i - 1] == hyp[j - 1]
    diag = d[{i - 1, j - 1}]
    up = d[{i - 1, j}]

    cond do
      same? and diag == curr ->
        backtrace(d, i - 1, j - 1, ref, hyp, [{:match, i - 1, j - 1} | acc])

      not same? and diag + 1 == curr ->
        backtrace(d, i - 1, j - 1, ref, hyp, [{:sub, i - 1, j - 1} | acc])

      up + 1 == curr ->
        backtrace(d, i - 1, j, ref, hyp, [{:del, i - 1, nil} | acc])

      true ->
        # left + 1 == curr (Insertion)
        backtrace(d, i, j - 1, ref, hyp, [{:ins, nil, j - 1} | acc])
    end
  end

  # ── Bucket-Backtrace-Attribution ────────────────────────────────────

  defp accumulate_buckets(alignment, ref_words, init) do
    total_refs = length(ref_words)
    ref_arr = ref_words |> Enum.with_index() |> Map.new(fn {w, i} -> {i, w} end)

    {result, _cursor} =
      Enum.reduce(alignment, {init, 0}, fn op, {acc, cursor} ->
        attribute_op(op, acc, cursor, ref_arr, total_refs)
      end)

    result
  end

  defp attribute_op({:match, ref_idx, _h}, acc, _cursor, ref_arr, _total) do
    bucket = ref_arr[ref_idx].length_bucket
    {bump(acc, bucket, 0, 1), ref_idx + 1}
  end

  defp attribute_op({:sub, ref_idx, _h}, acc, _cursor, ref_arr, _total) do
    bucket = ref_arr[ref_idx].length_bucket
    {bump(acc, bucket, 1, 1), ref_idx + 1}
  end

  defp attribute_op({:del, ref_idx, nil}, acc, _cursor, ref_arr, _total) do
    bucket = ref_arr[ref_idx].length_bucket
    {bump(acc, bucket, 1, 1), ref_idx + 1}
  end

  defp attribute_op({:ins, nil, _h}, acc, cursor, ref_arr, total_refs) do
    bucket =
      cond do
        cursor < total_refs -> ref_arr[cursor].length_bucket
        total_refs > 0 -> ref_arr[total_refs - 1].length_bucket
        true -> nil
      end

    if bucket, do: {bump(acc, bucket, 1, 0), cursor}, else: {acc, cursor}
  end

  defp bump(acc, bucket, d_edits, d_refs) do
    Map.update(
      acc,
      bucket,
      %{edits: d_edits, refs: d_refs},
      fn %{edits: e, refs: r} ->
        %{edits: e + d_edits, refs: r + d_refs}
      end
    )
  end
end
