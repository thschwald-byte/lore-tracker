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

    # #909 (Epic #900 S5): Bogen-Titel-Zeilen sind Struktur, keine Claims —
    # ohne Strip klebte "**Der Deal**" am ersten Satz und flaggte ihn.
    test "fette Titel-Zeilen und #-Headings erzeugen kein Flag, md bleibt voll" do
      md =
        "**Der Deal**\nDer König beauftragt Holmes mit der Sache.\n\n## Kapitel 3\nIrene flieht ins Ausland."

      trace = fn claim, _facts -> not String.contains?(claim, "*") end

      g = Render.gate_rendered(md, @fact_claims, trace)
      assert g.clean? == true
      assert g.flagged == []

      assert g.traceable == [
               "Der König beauftragt Holmes mit der Sache.",
               "Irene flieht ins Ausland."
             ]

      # Der persistierte Text behält die Struktur.
      assert g.md =~ "**Der Deal**"
    end

    test "Format-Drift (**Titel:** Satz in einer Zeile) wird NICHT gestrippt (benannte Grenze)" do
      md = "**Der Deal:** Der König beauftragt Holmes mit der Sache."
      trace = fn claim, _facts -> not String.contains?(claim, "*") end

      g = Render.gate_rendered(md, @fact_claims, trace)
      # Die Zeile ist kein reiner Titel → sie bleibt Claim-Material und flaggt
      # hier (trace_fn lehnt *-haltige Claims ab) — dokumentiertes Verhalten.
      assert g.flagged == ["**Der Deal:** Der König beauftragt Holmes mit der Sache."]
    end
  end

  # #909 (Epic #900 S5): der Arc-strukturierte Render-Prompt — Fakten mit
  # Bogen-Annotation (bogen_titel/bogen_kind aus Render.annotate_boegen)
  # rendern gruppiert; ohne Annotation bleibt der flache Alt-Prompt.
  describe "Bogen-Gruppierung (#909)" do
    defp bfact(claim, titel, kind, alias_name \\ "") do
      %{
        "claim" => claim,
        "character_alias" => alias_name,
        "bogen_titel" => titel,
        "bogen_kind" => kind
      }
    end

    defp los(claim), do: %{"claim" => claim, "character_alias" => ""}

    test "Resümee: Bogen-Sektionen in Erzähl-Chronologie, context+rauschen raus, Weiteres hinten" do
      facts = [
        bfact("Deal eingefädelt.", "Der Deal", "arc", "Skrapnik"),
        bfact("Seattle stimmt ab.", "die Welt", "context"),
        bfact("Foto erkannt.", "Kodex' Vergangenheit", "arc"),
        los("Van verloren."),
        bfact("Deal besiegelt.", "Der Deal", "arc"),
        bfact("Pizza bestellt.", "Tisch-Gerede", "rauschen"),
        bfact("Mann vom Foto benannt.", "Kodex' Vergangenheit", "arc")
      ]

      p = Render.summary_prompt(facts, %{})

      assert p =~ "gegliedert nach Handlungsbögen"
      assert p =~ "**Der Deal**"
      assert p =~ "**Kodex' Vergangenheit**"
      assert p =~ "**Weiteres**"
      # Erzähl-Chronologie: „Der Deal" (erster Fakt 0) vor „Kodex'" (Fakt 2),
      # „Weiteres" zuletzt.
      assert :binary.match(p, "**Der Deal**") < :binary.match(p, "**Kodex' Vergangenheit**")
      assert :binary.match(p, "**Kodex' Vergangenheit**") < :binary.match(p, "**Weiteres**")
      # Durchlaufende Nummerierung über die Sektionen + Zeilenformat.
      assert p =~ "1. [Skrapnik] Deal eingefädelt."
      assert p =~ "2. Deal besiegelt."
      assert p =~ "3. Foto erkannt."
      assert p =~ "5. Van verloren."
      # context + rauschen sind raus; STRENG bleibt.
      refute p =~ "Seattle stimmt ab."
      refute p =~ "Pizza bestellt."
      assert p =~ "AUSSCHLIESSLICH"
    end

    test "Ein-Fakt-Bogen wandert unter Weiteres (Anti-Fragmentierung)" do
      facts = [
        bfact("A1.", "Bogen A", "arc"),
        bfact("A2.", "Bogen A", "arc"),
        bfact("Einzelgänger.", "Mini-Bogen", "arc")
      ]

      p = Render.summary_prompt(facts, %{})
      assert p =~ "**Bogen A**"
      refute p =~ "**Mini-Bogen**"
      assert p =~ "**Weiteres**\n3. Einzelgänger."
    end

    test "Fallback: nur context-Fakten → flacher Prompt mit den context-Fakten" do
      facts = [
        bfact("Seattle stimmt ab.", "die Welt", "context"),
        bfact("Konzerne regieren.", "die Welt", "context")
      ]

      p = Render.summary_prompt(facts, %{})
      assert p =~ "3-6 Sätze"
      refute p =~ "Handlungsbögen"
      assert p =~ "1. Seattle stimmt ab."
      assert p =~ "2. Konzerne regieren."
    end

    test "Fallback: alles rauschen → flache Voll-Liste (letzte Rettung)" do
      facts = [bfact("Pizza.", "Tisch", "rauschen"), bfact("Pause.", "Tisch", "rauschen")]

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          p = Render.summary_prompt(facts, %{})
          assert p =~ "1. Pizza."
          assert p =~ "2. Pause."
        end)

      assert log =~ "ausschließlich rauschen"
    end

    test "ohne Annotation: flacher Alt-Prompt (Vorschau/Eval-Pfad)" do
      p = Render.summary_prompt([los("Nur ein Fakt.")], %{})
      assert p =~ "3-6 Sätze"
      refute p =~ "Handlungsbögen"
    end

    test "Flavor-Preamble steht auch im gruppierten Prompt vor dem Body" do
      facts = [bfact("A1.", "Bogen A", "arc"), bfact("A2.", "Bogen A", "arc")]
      p = Render.summary_prompt(facts, %{flavors: %{"base" => "Neon-Noir"}})

      assert :binary.match(p, "Stil-Vorgabe") < :binary.match(p, "Handlungsbögen")
      assert p =~ "Neon-Noir"
    end

    test "Epos: gruppiert, EINE fließende Geschichte, context als Hintergrund, rauschen raus" do
      facts = [
        bfact("Deal eingefädelt.", "Der Deal", "arc"),
        bfact("Deal besiegelt.", "Der Deal", "arc"),
        bfact("Seattle stimmt ab.", "die Welt", "context"),
        bfact("Pizza.", "Tisch", "rauschen"),
        los("Van verloren.")
      ]

      p = Render.epos_prompt(facts, %{})

      assert p =~ "**Der Deal**"
      assert p =~ "**Weiteres**"
      assert p =~ "ohne Zwischenüberschriften"
      assert p =~ "Erfinde KEINE neuen Plot-Fakten"
      assert p =~ "Hintergrund/Weltwissen"
      assert p =~ "- Seattle stimmt ab."
      refute p =~ "Pizza."
      # Hintergrund ist unnummeriert (keine Ereignis-Zeile).
      refute p =~ "3. Seattle stimmt ab."
    end

    test "Epos ohne Bögen mit context: flacher context-Fallback ohne Hintergrund-Sektion" do
      facts = [bfact("Seattle stimmt ab.", "die Welt", "context")]
      p = Render.epos_prompt(facts, %{})

      refute p =~ "Hintergrund/Weltwissen"
      assert p =~ "1. Seattle stimmt ab."
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

  describe "Stil-Flavors in den Render-Prompts (#787)" do
    @facts [%{"claim" => "Irene flieht.", "character_alias" => "Irene"}]

    test "ohne Campaign/Flavors: keine Stil-Preamble (Default unverändert)" do
      refute Render.summary_prompt(@facts) =~ "Stil-Vorgabe"
      refute Render.epos_prompt(@facts, %{}) =~ "Stil-Vorgabe"
    end

    test "base + Slot-Flavor landen als Preamble VOR dem Prompt-Body" do
      camp = %{flavors: %{"base" => "Verona um 1300", "summary" => "knapp, nüchtern"}}
      p = Render.summary_prompt(@facts, camp)

      assert p =~ "Stil-Vorgabe"
      assert p =~ "Verona um 1300"
      assert p =~ "knapp, nüchtern"
      # Stil vor Body — und die Faithful-Regel bleibt drin.
      assert :binary.match(p, "Stil-Vorgabe") < :binary.match(p, "AUSSCHLIESSLICH")
    end

    test "epos-Slot wirkt nur im Epos-Prompt, summary-Slot nur im Resümee" do
      camp = %{flavors: %{"summary" => "wie-ein-protokoll", "epos" => "hohes-pathos"}}

      assert Render.summary_prompt(@facts, camp) =~ "wie-ein-protokoll"
      refute Render.summary_prompt(@facts, camp) =~ "hohes-pathos"
      assert Render.epos_prompt(@facts, camp) =~ "hohes-pathos"
      refute Render.epos_prompt(@facts, camp) =~ "wie-ein-protokoll"
    end

    test "Überschrift-Direktive: nur beim Resümee, nie beim Epos (#752-Kapitel-Kopf)" do
      camp = %{
        flavors: %{},
        vorgaben: %{"summary" => %{name: "Zeitungsartikel"}, "epos" => %{name: "Ballade"}}
      }

      assert Render.summary_prompt(@facts, camp) =~ "«Zeitungsartikel»"
      refute Render.epos_prompt(@facts, camp) =~ "«Ballade»"
      refute Render.epos_prompt(@facts, camp) =~ "Textsorte"
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

  describe "render_opts/0 (#755 — Renders erben Sampling; #783 Phase 2 — Stage 4 statt Stage 2)" do
    test "enthält num_ctx + temperature/top_p/repeat_penalty, aber KEIN num_predict" do
      opts = Render.render_opts()

      assert Keyword.has_key?(opts, :num_ctx)
      assert Keyword.has_key?(opts, :temperature)
      assert Keyword.has_key?(opts, :top_p)
      assert Keyword.has_key?(opts, :repeat_penalty)
      # Prosa terminiert selbst — das Stage-4-Cap würde Kapitel abschneiden.
      refute Keyword.has_key?(opts, :num_predict)
    end

    test "Werte kommen aus den Stage-4-Settings (read-only Passthrough-Beweis)" do
      # KEIN Settings-Write (async-Suite, worker_state ist Singleton) — der
      # Passthrough-Beweis geht auch read-only gegen den aktuellen Wert.
      opts = Render.render_opts()
      assert Keyword.get(opts, :temperature) == Worker.Settings.get(:temperature_stage4)
      assert Keyword.get(opts, :num_ctx) == Worker.Settings.get(:ctx_stage4, 8192)
    end
  end

  describe "epos_opts/0 (#783 Phase 2 Nachtrag — Epos-Kapitel auf Stage 5, getrennt vom Resümee)" do
    test "enthält num_ctx + temperature/top_p/repeat_penalty, aber KEIN num_predict" do
      opts = Render.epos_opts()

      assert Keyword.has_key?(opts, :num_ctx)
      assert Keyword.has_key?(opts, :temperature)
      assert Keyword.has_key?(opts, :top_p)
      assert Keyword.has_key?(opts, :repeat_penalty)
      refute Keyword.has_key?(opts, :num_predict)
    end

    test "Werte kommen aus den Stage-5-Settings, nicht Stage 4 (kein Cross-Stage-Bleed)" do
      opts = Render.epos_opts()
      assert Keyword.get(opts, :temperature) == Worker.Settings.get(:temperature_stage5)
      assert Keyword.get(opts, :num_ctx) == Worker.Settings.get(:ctx_stage5, 8192)
    end
  end
end
