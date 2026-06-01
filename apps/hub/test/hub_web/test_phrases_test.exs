defmodule HubWeb.TestPhrasesTest do
  @moduledoc """
  Issue #400: der Compile-Time-Loader der Mic-Setup-Test-Phrasen.
  """

  use ExUnit.Case, async: true

  alias HubWeb.TestPhrases

  test "all/0 liefert eine nicht-leere Liste von %{text, source}-Maps" do
    phrases = TestPhrases.all()
    assert is_list(phrases)
    assert length(phrases) > 0

    assert Enum.all?(phrases, fn p ->
             is_map(p) and is_binary(p.text) and p.text != "" and is_binary(p.source)
           end)
  end

  test "count/0 stimmt mit all/0 überein und ist > 0" do
    assert TestPhrases.count() == length(TestPhrases.all())
    assert TestPhrases.count() > 0
  end

  test "random/0 liefert eine Phrase-Map aus der eingebetteten Liste" do
    phrase = TestPhrases.random()
    assert is_map(phrase) and is_binary(phrase.text) and phrase.text != ""
    assert phrase in TestPhrases.all()
  end

  test "die eingebetteten Zitate sind getrimmt (kein führender/folgender Whitespace)" do
    assert Enum.all?(TestPhrases.all(), &(String.trim(&1.text) == &1.text))
  end

  test "jede Phrase trägt eine Quelle (Film/Jahr) — Issue #410" do
    assert Enum.all?(TestPhrases.all(), &(&1.source != ""))
  end
end
