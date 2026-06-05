defmodule Mix.Tasks.Lore.Seed.SourceRefs do
  @moduledoc """
  Issue #350: deterministischer Selektor für `source_refs` (Liste von
  Utterance-IDs) auf Demo-Seed-Derived-Events (Resümee/Epos/Chronik).

  Hintergrund: seit #114 tragen produktive Aufnahmen `source_refs` an den
  Stage-2/3/4-Outputs — die Utterances, die in den Eintrag eingeflossen sind.
  Die committed Demo-Seeds sind Pre-#114. Damit die Demos sich wie echte
  Aufnahmen verhalten (Refs-Popover #114, Faithfulness-Restriction,
  utterance-granularer Spalten-Sync #10), berechnen wir die Refs hier
  reproduzierbar per **lexical-overlap** statt per LLM (kein Ollama, bewahrt
  den kuratierten `content_md`).

  Bewusst KEINE Wiederverwendung von `Worker.LLM.Faithfulness` (privat, andere
  App, Wort-Trigramme zu sparse für abstrahierende Summaries vs. Schlegel-Vers).
  Stattdessen Bag-of-significant-Tokens: downcase, Satzzeichen strippen, Tokens
  < 4 Grapheme verwerfen (sprach-agnostischer Stopword-Proxy für dt/en/frnhd),
  Score = Größe der Token-Intersection.

  Genutzt von `mix lore.seed.backfill_refs` (statische JSONL) und
  `Mix.Tasks.Lore.Seed.CocDemo` (programmatischer Builder).
  """

  @default_k 6
  @default_min_overlap 2

  @doc """
  Wählt bis zu `k` Utterance-IDs aus `candidate_utts`, deren Text die meisten
  signifikanten Tokens mit `entry_text` teilt.

  `candidate_utts` ist eine Liste von Maps mit `id` + `text` (string- ODER
  atom-keyed). Rückgabe in **Utterance-Reihenfolge** (nicht Score-Reihenfolge)
  für stabile, reviewbare Diffs. Liegt der beste Overlap unter `min_overlap`,
  bleibt die Liste **leer** — bewusst kein forciertes top-K (Falsch-Refs
  vergiften die Faithfulness-Restriction + zeigen falsche Popover-Zitate; leere
  Refs fallen sauber auf das bestehende Session-Verhalten zurück).

  Optionen: `k` (Default #{@default_k}), `min_overlap` (Default #{@default_min_overlap}).
  """
  # Issue #589 (Cut 4): MapSet.size/intersection auf via tokenize/MapSet.new
  # gebauten Sets ist korrekt, aber Dialyzer trackt innerhalb des Moduls die
  # konkrete %MapSet{}-Repräsentation und meldet `call_without_opaque` (Opacity-
  # Quirk). `no_opaque` schaltet die Opacity-Prüfung gezielt für diese Funktion
  # ab — kein Verhaltens-Effekt, nur die false-positive Opacity-Warnung weg.
  @dialyzer {:no_opaque, compute_refs: 3}
  @spec compute_refs(String.t() | nil, [map()], keyword()) :: [String.t()]
  def compute_refs(entry_text, candidate_utts, opts \\ []) do
    k = Keyword.get(opts, :k, @default_k)
    min_overlap = Keyword.get(opts, :min_overlap, @default_min_overlap)
    entry_tokens = tokenize(entry_text)

    if MapSet.size(entry_tokens) == 0 do
      []
    else
      candidate_utts
      |> Enum.with_index()
      |> Enum.map(fn {utt, idx} ->
        score = MapSet.size(MapSet.intersection(entry_tokens, tokenize(utt_text(utt))))
        {idx, utt_id(utt), score}
      end)
      |> Enum.filter(fn {_idx, id, score} -> score >= min_overlap and is_binary(id) end)
      # Top-K nach Score (desc), Tie-Break nach Original-Index (stabil).
      |> Enum.sort_by(fn {idx, _id, score} -> {-score, idx} end)
      |> Enum.take(k)
      # Zurück in Utterance-Reihenfolge.
      |> Enum.sort_by(fn {idx, _id, _score} -> idx end)
      |> Enum.map(fn {_idx, id, _score} -> id end)
      |> Enum.uniq()
    end
  end

  @doc """
  Union mehrerer Ref-Listen (dedup, Reihenfolge = erstes Vorkommen). Für das
  campaign-level Epos, dessen Refs in der echten Pipeline die deduped Union
  aller Summary-Refs sind.
  """
  @spec union_refs([[String.t()]]) :: [String.t()]
  def union_refs(ref_lists) do
    ref_lists |> List.flatten() |> Enum.uniq()
  end

  # ─── Internals ────────────────────────────────────────────────────

  defp tokenize(nil), do: MapSet.new()

  defp tokenize(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}\s]/u, " ")
    |> String.split()
    |> Enum.filter(&(String.length(&1) >= 4))
    |> MapSet.new()
  end

  defp tokenize(_), do: MapSet.new()

  defp utt_id(%{id: id}), do: id
  defp utt_id(%{"id" => id}), do: id
  defp utt_id(_), do: nil

  defp utt_text(%{text: t}), do: t
  defp utt_text(%{"text" => t}), do: t
  defp utt_text(_), do: ""
end
