defmodule Worker.Recording.PipelineStage2ChunkingTest do
  @moduledoc """
  Issue #417/#683: Chunking-Bausteine der Extraktions-Map-Reduce (seit #786
  der einzige Nutzer — der Chain-Stage-2-Pfad ist entfernt).

  Getestet werden die **puren** Bausteine direkt gegen die doc-hidden public
  Funktionen — `chunk_utterances/3`, `stage2_chunking_needed?/3`. Die volle
  Map-Reduce-Orchestrierung läuft durch einen echten LLM und wird im PR-Test
  verifiziert — kein Mock-Backend im Repo.

  Token-Heuristik (wie im Code): `estimate_tokens(text) = div(byte_size(text), 3)`.
  Fixtures sind so dimensioniert, dass eine Utterance-Zeile genau 10 Token wiegt:
  `transcript_line` = `"[u] " <> name <> ": " <> text` = 4 + 1 + 2 + 23 = 30 Bytes.
  """

  use ExUnit.Case, async: true

  alias Worker.Recording.Pipeline

  # discord_id "s" (1 Byte, kein speaker_names-Eintrag → Fallback auf die ID),
  # text 23 Bytes → Zeile 30 Bytes → 10 Token.
  defp utt(n), do: %{id: "u#{n}", discord_id: "s", text: String.duplicate("x", 23)}
  defp utts(range), do: Enum.map(range, &utt/1)
  defp ids(chunk), do: Enum.map(chunk, & &1.id)

  describe "chunk_utterances/3" do
    test "leere Liste → keine Chunks" do
      assert Pipeline.chunk_utterances([], 6000, %{}) == []
    end

    test "alles passt → genau ein Chunk mit allen Utterances in Reihenfolge" do
      list = utts(1..6)
      # 6 × 10 = 60 Token ≤ 100
      assert [chunk] = Pipeline.chunk_utterances(list, 100, %{})
      assert ids(chunk) == ["u1", "u2", "u3", "u4", "u5", "u6"]
    end

    test "splittet an Utterance-Grenzen + Overlap N=2 zwischen Chunks" do
      list = utts(1..10)
      # budget 50 = 5 Utts/Chunk; Overlap 2 → [u1-5],[u4-8],[u7-10]
      chunks = Pipeline.chunk_utterances(list, 50, %{})

      assert Enum.map(chunks, &ids/1) == [
               ["u1", "u2", "u3", "u4", "u5"],
               ["u4", "u5", "u6", "u7", "u8"],
               ["u7", "u8", "u9", "u10"]
             ]
    end

    test "deckt alle Utterances ab + monoton in Reihenfolge" do
      list = utts(1..10)
      chunks = Pipeline.chunk_utterances(list, 50, %{})

      seen = chunks |> Enum.flat_map(&ids/1) |> Enum.uniq()
      assert seen == Enum.map(1..10, &"u#{&1}")

      idx = fn u -> String.to_integer(String.trim_leading(u.id, "u")) end

      # Innerhalb jedes Chunks streng aufsteigend (Reihenfolge intakt)...
      per_chunk = Enum.map(chunks, fn c -> Enum.map(c, idx) end)
      assert Enum.all?(per_chunk, fn xs -> xs == Enum.sort(xs) end)

      # ...und die Chunk-Startindizes laufen vorwärts (kein Rückwärts-Sprung
      # über die Chunk-Grenzen hinweg, Overlap ausgenommen).
      starts = Enum.map(per_chunk, &List.first/1)
      assert starts == Enum.sort(starts)
    end

    test "Einzel-Element über Budget wird geteilt statt als unteilbarer Chunk durchgereicht (#1045)" do
      # Unterscheidbare Wörter, damit jedes Teil-Element eindeutig ist — nur so
      # lässt sich Abdeckung trotz Overlap-Duplikaten sauber prüfen.
      big_text = Enum.map_join(1..60, " ", &"wort#{&1}")
      big = %{id: "big", discord_id: "s", text: big_text}
      list = [utt(1), big, utt(2)]
      chunks = Pipeline.chunk_utterances(list, 30, %{})

      # Nichts geht verloren, und die Nachbarn bleiben erhalten.
      all_ids = chunks |> Enum.flat_map(&ids/1) |> Enum.uniq()
      assert "big" in all_ids
      assert "u1" in all_ids
      assert "u2" in all_ids

      # Der Kern von #1045: die Chunks enthalten exakt die Teil-Elemente aus
      # split_oversized, in Reihenfolge (uniq behält das ERSTE Vorkommen —
      # Overlap-Wiederholungen kommen stets nach ihrem Original).
      erwartete_teile = Worker.Recording.Pipeline.Stages.split_oversized(big, 30, %{})
      gepackt = chunks |> List.flatten() |> Enum.filter(&(&1.id == "big"))

      assert length(erwartete_teile) > 1
      assert Enum.uniq(gepackt) == erwartete_teile
    end
  end

  # ─── Issue #1045: Riesen-Block-Split (der S62-Prod-Fall) ─────────────

  describe "split_oversized/3 + chunk_utterances/3 — Solo-Sprecher-Riesen-Block" do
    # Der Prod-Fall in klein: EIN Glättungs-Block (ein Sprecher, merge_gap=30
    # verschmilzt den ganzen Monolog), dessen Text das Chunk-Budget um ein
    # Vielfaches sprengt. Vor #1045: 1 Chunk mit 1 Element → :parse_failed →
    # Halbierungs-Retry kann nicht teilen → GARANTIERT extraction_empty.
    defp riesen_block do
      satz = "abcdefg hijklmn opqrst. "

      %{
        id: "b_riese",
        discord_id: "gm",
        text: String.duplicate(satz, 120) |> String.trim_trailing(),
        quell_utterance_ids: ["utt-1", "utt-2", "utt-3"]
      }
    end

    test "der Riesen-Block wird auf mehrere mehr-elementige Chunks verteilt" do
      chunks = Pipeline.chunk_utterances([riesen_block()], 210, %{})

      assert length(chunks) > 1
      assert Enum.all?(chunks, fn c -> Enum.all?(c, &(&1.id == "b_riese")) end)

      # DIE Eigenschaft, deren Fehlen S62 gekostet hat: jeder Chunk ist für den
      # #763-Halbierungs-Retry teilbar — kein Chunk fällt auf [] zurück.
      # (Der letzte Chunk KANN 1 Element haben; dann ist er aber klein und
      # scheitert nicht an der Größe. Alle Budget-großen sind mehrteilig.)
      assert Enum.count(chunks, fn c ->
               Worker.Recording.Pipeline.Stages.split_chunk_for_retry(c) != []
             end) >=
               length(chunks) - 1
    end

    test "jeder Chunk bleibt im Token-Budget (bis auf Rundungs-Slack) — auch Overlap-geseedete" do
      # Ehrlicher Vertrag: build_chunks schätzt pro ZEILE (Floor-Division, ohne
      # Newlines und ohne die echten [uN]-Index-Breiten) — der gerenderte Chunk
      # liegt deshalb bis zu ~2 Tokens PRO ZEILE über der Schätzsumme. Der
      # Anspruch ist "kein Vielfaches des Budgets mehr" (vor dem Fix: bis 2,9×
      # via Overlap-Seeding), nicht Token-Exaktheit.
      budget = 210
      chunks = Pipeline.chunk_utterances([riesen_block()], budget, %{})

      for chunk <- chunks do
        rendered = Worker.Recording.Pipeline.Prompts.render_transcript(chunk, %{})

        assert Worker.Recording.Pipeline.Parsing.estimate_tokens(rendered) <=
                 budget + 2 * length(chunk)
      end
    end

    test "Schwelle budget/3: auch ein Block ZWISCHEN budget/3 und budget wird geteilt (Review-Fund)" do
      # Der S62-Prod-Block (≈3.264 Tokens) lag UNTER dem Default-Budget 3500 —
      # mit Schwelle `> budget` wäre er ungeteilt geblieben und als
      # unhalbierbarer Chunk-Kern gescheitert. Nachgestellt in klein:
      # Zeile ≈ 136 Tokens bei budget 210 (Drittel = 70).
      mittel = %{id: "b_mittel", discord_id: "gm", text: String.duplicate("wort satz. ", 37)}
      parts = Worker.Recording.Pipeline.Stages.split_oversized(mittel, 210, %{})

      assert length(parts) > 1
      assert Enum.map_join(parts, "", & &1.text) == mittel.text
    end

    test "Kosten-Deckel: Fünftel-Teile + Overlap 2 ⇒ Stride ≥ 3, keine 3×-Amplifikation (Review-Fund)" do
      # Mit Drittel-Teilen wäre jeder Folge-Chunk nur EIN neues Teil (Stride 1,
      # ~3× LLM-Calls). Fünftel-Teile packen ~5 pro Chunk bei Overlap 2.
      budget = 210
      b = riesen_block()
      n_parts = length(Worker.Recording.Pipeline.Stages.split_oversized(b, budget, %{}))
      chunks = Pipeline.chunk_utterances([b], budget, %{})

      assert length(chunks) <= div(n_parts, 3) + 2
    end

    test "Teil-Elemente tragen Block-ID, Sprecher und quell_utterance_ids unverändert" do
      [%{id: id} = b] = [riesen_block()]
      parts = Worker.Recording.Pipeline.Stages.split_oversized(b, 210, %{})

      assert length(parts) > 1
      assert Enum.all?(parts, &(&1.id == id))
      assert Enum.all?(parts, &(&1.discord_id == "gm"))
      assert Enum.all?(parts, &(&1.quell_utterance_ids == ["utt-1", "utt-2", "utt-3"]))
      assert Enum.map_join(parts, "", & &1.text) == b.text
    end

    test "Element im Budget kommt IDENTISCH zurück (Normalfall byte-gleich zu vor #1045)" do
      u = utt(1)
      assert Worker.Recording.Pipeline.Stages.split_oversized(u, 100, %{}) == [u]
    end

    test "leerer Text bei Mini-Budget wird nie verworfen (flag-not-drop)" do
      u = %{id: "leer", discord_id: "sprecher-mit-sehr-langem-namen", text: ""}
      assert Worker.Recording.Pipeline.Stages.split_oversized(u, 1, %{}) == [u]
    end
  end

  describe "split_text_to_parts/2 — verlustfreies Zerlegen (#1045)" do
    alias Worker.Recording.Pipeline.Stages

    test "Satzgrenzen-Schnitt: Konkatenation ist byte-identisch (inkl. Whitespace)" do
      text = "Erster Satz. Zweiter Satz!  Dritter mit  Doppelspace. Vierter?\nFünfter…"
      parts = Stages.split_text_to_parts(text, 30)

      assert Enum.join(parts) == text
      assert length(parts) > 1
    end

    test "überlanger Satz fällt auf Wortgrenzen zurück" do
      text = String.duplicate("wort ", 40) <> "ende."
      parts = Stages.split_text_to_parts(text, 30)

      assert Enum.join(parts) == text
      assert Enum.all?(parts, &(byte_size(&1) <= 30))
    end

    test "Leerzeichen-loses ASR-Kauderwelsch: Graphem-Schnitt bricht keine UTF-8-Sequenz" do
      text = String.duplicate("Grüße🎲Ärger", 20)
      parts = Stages.split_text_to_parts(text, 16)

      assert Enum.join(parts) == text
      assert Enum.all?(parts, &String.valid?/1)
      assert Enum.all?(parts, &(byte_size(&1) <= 16))
    end
  end

  describe "stage2_chunking_needed?/3" do
    test "kurzes Transkript → kein Chunking" do
      refute Pipeline.stage2_chunking_needed?(utts(1..3), %{}, 1000)
    end

    test "langes Transkript über Budget → Chunking" do
      assert Pipeline.stage2_chunking_needed?(utts(1..50), %{}, 5)
    end
  end
end
