defmodule Worker.Recording.PipelineStage2ChunkingTest do
  @moduledoc """
  Issue #417/#683: Chunking-Bausteine der Extraktions-Map-Reduce (seit #786
  der einzige Nutzer — der Chain-Stage-2-Pfad ist entfernt).

  Getestet werden die **puren** Bausteine direkt gegen die doc-hidden public
  Funktionen — `chunk_utterances/3`, `stage2_chunking_needed?/3`. Die volle
  Map-Reduce-Orchestrierung läuft durch einen echten LLM und wird im PR-Test
  verifiziert — kein Mock-Backend im Repo.

  Token-Heuristik (wie im Code): `estimate_tokens(text) = div(byte_size(text), 3)`.
  Fixtures sind so dimensioniert, dass eine Utterance-Zeile genau 10 Token wiegt:
  `transcript_line` = `"[u] " <> name <> ": " <> text` = 4 + 1 + 2 + 23 = 30 Bytes.
  """

  use ExUnit.Case, async: true

  alias Worker.Recording.Pipeline

  # discord_id "s" (1 Byte, kein speaker_names-Eintrag → Fallback auf die ID),
  # text 23 Bytes → Zeile 30 Bytes → 10 Token.
  defp utt(n), do: %{id: "u#{n}", discord_id: "s", text: String.duplicate("x", 23)}
  defp utts(range), do: Enum.map(range, &utt/1)
  defp ids(chunk), do: Enum.map(chunk, & &1.id)

  describe "chunk_utterances/3" do
    test "leere Liste → keine Chunks" do
      assert Pipeline.chunk_utterances([], 6000, %{}) == []
    end

    test "alles passt → genau ein Chunk mit allen Utterances in Reihenfolge" do
      list = utts(1..6)
      # 6 × 10 = 60 Token ≤ 100
      assert [chunk] = Pipeline.chunk_utterances(list, 100, %{})
      assert ids(chunk) == ["u1", "u2", "u3", "u4", "u5", "u6"]
    end

    test "splittet an Utterance-Grenzen + Overlap N=2 zwischen Chunks" do
      list = utts(1..10)
      # budget 50 = 5 Utts/Chunk; Overlap 2 → [u1-5],[u4-8],[u7-10]
      chunks = Pipeline.chunk_utterances(list, 50, %{})

      assert Enum.map(chunks, &ids/1) == [
               ["u1", "u2", "u3", "u4", "u5"],
               ["u4", "u5", "u6", "u7", "u8"],
               ["u7", "u8", "u9", "u10"]
             ]
    end

    test "deckt alle Utterances ab + monoton in Reihenfolge" do
      list = utts(1..10)
      chunks = Pipeline.chunk_utterances(list, 50, %{})

      seen = chunks |> Enum.flat_map(&ids/1) |> Enum.uniq()
      assert seen == Enum.map(1..10, &"u#{&1}")

      idx = fn u -> String.to_integer(String.trim_leading(u.id, "u")) end

      # Innerhalb jedes Chunks streng aufsteigend (Reihenfolge intakt)...
      per_chunk = Enum.map(chunks, fn c -> Enum.map(c, idx) end)
      assert Enum.all?(per_chunk, fn xs -> xs == Enum.sort(xs) end)

      # ...und die Chunk-Startindizes laufen vorwärts (kein Rückwärts-Sprung
      # über die Chunk-Grenzen hinweg, Overlap ausgenommen).
      starts = Enum.map(per_chunk, &List.first/1)
      assert starts == Enum.sort(starts)
    end

    test "Einzel-Utterance über Budget bekommt eigenen Chunk (Turn bleibt ganz)" do
      big = %{id: "big", discord_id: "s", text: String.duplicate("y", 300)}
      list = [utt(1), big, utt(2)]
      chunks = Pipeline.chunk_utterances(list, 30, %{})

      # big landet in einem eigenen Chunk, nichts geht verloren.
      all_ids = chunks |> Enum.flat_map(&ids/1) |> Enum.uniq()
      assert "big" in all_ids
      assert "u1" in all_ids
      assert "u2" in all_ids
      assert Enum.any?(chunks, fn c -> ids(c) == ["big"] or "big" in ids(c) end)
    end
  end

  describe "stage2_chunking_needed?/3" do
    test "kurzes Transkript → kein Chunking" do
      refute Pipeline.stage2_chunking_needed?(utts(1..3), %{}, 1000)
    end

    test "langes Transkript über Budget → Chunking" do
      assert Pipeline.stage2_chunking_needed?(utts(1..50), %{}, 5)
    end
  end
end
