defmodule Worker.LLM.BackendParsersTest do
  @moduledoc """
  Issue #615 / #608: Response-Parse-Tests für die backend-spezifischen Parser
  der drei Cloud-Backends. Vor #615 hatten OpenAI + Google gar keinen Parser-
  Test. Geprüft: `parse_success/1` (200-Body → {:ok, text, usage}) je Provider-
  Shape + die `extract_model_names/1`-Models-List-Extraktion + die
  Bad-Shape-Fallbacks.
  """
  use ExUnit.Case, async: true

  alias Worker.LLM.{Anthropic, Google, OpenAI}

  describe "Anthropic.parse_success/1" do
    test "content-Array + usage → {:ok, text, usage}" do
      body = %{
        "content" => [
          %{"type" => "text", "text" => "Hallo "},
          %{"type" => "text", "text" => "Welt"}
        ],
        "usage" => %{"input_tokens" => 12, "output_tokens" => 7}
      }

      assert {:ok, "Hallo Welt", %{input_tokens: 12, output_tokens: 7}} =
               Anthropic.parse_success({:ok, body})
    end

    test "fehlende usage → 0/0" do
      body = %{"content" => [%{"type" => "text", "text" => "x"}]}

      assert {:ok, "x", %{input_tokens: 0, output_tokens: 0}} =
               Anthropic.parse_success({:ok, body})
    end

    test "fremde Shape → :bad_response_shape" do
      assert {:error, {:bad_response_shape, %{"foo" => 1}}} =
               Anthropic.parse_success({:ok, %{"foo" => 1}})
    end

    test "durchgereichter Fehler bleibt" do
      assert {:error, :upstream_auth} = Anthropic.parse_success({:error, :upstream_auth})
    end
  end

  describe "OpenAI.parse_success/1" do
    test "choices[].message.content + usage → {:ok, text, usage}" do
      body = %{
        "choices" => [%{"message" => %{"content" => "Antwort"}}],
        "usage" => %{"prompt_tokens" => 20, "completion_tokens" => 9}
      }

      assert {:ok, "Antwort", %{input_tokens: 20, output_tokens: 9}} =
               OpenAI.parse_success({:ok, body})
    end

    test "fremde Shape → :bad_response_shape" do
      assert {:error, {:bad_response_shape, _}} = OpenAI.parse_success({:ok, %{"x" => 1}})
    end
  end

  describe "Google.parse_success/1" do
    test "candidates[].content.parts[].text + usageMetadata → {:ok, text, usage}" do
      body = %{
        "candidates" => [
          %{"content" => %{"parts" => [%{"text" => "Teil1 "}, %{"text" => "Teil2"}]}}
        ],
        "usageMetadata" => %{"promptTokenCount" => 30, "candidatesTokenCount" => 11}
      }

      assert {:ok, "Teil1 Teil2", %{input_tokens: 30, output_tokens: 11}} =
               Google.parse_success({:ok, body})
    end

    test "fremde Shape → :bad_response_shape" do
      assert {:error, {:bad_response_shape, _}} = Google.parse_success({:ok, %{"x" => 1}})
    end
  end

  describe "extract_model_names/1 (Models-List-Parser)" do
    test "Anthropic: data[].id" do
      assert {:ok, ids} =
               Anthropic.extract_model_names(%{
                 "data" => [%{"id" => "claude-x"}, %{"id" => "claude-y"}, %{"foo" => 1}]
               })

      assert "claude-x" in ids and "claude-y" in ids
    end

    test "OpenAI: data[].id mit Chat-Filter (instruct/embed raus)" do
      assert {:ok, ids} =
               OpenAI.extract_model_names(%{
                 "data" => [
                   %{"id" => "gpt-4o"},
                   %{"id" => "text-embedding-3-small"},
                   %{"id" => "gpt-3.5-turbo-instruct"}
                 ]
               })

      assert "gpt-4o" in ids
      refute "text-embedding-3-small" in ids
      refute "gpt-3.5-turbo-instruct" in ids
    end

    test "Google: models[] mit generateContent-Filter + models/-Präfix-Strip" do
      assert {:ok, ids} =
               Google.extract_model_names(%{
                 "models" => [
                   %{
                     "name" => "models/gemini-2.5-pro",
                     "supportedGenerationMethods" => ["generateContent"]
                   },
                   %{
                     "name" => "models/embedding-001",
                     "supportedGenerationMethods" => ["embedContent"]
                   }
                 ]
               })

      assert "gemini-2.5-pro" in ids
      refute "embedding-001" in ids
    end

    test "fremde Shape → :no_match (alle drei)" do
      assert :no_match = Anthropic.extract_model_names(%{"x" => 1})
      assert :no_match = OpenAI.extract_model_names(%{"x" => 1})
      assert :no_match = Google.extract_model_names(%{"x" => 1})
    end
  end
end
