defmodule Worker.Recording.PipelineSourceRefsTest do
  @moduledoc """
  Issue #114: parse_summary_json/2 + parse_epos_json/2 — robustness +
  Whitelist-Filter auf valid utterance_ids. Tests laufen direkt gegen die
  public-but-doc-hidden Parser-Funktionen (analog parse_chronik_json/1).
  """

  use ExUnit.Case, async: true

  alias Worker.Recording.Pipeline

  describe "parse_summary_json/2" do
    test "happy-path: content_md + source_refs aus JSON-Block extrahiert" do
      utterances = [%{id: "utt-1"}, %{id: "utt-2"}, %{id: "utt-3"}]

      raw = ~s({"content_md": "Romeo trifft Julia.", "source_refs": ["utt-1", "utt-3"]})

      assert {"Romeo trifft Julia.", ["utt-1", "utt-3"]} =
               Pipeline.parse_summary_json(raw, utterances)
    end

    test "source_refs werden auf valid utterance_ids gefiltert" do
      utterances = [%{id: "utt-1"}, %{id: "utt-2"}]
      raw = ~s({"content_md": "X", "source_refs": ["utt-1", "utt-99", "utt-fake"]})

      assert {"X", refs} = Pipeline.parse_summary_json(raw, utterances)
      assert refs == ["utt-1"]
    end

    test "duplicate refs werden dedupliziert" do
      utterances = [%{id: "u1"}]
      raw = ~s({"content_md": "X", "source_refs": ["u1", "u1", "u1"]})

      assert {"X", ["u1"]} = Pipeline.parse_summary_json(raw, utterances)
    end

    test "Markdown-Code-Fences werden gestripped" do
      utterances = [%{id: "utt-1"}]
      raw = "```json\n{\"content_md\": \"X\", \"source_refs\": [\"utt-1\"]}\n```"

      assert {"X", ["utt-1"]} = Pipeline.parse_summary_json(raw, utterances)
    end

    test "thinking-blocks werden gestripped (qwen3-Pattern)" do
      utterances = [%{id: "utt-1"}]

      raw = "<think>überlege...</think>{\"content_md\": \"Test\", \"source_refs\": [\"utt-1\"]}"

      assert {"Test", ["utt-1"]} = Pipeline.parse_summary_json(raw, utterances)
    end

    test "Free-form Fallback: kein JSON → content_md = trim(raw), refs = []" do
      raw = "Romeo trifft Julia und stirbt."

      assert {"Romeo trifft Julia und stirbt.", []} = Pipeline.parse_summary_json(raw, [])
    end

    test "Junk source_refs werden ignoriert" do
      utterances = [%{id: "u1"}]
      raw = ~s({"content_md": "X", "source_refs": [123, null, "u1"]})

      assert {"X", ["u1"]} = Pipeline.parse_summary_json(raw, utterances)
    end

    test "nil-Input returnt empty tuple" do
      assert {"", []} = Pipeline.parse_summary_json(nil, [])
    end

    # Issue #307: Kurz-IDs `[u1]…[uN]` im Prompt → Round-Map zurück auf UUIDs.
    test "Kurz-IDs werden über den Index auf echte UUIDs gemappt" do
      utterances = [%{id: "uuid-a"}, %{id: "uuid-b"}, %{id: "uuid-c"}]
      raw = ~s({"content_md": "X", "source_refs": ["u1", "u3"]})

      assert {"X", ["uuid-a", "uuid-c"]} = Pipeline.parse_summary_json(raw, utterances)
    end

    test "halluzinierte Kurz-IDs (u999) fallen raus" do
      utterances = [%{id: "uuid-a"}, %{id: "uuid-b"}]
      raw = ~s({"content_md": "X", "source_refs": ["u1", "u999"]})

      assert {"X", ["uuid-a"]} = Pipeline.parse_summary_json(raw, utterances)
    end

    test "geklammerte Kurz-IDs [u2] werden normalisiert" do
      utterances = [%{id: "uuid-a"}, %{id: "uuid-b"}]
      raw = ~s({"content_md": "X", "source_refs": ["[u2]"]})

      assert {"X", ["uuid-b"]} = Pipeline.parse_summary_json(raw, utterances)
    end

    test "Prompt-Platzhalter <utterance-id-3> leakt nicht durch (#114-Leak)" do
      utterances = [%{id: "uuid-a"}, %{id: "uuid-b"}, %{id: "uuid-c"}]
      raw = ~s({"content_md": "X", "source_refs": ["u1", "<utterance-id-3>"]})

      assert {"X", ["uuid-a"]} = Pipeline.parse_summary_json(raw, utterances)
    end

    test "echte UUID-Refs gehen weiterhin durch (dual, Backward-Compat)" do
      utterances = [%{id: "uuid-a"}, %{id: "uuid-b"}]
      raw = ~s({"content_md": "X", "source_refs": ["uuid-b"]})

      assert {"X", ["uuid-b"]} = Pipeline.parse_summary_json(raw, utterances)
    end
  end

  describe "parse_epos_json/2" do
    test "happy-path: content_md + source_refs übernommen" do
      raw = ~s({"content_md": "# Epos\\n...", "source_refs": ["utt-1", "utt-2"]})

      assert {"# Epos\n...", ["utt-1", "utt-2"]} = Pipeline.parse_epos_json(raw, [])
    end

    test "fehlende refs im JSON → fallback aus stage3 (Summary-Refs)" do
      raw = ~s({"content_md": "# Epos"})

      assert {"# Epos", ["from-stage3-fallback"]} =
               Pipeline.parse_epos_json(raw, ["from-stage3-fallback"])
    end

    test "JSON-Parse-Failure → content_md = trim(raw), refs = fallback" do
      raw = "Freitext ohne JSON"

      assert {"Freitext ohne JSON", ["fallback-ref"]} =
               Pipeline.parse_epos_json(raw, ["fallback-ref"])
    end

    test "duplicate refs werden dedupliziert" do
      raw = ~s({"content_md": "X", "source_refs": ["a", "b", "a", "c", "b"]})

      assert {"X", refs} = Pipeline.parse_epos_json(raw, [])
      assert Enum.sort(refs) == ["a", "b", "c"]
    end
  end

  describe "parse_chronik_json/1 mit source_refs pro Entry (Issue #114)" do
    test "Entries behalten den source_refs-Key bis zum stage4_publish-Aufruf" do
      raw = """
      {
        "entries": [
          {
            "in_game_date": "Tag 1",
            "label": "Begegnung",
            "summary": "Romeo & Julia.",
            "source_refs": ["utt-1", "utt-2"]
          }
        ]
      }
      """

      assert [entry] = Pipeline.parse_chronik_json(raw)
      assert entry["source_refs"] == ["utt-1", "utt-2"]
    end
  end
end
