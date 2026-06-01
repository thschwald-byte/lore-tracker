defmodule HubWeb.TestPhrasesTest do
  @moduledoc """
  Issue #400: der Compile-Time-Loader der Mic-Setup-Test-Phrasen.
  """

  use ExUnit.Case, async: true

  alias HubWeb.TestPhrases

  test "all/0 liefert eine nicht-leere Liste von Strings" do
    phrases = TestPhrases.all()
    assert is_list(phrases)
    assert length(phrases) > 0
    assert Enum.all?(phrases, &(is_binary(&1) and &1 != ""))
  end

  test "count/0 stimmt mit all/0 überein und ist > 0" do
    assert TestPhrases.count() == length(TestPhrases.all())
    assert TestPhrases.count() > 0
  end

  test "random/0 liefert eine Phrase aus der eingebetteten Liste" do
    phrase = TestPhrases.random()
    assert is_binary(phrase) and phrase != ""
    assert phrase in TestPhrases.all()
  end

  test "die eingebetteten Phrasen sind getrimmt (kein führender/folgender Whitespace)" do
    assert Enum.all?(TestPhrases.all(), &(String.trim(&1) == &1))
  end
end
