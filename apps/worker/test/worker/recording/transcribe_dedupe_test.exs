defmodule Worker.Recording.TranscribeDedupeTest do
  @moduledoc """
  `dedupe_consecutive/1` ist private — wir verifizieren das beobachtbare
  Verhalten via `emit_utterances` über den Intents-Publish-Pfad. Dafür
  reicht ein Lauf von Public-Helpers wäre invasiver; stattdessen Black-
  Box-Test der Normalisierungsregel über Reflection.
  """

  use ExUnit.Case, async: true

  test "consecutive identical segments collapse to one" do
    segs = [
      %{"text" => "Vielen Dank.", "offset_ms" => 0},
      %{"text" => "Vielen Dank.", "offset_ms" => 1000},
      %{"text" => "Wir spielen.", "offset_ms" => 2000},
      %{"text" => "vielen   dank!", "offset_ms" => 3000}
    ]

    out = call_private(:dedupe_consecutive, [segs])
    texts = Enum.map(out, & &1["text"])

    # First two collapse to one, third stays, fourth is again a duplicate
    # of "Vielen Dank." once normalized.
    assert texts == ["Vielen Dank.", "Wir spielen.", "vielen   dank!"]
  end

  test "empty / whitespace-only segments are dropped" do
    segs = [
      %{"text" => "", "offset_ms" => 0},
      %{"text" => "   ", "offset_ms" => 100},
      %{"text" => "Hallo", "offset_ms" => 200}
    ]

    out = call_private(:dedupe_consecutive, [segs])
    assert Enum.map(out, & &1["text"]) == ["Hallo"]
  end

  test "non-consecutive duplicates are kept" do
    segs = [
      %{"text" => "Ja.", "offset_ms" => 0},
      %{"text" => "Nein.", "offset_ms" => 1000},
      %{"text" => "Ja.", "offset_ms" => 2000}
    ]

    out = call_private(:dedupe_consecutive, [segs])
    assert Enum.map(out, & &1["text"]) == ["Ja.", "Nein.", "Ja."]
  end

  # Reflection helper — defp aufrufen ohne den Helper zu exporten.
  defp call_private(fun, args) do
    apply(Worker.Recording.Transcribe, fun, args)
  rescue
    UndefinedFunctionError -> flunk("expected #{fun}/#{length(args)} to be defined (even as defp via apply)")
  end
end
