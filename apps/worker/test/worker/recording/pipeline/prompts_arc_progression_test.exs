defmodule Worker.Recording.Pipeline.PromptsArcProgressionTest do
  @moduledoc """
  Issue #838: `Prompts.build_arc_progression_prompt/4` — Fall A (kein
  vorheriger Eintrag, inkl. Backfill) / Fall B (Fortsetzung, `[unbelegt]`-
  Markierung), kein Leitfrage-Input (Content-Kontaminations-Risiko, #838-Plan
  Design F). Pure, kein LLM.
  """

  use ExUnit.Case, async: true

  alias Worker.Recording.Pipeline.Prompts

  defp fact(claim), do: %{"id" => "f", "claim" => claim}

  describe "Fall A (kein vorheriger Eintrag)" do
    test "enthält den Bogen-Titel + nummerierte Fakten, keine Fortsetzungs-Sprache" do
      prompt =
        Prompts.build_arc_progression_prompt("Der Auftrag", nil, [fact("Erstes Ereignis")])

      assert prompt =~ "Bogen: Der Auftrag"
      assert prompt =~ "1. Erstes Ereignis"
      assert prompt =~ "BEGINN"
      refute prompt =~ "Bisheriger Stand"
    end

    test "funktioniert identisch, egal ob new_facts Session-Delta oder volle Historie sind (Backfill) — der Builder kennt den Unterschied nicht" do
      delta = [fact("Nur diese Sitzung")]
      full_history = [fact("Sitzung 1"), fact("Sitzung 2"), fact("Sitzung 3")]

      p1 = Prompts.build_arc_progression_prompt("X", nil, delta)
      p2 = Prompts.build_arc_progression_prompt("X", nil, full_history)

      assert p1 =~ "1. Nur diese Sitzung"
      assert p2 =~ "1. Sitzung 1"
      assert p2 =~ "3. Sitzung 3"
    end
  end

  describe "Fall B (Fortsetzung)" do
    test "enthält den vorherigen Eintrag + neue Fakten + Fortsetzungs-Anweisung" do
      prior = %{content_md: "Der Auftrag begann mit einem Brief.", flagged_claims: []}
      prompt = Prompts.build_arc_progression_prompt("Der Auftrag", prior, [fact("Der Brief wurde geöffnet.")])

      assert prompt =~ "Bisheriger Stand"
      assert prompt =~ "Der Auftrag begann mit einem Brief."
      assert prompt =~ "1. Der Brief wurde geöffnet."
      assert prompt =~ "NUR den neuen Absatz"
    end

    test "flagged_claims werden im vorherigen Eintrag mit [unbelegt] markiert" do
      prior = %{
        content_md: "Der Held rettete das Dorf. Ein Verräter half heimlich mit.",
        flagged_claims: ["Ein Verräter half heimlich mit."]
      }

      prompt = Prompts.build_arc_progression_prompt("X", prior, [fact("neu")])

      assert prompt =~ "[unbelegt] Ein Verräter half heimlich mit."
      assert prompt =~ "Der Held rettete das Dorf."
    end

    test "keine flagged_claims -> der bisherige Stand bleibt unmarkiert" do
      prior = %{content_md: "Alles sauber belegt.", flagged_claims: []}
      prompt = Prompts.build_arc_progression_prompt("X", prior, [fact("neu")])

      # Die statische Anweisung erwähnt "[unbelegt]" als Begriff (immer
      # vorhanden) — geprüft wird hier, dass der EINGEBETTETE bisherige
      # Stand selbst nicht markiert wurde.
      assert prompt =~ "\"\"\"\nAlles sauber belegt.\n\"\"\""
    end
  end

  test "Negativtest: die Leitfrage ist kein Parameter -- kann also nie im Prompt auftauchen" do
    prior = %{content_md: "Stand.", flagged_claims: []}
    prompt_a = Prompts.build_arc_progression_prompt("Der Auftrag", nil, [fact("x")])
    prompt_b = Prompts.build_arc_progression_prompt("Der Auftrag", prior, [fact("x")])

    refute prompt_a =~ "Leitfrage"
    refute prompt_b =~ "Leitfrage"
  end
end
