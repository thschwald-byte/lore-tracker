defmodule Worker.LLM.FormatTranslationTest do
  @moduledoc """
  Issue #518 — Tests dass `opts[:format]` aus der Pipeline pro Cloud-
  Backend korrekt in das Provider-spezifische Pendant übersetzt wird.

  Die `maybe_*`-Helper sind pure und für Tests via `@doc false def`
  exportiert. Kein Req-Mock nötig — wir prüfen direkt die Body-Map die
  ans Provider-API geschickt würde.
  """

  use ExUnit.Case, async: true

  alias Worker.LLM.{Anthropic, OpenAI, Google}

  @stage2_schema %{
    "type" => "object",
    "properties" => %{
      "content_md" => %{"type" => "string"},
      "source_refs" => %{"type" => "array", "items" => %{"type" => "string"}}
    },
    "required" => ["content_md"]
  }

  @stage4_schema %{
    "type" => "object",
    "properties" => %{
      "entries" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "properties" => %{
            "in_game_date" => %{"type" => "string"},
            "label" => %{"type" => "string"},
            "summary" => %{"type" => "string"}
          },
          "required" => ["in_game_date", "label", "summary"]
        }
      }
    },
    "required" => ["entries"]
  }

  describe "Anthropic.maybe_force_json/2 — System-Prompt-Pattern" do
    test "nil → unverändert (kein System-Prompt)" do
      body = %{model: "claude", messages: []}
      assert ^body = Anthropic.maybe_force_json(body, nil)
    end

    test "\"\" → unverändert" do
      body = %{model: "claude", messages: []}
      assert ^body = Anthropic.maybe_force_json(body, "")
    end

    test "\"json\" → System-Prompt mit JSON-only-Instruktion" do
      result = Anthropic.maybe_force_json(%{model: "claude"}, "json")
      assert is_binary(result.system)
      assert String.contains?(result.system, "JSON")
      assert String.contains?(result.system, "Kein Markdown")
    end

    test "Schema-Map → System-Prompt enthält das Schema als pretty JSON" do
      result = Anthropic.maybe_force_json(%{model: "claude"}, @stage2_schema)
      assert is_binary(result.system)
      assert String.contains?(result.system, "JSON-Schema")
      assert String.contains?(result.system, "content_md")
      assert String.contains?(result.system, "source_refs")
    end

    test "unbekannter Typ (Integer) → unverändert (kein Crash)" do
      body = %{model: "claude"}
      assert ^body = Anthropic.maybe_force_json(body, 42)
    end
  end

  describe "OpenAI.maybe_put_response_format/3 — response_format-Pattern" do
    test "nil → unverändert" do
      body = %{model: "gpt-4o", messages: []}
      assert ^body = OpenAI.maybe_put_response_format(body, nil, "gpt-4o")
    end

    test "\"json\" → response_format: json_object" do
      result = OpenAI.maybe_put_response_format(%{model: "gpt-4o"}, "json", "gpt-4o")
      assert result.response_format == %{type: "json_object"}
    end

    test "Schema + gpt-4o → strict json_schema" do
      result =
        OpenAI.maybe_put_response_format(%{model: "gpt-4o"}, @stage2_schema, "gpt-4o")

      assert %{type: "json_schema", json_schema: js} = result.response_format
      assert js.name == "stage_output"
      assert js.strict == true
      assert js.schema == @stage2_schema
    end

    test "Schema + gpt-4o-mini → strict json_schema (gpt-4o-Familie)" do
      result =
        OpenAI.maybe_put_response_format(%{}, @stage4_schema, "gpt-4o-mini")

      assert %{type: "json_schema"} = result.response_format
    end

    test "Schema + o1-preview → fällt auf json_object zurück (kein strict)" do
      result =
        OpenAI.maybe_put_response_format(%{}, @stage2_schema, "o1-preview")

      assert result.response_format == %{type: "json_object"}
    end

    test "Schema + o1-mini → json_object (kein strict)" do
      result = OpenAI.maybe_put_response_format(%{}, @stage2_schema, "o1-mini")
      assert result.response_format == %{type: "json_object"}
    end

    test "Schema + gpt-4-turbo → json_object (älteres Modell, kein strict)" do
      result = OpenAI.maybe_put_response_format(%{}, @stage2_schema, "gpt-4-turbo")
      assert result.response_format == %{type: "json_object"}
    end
  end

  describe "OpenAI.supports_json_schema?/1 — Modell-Capability" do
    test "gpt-4o → true" do
      assert OpenAI.supports_json_schema?("gpt-4o") == true
    end

    test "gpt-4o-mini → true" do
      assert OpenAI.supports_json_schema?("gpt-4o-mini") == true
    end

    test "o1-preview → false (nur json_object)" do
      assert OpenAI.supports_json_schema?("o1-preview") == false
    end

    test "gpt-4-turbo → false (älter, kein strict)" do
      assert OpenAI.supports_json_schema?("gpt-4-turbo") == false
    end

    test "nil → false" do
      assert OpenAI.supports_json_schema?(nil) == false
    end
  end

  describe "Google.maybe_put_response_format/2 — responseMimeType-Pattern" do
    test "nil → unverändert" do
      cfg = %{maxOutputTokens: 1000}
      assert ^cfg = Google.maybe_put_response_format(cfg, nil)
    end

    test "\"json\" → responseMimeType nur (kein Schema)" do
      result = Google.maybe_put_response_format(%{}, "json")
      assert result == %{responseMimeType: "application/json"}
    end

    test "Schema-Map → responseMimeType + responseSchema" do
      result = Google.maybe_put_response_format(%{}, @stage2_schema)
      assert result.responseMimeType == "application/json"
      assert is_map(result.responseSchema)
    end
  end

  describe "Google.to_gemini_schema/1 — JSON-Schema → Gemini-Type-Strings" do
    test "primitives Type lowercase → UPPERCASE" do
      assert %{type: "STRING"} = Google.to_gemini_schema(%{"type" => "string"})
      assert %{type: "INTEGER"} = Google.to_gemini_schema(%{"type" => "integer"})
      assert %{type: "BOOLEAN"} = Google.to_gemini_schema(%{"type" => "boolean"})
      assert %{type: "ARRAY"} = Google.to_gemini_schema(%{"type" => "array"})
      assert %{type: "OBJECT"} = Google.to_gemini_schema(%{"type" => "object"})
    end

    test "Stage-2-Schema rekursiv konvertiert" do
      result = Google.to_gemini_schema(@stage2_schema)

      assert result.type == "OBJECT"
      assert result.required == ["content_md"]
      assert result.properties["content_md"].type == "STRING"
      assert result.properties["source_refs"].type == "ARRAY"
      assert result.properties["source_refs"].items.type == "STRING"
    end

    test "Stage-4-Schema mit verschachteltem array of object" do
      result = Google.to_gemini_schema(@stage4_schema)

      assert result.type == "OBJECT"
      assert result.properties["entries"].type == "ARRAY"

      item = result.properties["entries"].items
      assert item.type == "OBJECT"
      assert item.properties["in_game_date"].type == "STRING"
      assert item.required == ["in_game_date", "label", "summary"]
    end

    test "description-Feld wird durchgereicht" do
      schema = %{"type" => "string", "description" => "Markdown content"}
      result = Google.to_gemini_schema(schema)
      assert result.description == "Markdown content"
    end

    test "unbekannte JSON-Schema-Keys werden still ignoriert (additionalProperties, format)" do
      schema = %{
        "type" => "string",
        "additionalProperties" => false,
        "format" => "date-time",
        "pattern" => "^\\d{4}"
      }

      result = Google.to_gemini_schema(schema)
      assert result == %{type: "STRING"}
    end
  end
end
