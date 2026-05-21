defmodule Worker.Recording.PipelineChronikParserTest do
  @moduledoc """
  Issue #75: `parse_chronik_json/1` must handle the messy reality of LLM
  output — Thinking-Modelle (qwen3) prefix their answer with a
  `<think>...</think>` block, smaller modelle wrap their answer in Markdown
  code-fences, some only emit a top-level JSON array. All of these are valid
  Stage-4 input.
  """

  use ExUnit.Case, async: true

  alias Worker.Recording.Pipeline

  describe "parse_chronik_json/1" do
    test "plain JSON with entries key" do
      raw = ~s({"entries":[{"in_game_date":"Tag 1","label":"X","summary":"Y"}]})
      assert [%{"label" => "X"}] = Pipeline.parse_chronik_json(raw)
    end

    test "top-level JSON array" do
      raw = ~s([{"in_game_date":"Tag 1","label":"X","summary":"Y"}])
      assert [%{"label" => "X"}] = Pipeline.parse_chronik_json(raw)
    end

    test "alternate top-level keys (chronik, timeline)" do
      assert [%{"label" => "A"}] =
               Pipeline.parse_chronik_json(~s({"chronik":[{"label":"A"}]}))

      assert [%{"label" => "B"}] =
               Pipeline.parse_chronik_json(~s({"timeline":[{"label":"B"}]}))
    end

    test "strips qwen3 <think>...</think> block before JSON" do
      raw = """
      <think>
      Der User will JSON. Ich extrahiere drei Einträge aus dem Text.
      </think>
      {"entries":[{"in_game_date":"Tag 1","label":"X","summary":"Y"}]}
      """

      assert [%{"label" => "X"}] = Pipeline.parse_chronik_json(raw)
    end

    test "strips markdown code-fences (json-tagged)" do
      raw = """
      ```json
      {"entries":[{"label":"Z"}]}
      ```
      """

      assert [%{"label" => "Z"}] = Pipeline.parse_chronik_json(raw)
    end

    test "strips markdown code-fences (untagged)" do
      raw = """
      ```
      {"entries":[{"label":"W"}]}
      ```
      """

      assert [%{"label" => "W"}] = Pipeline.parse_chronik_json(raw)
    end

    test "extracts JSON object from surrounding prose" do
      raw = ~s(Hier ist die Liste: {"entries":[{"label":"P"}]} — fertig.)
      assert [%{"label" => "P"}] = Pipeline.parse_chronik_json(raw)
    end

    test "empty string returns []" do
      assert [] = Pipeline.parse_chronik_json("")
    end

    test "nil returns []" do
      assert [] = Pipeline.parse_chronik_json(nil)
    end

    test "garbage non-JSON returns []" do
      assert [] = Pipeline.parse_chronik_json("ich liefere kein JSON. Sorry.")
    end

    test "qwen3 thinking-block only, no actual JSON returns []" do
      raw = "<think>I should output JSON but I'll forget.</think>"
      assert [] = Pipeline.parse_chronik_json(raw)
    end
  end
end
