defmodule Worker.LLM.AnthropicTemperatureTest do
  @moduledoc """
  Hotfix: manche Anthropic-Modelle lehnen `temperature` mit 400
  "temperature is deprecated for this model" ab. `temperature_deprecated?/1`
  erkennt das aus dem 400-Body, damit `complete/2` einmal ohne temperature
  retried statt die Stage hart scheitern zu lassen.
  """
  use ExUnit.Case, async: true

  alias Worker.LLM.Anthropic

  test "erkennt den temperature-deprecated 400-Body" do
    body = %{
      "type" => "error",
      "error" => %{
        "type" => "invalid_request_error",
        "message" => "`temperature` is deprecated for this model."
      }
    }

    assert Anthropic.temperature_deprecated?(body)
  end

  test "case-insensitive + Teilstring-robust" do
    assert Anthropic.temperature_deprecated?(%{
             "error" => %{"message" => "Temperature is DEPRECATED here"}
           })
  end

  test "andere 400-Fehler sind NICHT temperature-deprecated" do
    refute Anthropic.temperature_deprecated?(%{
             "error" => %{"message" => "max_tokens is too large"}
           })

    refute Anthropic.temperature_deprecated?(%{
             "error" => %{"message" => "temperature must be <= 1"}
           })
  end

  test "robust gegen fremde Shapes" do
    refute Anthropic.temperature_deprecated?(%{})
    refute Anthropic.temperature_deprecated?("kein body")
    refute Anthropic.temperature_deprecated?(%{"error" => "string statt map"})
  end
end
