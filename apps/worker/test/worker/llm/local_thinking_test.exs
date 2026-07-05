defmodule Worker.LLM.LocalThinkingTest do
  use ExUnit.Case, async: true

  alias Worker.LLM.Local

  # Issue #700: modell-agnostische Thinking-Detection. Die Entscheidung
  # (think:false ja/nein) ist pur aus dem Capabilities-Lookup-Resultat
  # ableitbar — der HTTP-Fetch selbst ist dünne :httpc-Plumbing.
  describe "think_flag_from/2" do
    test "capability 'thinking' setzt think:false — unabhängig vom Modellnamen" do
      assert Local.think_flag_from(
               {:ok, ["completion", "vision", "tools", "thinking"]},
               "gemma4:26b"
             )

      assert Local.think_flag_from({:ok, ["thinking"]}, "irgendein-neues-modell:1b")
    end

    test "ohne 'thinking'-Capability kein think:false — Capabilities schlagen Namens-Heuristik" do
      refute Local.think_flag_from({:ok, ["completion", "tools"]}, "qwen2.5:7b")

      # Ein qwen3-Derivat OHNE thinking-Capability (z.B. Instruct-Distill)
      # bekommt kein think:false, obwohl der Name nach Reasoning klingt.
      refute Local.think_flag_from({:ok, ["completion"]}, "qwen3:30b-a3b-instruct")
    end

    test "Lookup-Fehler fällt auf die #289-Namens-Heuristik zurück" do
      assert Local.think_flag_from({:error, :ollama_offline}, "qwen3:30b-a3b")
      assert Local.think_flag_from({:error, :no_capabilities_field}, "deepseek-r1:14b")

      # Restlücke bewusst dokumentiert: unbekanntes Thinking-Modell + toter
      # Lookup → kein think:false (heilt beim nächsten Call, Fehler wird
      # nicht gecacht).
      refute Local.think_flag_from({:error, :ollama_offline}, "gemma4:26b")
      refute Local.think_flag_from({:error, {:http, 500, "boom"}}, "mistral-nemo:12b")
    end
  end
end
