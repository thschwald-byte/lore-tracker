defmodule Worker.MultiSourceEval.Metrics do
  @moduledoc """
  Sekundär-Metriken neben WER (Issue #377 Plan v5 Section G + H + I).

  Bewusst getrennt von `Worker.MultiSourceEval.Wer` — WER ist die Hauptzahl,
  die hier definierten Metriken sind Korrektheits-Smoke-Tests (Drift,
  Routing, NE-Consistency).
  """

  alias Worker.MultiSourceEval.Normalize

  @ne_fuzzy_floor 1
  @ne_fuzzy_cap 2

  @doc """
  Pro turn in den expected_turns: diff zwischen erwartetem start_ms und der
  ersten actual utterance dieses Sprechers, die zeitlich nach dem turn-Start
  liegt und davor noch unbenutzt war.

  Liefert `[%{turn_idx, speaker, expected_start_ms, actual_start_ms_or_nil, drift_ms}]`.

  Wichtig: das ist **kein** strikter Per-Turn-Matcher (das wäre Quatsch — der
  Plan verbietet das explizit), sondern eine pro-Sprecher chronologische
  Zuordnung. Wenn der Sprecher gar nicht aufgetaucht ist (z.B. weil whisper
  ihn ganz silent gefunden hat), bleibt `actual_start_ms_or_nil = nil` und
  drift_ms = nil.
  """
  def timeline_drift(expected_turns, utterances, session_started_at) do
    # Pre-index utterances by discord_id (Sprecher-Name → ID kommt aus session_speakers)
    utts_by_did = Enum.group_by(utterances, & &1.discord_id)

    expected_turns
    |> Enum.with_index()
    |> Enum.map(fn {turn, idx} ->
      %{
        turn_idx: idx,
        speaker: turn["speaker"],
        expected_start_ms: turn["start_ms"],
        length_bucket: turn["length_bucket"],
        # actual_did wird vom Aufrufer übergeben (über die Session-Speaker-Map)
        actual_start_ms: nil,
        drift_ms: nil
      }
    end)
    |> map_actual_starts(expected_turns, utts_by_did, session_started_at)
  end

  defp map_actual_starts(drift_entries, expected_turns, utts_by_did, session_started_at) do
    # discord_id pro turn aus utterances ableiten — der Driver hat die
    # mapping Speaker-Name → discord_id im Session-JSON; wir bekommen sie
    # via session_speakers (vom Aufrufer übergeben)
    drift_entries
    |> Enum.zip(expected_turns)
    |> Enum.map(fn {entry, turn} ->
      did = turn["discord_id"]
      utts = Map.get(utts_by_did, did, [])

      actual_ms =
        Enum.find_value(utts, fn utt ->
          DateTime.diff(utt.timestamp, session_started_at, :millisecond)
        end)

      drift = if actual_ms, do: actual_ms - entry.expected_start_ms, else: nil
      %{entry | actual_start_ms: actual_ms, drift_ms: drift}
    end)
  end

  @doc """
  Annotiert die expected_turns mit ihrer discord_id basierend auf der
  session_speakers-Map (`%{speaker_name => discord_id}`). Wird vor
  `timeline_drift/3` aufgerufen.
  """
  def attach_discord_ids(turns, speakers_map) do
    Enum.map(turns, fn turn ->
      did = Map.fetch!(speakers_map, turn["speaker"])
      Map.put(turn, "discord_id", did)
    end)
  end

  @doc """
  Smoke-Test: jede Utterance trägt eine `discord_id`, die in der Speaker-Map
  vorkommt? Wahr = Routing hat keine fremden discord_ids erfunden.

  Wichtig (Plan v5 Section I): das ist ein **Worker-internal** Smoke-Test —
  der `AudioBuffer.append`-Pfad nimmt die discord_id von außen, eine
  Verfälschung kann hier strukturell nur durch einen Bug im Materializer oder
  in `Transcribe.transcribe_one/4` entstehen. Hub-side Routing (`pick_leader`)
  wird durch diesen Test NICHT überprüft.
  """
  def speaker_routing_smoke_ok?(utterances, speakers_map) when is_map(speakers_map) do
    known_dids = MapSet.new(Map.values(speakers_map))

    Enum.all?(utterances, fn utt ->
      MapSet.member?(known_dids, utt.discord_id)
    end)
  end

  @doc """
  Named-Entity-Konsistenz: für jeden Vokabel-Eintrag wird im normalisierten
  Output nach Vorkommen + Fuzzy-Varianten gesucht (Char-Level-Levenshtein).
  Schwelle: `min(2, max(1, round(len * 0.3)))` — floor 1 / cap 2.

  Liefert `%{vocab_word => %{occurrences, fuzzy_variants, consistent?}}`.
  `consistent? = true` wenn maximal eine Schreibweise im Output erscheint.
  """
  def named_entity_consistency(vocab, utterances) when is_list(vocab) do
    all_words =
      utterances
      |> Enum.flat_map(fn utt -> Normalize.words(utt.text || "") end)

    Map.new(vocab, fn name ->
      threshold = ne_threshold(name)
      norm_name = name |> String.normalize(:nfc) |> String.downcase()

      variants =
        all_words
        |> Enum.filter(fn w -> char_levenshtein(w, norm_name) <= threshold end)
        |> Enum.uniq()

      {name,
       %{
         occurrences: length(variants),
         fuzzy_variants: variants,
         consistent?: length(variants) <= 1
       }}
    end)
  end

  @doc "NE-Fuzzy-Schwelle: floor #{@ne_fuzzy_floor} / cap #{@ne_fuzzy_cap}, Standard round(len * 0.3)."
  def ne_threshold(name) do
    base = round(String.length(name) * 0.3)
    base |> max(@ne_fuzzy_floor) |> min(@ne_fuzzy_cap)
  end

  # Char-level Levenshtein für kurze Wörter (≤ ~30 chars). Map-DP.
  defp char_levenshtein(a, b) do
    a_chars = String.graphemes(a)
    b_chars = String.graphemes(b)
    do_levenshtein(a_chars, b_chars)
  end

  defp do_levenshtein(a, b) do
    al = length(a)
    bl = length(b)
    a_map = a |> Enum.with_index() |> Map.new(fn {c, i} -> {i, c} end)
    b_map = b |> Enum.with_index() |> Map.new(fn {c, i} -> {i, c} end)

    d =
      Enum.reduce(0..al, %{}, fn i, acc ->
        Enum.reduce(0..bl, acc, fn j, acc2 ->
          cost =
            cond do
              i == 0 ->
                j

              j == 0 ->
                i

              true ->
                same? = a_map[i - 1] == b_map[j - 1]
                diag = acc2[{i - 1, j - 1}] + if same?, do: 0, else: 1
                up = acc2[{i - 1, j}] + 1
                left = acc2[{i, j - 1}] + 1
                Enum.min([diag, up, left])
            end

          Map.put(acc2, {i, j}, cost)
        end)
      end)

    Map.fetch!(d, {al, bl})
  end
end
