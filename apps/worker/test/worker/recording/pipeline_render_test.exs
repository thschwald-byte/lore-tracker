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

  # Seit #724 (Slice E) sortiert Render.timeline NICHT mehr selbst — die
  # chronologische Ordnung ist Sache des Read-Path (`Repo.list_chronik_entries`,
  # Familie-0-Tageszähler bzw. Familie-1-Fallback; getestet in
  # repo_timeline_persistence_test + repo_chronik_sort_test). timeline reicht die
  # Fakten in Eingabe-Reihenfolge durch.
  test "Eingabe-Reihenfolge bleibt erhalten (Sort ist Read-Path-Sache)" do
    facts = [
      fact(claim: "C", date: "Tag 9"),
      fact(claim: "A", date: "Tag 1"),
      fact(claim: "B", date: "Tag 5")
    ]

    assert Render.timeline(facts) |> Enum.map(& &1.summary) == ["C", "A", "B"]
  end

  test "aufgelöster Fakt (in_game_day/display/precision aus Graph.resolve) wird durchgereicht" do
    resolved =
      fact(claim: "datiert", date: "1888")
      |> Map.merge(%{"in_game_day" => 1234, "display" => "1888", "precision" => "year"})

    [e] = Render.timeline([resolved])
    assert e.in_game_day == 1234
    assert e.in_game_date == "1888"
    assert e.precision == "year"
  end

  test "Eintrag-Shape: claim→summary, character→label, refs + session_id durchgereicht" do
    [e] =
      Render.timeline([
        fact(
          claim: "Der König beauftragt Holmes.",
          character: "König",
          refs: ["u1", "u2"],
          session: "sX",
          date: "Tag 1"
        )
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

  describe "chapter_header/2 (#752 — deterministisch, kein LLM)" do
    test "ohne datierte Einträge → nackter Kopf" do
      assert Render.chapter_header(%{number: 3}, []) == "## Kapitel 3"

      assert Render.chapter_header(%{number: 3}, [%{in_game_day: nil}]) ==
               "## Kapitel 3"
    end

    test "ein Tag → Einzel-Tag, Range → min–max" do
      assert Render.chapter_header(%{number: 1}, [%{in_game_day: 12}]) ==
               "## Kapitel 1 — Tag 12"

      entries = [%{in_game_day: 14}, %{in_game_day: nil}, %{in_game_day: 12}]
      assert Render.chapter_header(%{number: 2}, entries) == "## Kapitel 2 — Tag 12–14"
    end
  end

  describe "render_opts/0 (#755 — Renders erben Stage-2-Sampling)" do
    test "enthält num_ctx + temperature/top_p/repeat_penalty, aber KEIN num_predict" do
      opts = Render.render_opts()

      assert Keyword.has_key?(opts, :num_ctx)
      assert Keyword.has_key?(opts, :temperature)
      assert Keyword.has_key?(opts, :top_p)
      assert Keyword.has_key?(opts, :repeat_penalty)
      # Prosa terminiert selbst — das Stage-2-Cap würde Kapitel abschneiden.
      refute Keyword.has_key?(opts, :num_predict)
    end

    test "Werte kommen aus den Stage-2-Settings (read-only Passthrough-Beweis)" do
      # KEIN Settings-Write (async-Suite, worker_state ist Singleton) — der
      # Passthrough-Beweis geht auch read-only gegen den aktuellen Wert.
      opts = Render.render_opts()
      assert Keyword.get(opts, :temperature) == Worker.Settings.get(:temperature_stage2)
      assert Keyword.get(opts, :num_ctx) == Worker.Settings.get(:ctx_stage2, 8192)
    end

    test ":render_model-Override spiegelt das Setting (#783, read-only)" do
      # Gleicher read-only Stil: ungesetzt/leer → kein :model-Key; gesetzt →
      # getrimmter Name. Die Override-Logik selbst ist pure getestet in
      # Worker.LLM.ModelOverrideTest.
      opts = Render.render_opts()

      case Worker.Settings.get(:render_model) do
        m when is_binary(m) ->
          case String.trim(m) do
            "" -> refute Keyword.has_key?(opts, :model)
            t -> assert Keyword.get(opts, :model) == t
          end

        _ ->
          refute Keyword.has_key?(opts, :model)
      end
    end
  end
end
