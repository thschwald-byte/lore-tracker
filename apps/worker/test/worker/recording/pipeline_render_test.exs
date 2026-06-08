defmodule Worker.Recording.Pipeline.RenderTest do
  @moduledoc """
  Issue #651 (Wahrheitsbild, Phase B): die deterministische Timeline
  (`Worker.Recording.Pipeline.Render.timeline/1`). Pur — kein LLM, kein Mnesia.
  """

  use ExUnit.Case, async: true

  alias Worker.Recording.Pipeline.Render

  defp fact(opts) do
    %{
      "id" => opts[:id] || "f",
      "claim" => opts[:claim] || "claim",
      "character_alias" => opts[:character] || "",
      "in_game_date" => Keyword.get(opts, :date, "Tag 1"),
      "source_refs" => opts[:refs] || [],
      "session_id" => opts[:session],
      "verified?" => Keyword.get(opts, :verified, true)
    }
  end

  test "nur verifizierte + datierte Fakten werden gerendert" do
    facts = [
      fact(claim: "verifiziert+datiert", date: "Tag 1", verified: true),
      fact(claim: "unverifiziert", date: "Tag 2", verified: false),
      fact(claim: "verifiziert aber undatiert", date: nil, verified: true)
    ]

    out = Render.timeline(facts)
    assert Enum.map(out, & &1.summary) == ["verifiziert+datiert"]
  end

  test "chronologisch sortiert (Familie/Zahl wie Chronik)" do
    facts = [
      fact(claim: "C", date: "Tag 9"),
      fact(claim: "A", date: "Tag 1"),
      fact(claim: "B", date: "Tag 5")
    ]

    assert Render.timeline(facts) |> Enum.map(& &1.summary) == ["A", "B", "C"]
  end

  test "stabiler Tie-Break bei gleichem Datum (Eingabe-Reihenfolge bleibt)" do
    facts = [
      fact(claim: "erst", date: "Tag 3", session: "s1"),
      fact(claim: "dann", date: "Tag 3", session: "s2")
    ]

    assert Render.timeline(facts) |> Enum.map(& &1.summary) == ["erst", "dann"]
  end

  test "Eintrag-Shape: claim→summary, character→label, refs + session_id durchgereicht" do
    [e] =
      Render.timeline([
        fact(claim: "Der König beauftragt Holmes.", character: "König", refs: ["u1", "u2"], session: "sX", date: "Tag 1")
      ])

    assert e.summary == "Der König beauftragt Holmes."
    assert e.label == "König"
    assert e.character == "König"
    assert e.source_refs == ["u1", "u2"]
    assert e.session_id == "sX"
    assert e.in_game_date == "Tag 1"
  end

  test "leer / alles unverifiziert / alles undatiert → []" do
    assert Render.timeline([]) == []
    assert Render.timeline([fact(verified: false), fact(verified: false)]) == []
    assert Render.timeline([fact(date: nil), fact(date: "  ")]) == []
  end

  describe "gate_rendered/3 — Render-Gating (injizierter trace_fn)" do
    @fact_claims ["Der König beauftragt Holmes.", "Irene flieht ins Ausland."]

    test "sauberer Render: alle Claims führbar → clean?, kein flagged" do
      md = "Der König beauftragt Holmes mit der Sache. Danach flieht Irene ins Ausland."
      trace = fn _claim, _facts -> true end

      g = Render.gate_rendered(md, @fact_claims, trace)
      assert g.clean? == true
      assert g.flagged == []
      assert length(g.traceable) == 2
    end

    test "fängt einen hinzugedichteten / re-invertierten Claim (das Baseline-Failure-Muster)" do
      # 'Holmes triumphiert' steht auf KEINEM Fakt — genau die command-r-Re-Inversion.
      md = "Der König beauftragt Holmes mit der Sache. Holmes triumphiert am Ende."
      trace = fn claim, _facts -> String.contains?(claim, "beauftragt") end

      g = Render.gate_rendered(md, @fact_claims, trace)
      assert g.clean? == false
      assert g.flagged == ["Holmes triumphiert am Ende."]
      assert g.traceable == ["Der König beauftragt Holmes mit der Sache."]
    end
  end

  describe "Prompt-Builder (context-faithful)" do
    test "summary_prompt nennt die Fakten + verbietet neue Claims" do
      p = Render.summary_prompt([fact(claim: "Der König beauftragt Holmes.", character: "König")])
      assert p =~ "Der König beauftragt Holmes."
      assert p =~ "[König]"
      assert p =~ "AUSSCHLIESSLICH"
    end

    test "epos_prompt: Handlung treu, keine neuen Plot-Fakten" do
      p = Render.epos_prompt([fact(claim: "Irene flieht.", character: "Irene")])
      assert p =~ "Irene flieht."
      assert p =~ "Erfinde KEINE neuen Plot-Fakten"
    end
  end
end
