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

    test "#874: gpt-oss ist in der Heuristik — gesetztes Think-Level darf bei totem Lookup nicht wegfallen" do
      # Ohne diesen Fall fiele ein konfiguriertes Level bei kurzem
      # Ollama-Ausfall auf :omit zurück und der Leer-Extraktion-Blocker
      # kehrte sporadisch wieder.
      assert Local.think_flag_from({:error, :ollama_offline}, "gpt-oss:20b")
      assert Local.think_flag_from({:error, :no_capabilities_field}, "gpt-oss:120b")
    end
  end

  # Issue #874: Modus × Thinking-Capability → Payload-Wirkung. Pur — der
  # Settings-/Override-Teil (think_mode_for_stage/resolve_think) läuft in
  # local_think_setting_test.exs (async: false).
  describe "think_payload/2" do
    test "H: :auto + Capability = think:false (das unveränderte #700-Verhalten)" do
      assert Local.think_payload(:auto, true) == false
    end

    test "H: Level + Capability = Level als String (gpt-oss-Pfad)" do
      assert Local.think_payload(:medium, true) == "medium"
    end

    test "R: alle drei Level mappen auf ihren String" do
      assert Local.think_payload(:low, true) == "low"
      assert Local.think_payload(:medium, true) == "medium"
      assert Local.think_payload(:high, true) == "high"
    end

    test "N: ohne Capability wird IMMER weggelassen — auch ein gesetztes Level erzwingt nichts" do
      # Ollama lehnt `think` an Nicht-Thinking-Modellen ab; das Level darf
      # den Capability-Check nicht überstimmen.
      assert Local.think_payload(:auto, false) == :omit
      assert Local.think_payload(:high, false) == :omit
    end
  end
end
