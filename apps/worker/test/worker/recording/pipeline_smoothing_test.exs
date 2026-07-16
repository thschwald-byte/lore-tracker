defmodule Worker.Recording.Pipeline.SmoothingTest do
  @moduledoc """
  Issue #862 (Epic #861 Slice A): die pure Transkript-Glättung. Deckt die
  Plan-Test-Matrix: Merge-Adjazenz+Gap, OOC-Grenze (beide Fehlerrichtungen),
  Dedup/Füllwort, Content-ID-Stabilität/Reihenfolge-Unabhängigkeit/Rules-
  Version-Drift (Golden), B1b-Mitgliedschaft, Lücken-Signale inkl. des
  benannten „so unserem"-False-Negatives, effective_text-Präzedenz, Randfälle.
  Kein LLM, kein Mnesia.
  """
  use ExUnit.Case, async: true

  alias Worker.Recording.Pipeline.Smoothing

  @base ~U[2026-07-15 20:00:00Z]

  defp utt(id, did, text, offset_s, conf \\ nil) do
    %{
      id: id,
      session_id: "s1",
      discord_id: did,
      timestamp: DateTime.add(@base, offset_s, :second),
      text: text,
      confidence: conf,
      status: "confirmed"
    }
  end

  defp ids(block), do: block["quell_utterance_ids"]

  describe "Sprecher-Merge (Adjazenz + Gap)" do
    test "gleicher Sprecher innerhalb des Gaps → EIN Block" do
      %{blocks: [b]} =
        Smoothing.smooth([
          utt("u1", "A", "Wir kommen zurück", 0),
          utt("u2", "A", "zu unserem Abenteuer", 3)
        ])

      assert ids(b) == ["u1", "u2"]
      assert b["text"] == "Wir kommen zurück zu unserem Abenteuer"
      assert b["speaker_discord_id"] == "A"
    end

    test "Kalibrier-Anker: 5s-Pause (mit Lacher) merged beim 8s-Default" do
      # DER Kalibrier-Fall aus dem Plan (F3): 19:19:33 → 19:19:38, 5 s.
      # Beim Default 8 s merged das durch — bewusste Start-Hypothese, das
      # Setting ist campaign-tunbar (Slice C verdrahtet die Quelle).
      %{blocks: blocks} =
        Smoothing.smooth([
          utt("u1", "A", "Wir kommen mal zurück", 0),
          utt("u2", "A", "zu unserem kleinen Abenteuer", 5)
        ])

      assert [_ein_block] = blocks
    end

    test "Gap überschritten → Split (zwei Blöcke desselben Sprechers)" do
      %{blocks: blocks} =
        Smoothing.smooth([
          utt("u1", "A", "Erster Gedanke", 0),
          utt("u2", "A", "Neuer Gedanke nach Pause", 60)
        ])

      assert [b1, b2] = blocks
      assert ids(b1) == ["u1"]
      assert ids(b2) == ["u2"]
    end

    test "merge_gap_seconds ist ein Opt (kleineres Gap → Split)" do
      %{blocks: blocks, merge_gap_seconds: 2} =
        Smoothing.smooth(
          [utt("u1", "A", "eins", 0), utt("u2", "A", "zwei", 5)],
          merge_gap_seconds: 2
        )

      assert length(blocks) == 2
    end

    test "Sprecherwechsel → Split, auch bei Gap 0" do
      %{blocks: blocks} =
        Smoothing.smooth([
          utt("u1", "A", "Frage an dich", 0),
          utt("u2", "B", "Meine Antwort", 0),
          utt("u3", "A", "Und weiter", 1)
        ])

      assert length(blocks) == 3
    end

    test "identische Timestamps beim selben Sprecher → merge (Gap 0 ≤ Default)" do
      %{blocks: [b]} =
        Smoothing.smooth([utt("u1", "A", "eins", 0), utt("u2", "A", "zwei", 0)])

      assert ids(b) == ["u1", "u2"]
    end

    test "Utterance ohne discord_id merged NIE (nil ist kein Sprecher)" do
      %{blocks: blocks} =
        Smoothing.smooth([
          utt("u1", nil, "wer war das", 0),
          utt("u2", nil, "schon wieder", 1)
        ])

      assert length(blocks) == 2
    end

    test "leere Liste → leeres Ergebnis" do
      assert %{blocks: [], ooc_verworfen: []} = Smoothing.smooth([])
    end

    test "alle Utterances vom selben Sprecher → ein Block über die ganze Session" do
      utts = for i <- 1..20, do: utt("u#{i}", "SL", "Satz Nummer #{i}", i * 2)
      %{blocks: [b]} = Smoothing.smooth(utts)
      assert length(ids(b)) == 20
    end
  end

  describe "OOC-Grenze (F7 — beide Fehlerrichtungen)" do
    test "OOC bricht den Merge-Run: Narration + Würfel + Narration → 2 Blöcke, OOC verworfen" do
      %{blocks: blocks, ooc_verworfen: ooc} =
        Smoothing.smooth([
          utt("u1", "A", "Der König betritt den Raum", 0),
          utt("u2", "A", "ich würfle mal eben", 2),
          utt("u3", "A", "und verneigt sich tief", 4)
        ])

      # Narration verschwindet NICHT (beide Hälften bleiben) …
      assert [b1, b2] = blocks
      assert ids(b1) == ["u1"]
      assert ids(b2) == ["u3"]
      # … und der OOC-Turn überlebt NICHT als IC in einem Block.
      assert ooc == ["u2"]
      refute Enum.any?(blocks, fn b -> "u2" in ids(b) end)
    end

    test "ooc_verworfen ist auditierbar (war OOC ≠ Smoother hat's verloren)" do
      %{blocks: [_], ooc_verworfen: ooc} =
        Smoothing.smooth([
          utt("u1", "A", "38 gegen 55 geschafft", 0),
          utt("u2", "A", "Der Schuss verfehlt die Wache", 2)
        ])

      assert ooc == ["u1"]
    end
  end

  describe "Dedup + Füllwort-Strip" do
    test "Stotter-Dedup: unmittelbare Wiederholung kollabiert, erste Form gewinnt" do
      assert Smoothing.dedup_stutter("Wir Wir kommen") == "Wir kommen"
      assert Smoothing.dedup_stutter("Wir wir kommen") == "Wir kommen"
      assert Smoothing.dedup_stutter("und dann dann ging er") == "und dann ging er"
      # Keine Fern-Wiederholung: nur UNMITTELBARE Dubletten.
      assert Smoothing.dedup_stutter("er sah was er sah") == "er sah was er sah"
    end

    test "Füllwörter fliegen (case-insensitiv, satzzeichen-tolerant)" do
      assert Smoothing.strip_fillers("äh wir gehen ähm los") == "wir gehen los"
      assert Smoothing.strip_fillers("Ähm, also los") == "also los"
    end

    test "Dedup über Utterance-Grenzen im Block (Join vor Dedup)" do
      %{blocks: [b]} =
        Smoothing.smooth([
          utt("u1", "A", "Wir gehen zum", 0),
          utt("u2", "A", "zum Turm hinauf", 2)
        ])

      assert b["text"] == "Wir gehen zum Turm hinauf"
    end

    test "B1b: komplett gestrippte Utterance BLEIBT in quell_utterance_ids" do
      %{blocks: [b]} =
        Smoothing.smooth([
          utt("u1", "A", "ähm", 0),
          utt("u2", "A", "Der Plan steht", 2)
        ])

      # Mitgliedschaft ist Input-basiert — die ID hängt nicht am Strip-Ergebnis.
      assert ids(b) == ["u1", "u2"]
      assert b["text"] == "Der Plan steht"
    end

    test "Nur-Füllwort-Block wird VERWORFEN (nie leeres source_ref-Ziel)" do
      %{blocks: blocks} =
        Smoothing.smooth([
          utt("u1", "A", "äh ähm", 0),
          utt("u2", "B", "Echter Inhalt", 10)
        ])

      assert [b] = blocks
      assert ids(b) == ["u2"]
    end
  end

  describe "Content-Adresse (K1)" do
    test "Stabilität: gleiche Menge + gleiche Regeln → gleiche ID" do
      assert Smoothing.block_id(["u1", "u2"]) == Smoothing.block_id(["u1", "u2"])
    end

    test "Reihenfolge-Unabhängigkeit: andere Einlese-Reihenfolge → identische ID" do
      assert Smoothing.block_id(["u2", "u1", "u3"]) == Smoothing.block_id(["u1", "u3", "u2"])
    end

    test "Kompositions-Änderung → andere ID" do
      refute Smoothing.block_id(["u1", "u2"]) == Smoothing.block_id(["u1", "u2", "u3"])
    end

    test "Golden: rules_version ist gepinnt — Regel-Drift rotet diesen Test SICHTBAR" do
      # Ändert sich @fillers / die OOC-Regexes / ein Semantik-Tag, ändert sich
      # die abgeleitete Version → dieser Pin rotet → der Autor weiß, dass ALLE
      # Block-IDs invalidieren (Re-Attach D+E fängt die Kurationen). Beim
      # bewussten Regel-Update: neuen Wert hier einpinnen.
      assert Smoothing.rules_version() == 59_094_094
    end
  end

  describe "Signale (⚠ + Lücke)" do
    test "asr_unsicher propagiert vom Mitglied auf den Block" do
      conf = %{"low_token_fraction" => 0.4, "token_count" => 12, "mean_p" => 0.7, "min_p" => 0.3}

      %{blocks: [b]} =
        Smoothing.smooth([
          utt("u1", "A", "klarer Satz", 0),
          utt("u2", "A", "wackliger Satz", 2, conf)
        ])

      assert b["asr_unsicher"] == true
    end

    test "detect_luecke: low_token_fraction-Signal" do
      conf = %{"low_token_fraction" => 0.5, "token_count" => 10}
      %{blocks: [b]} = Smoothing.smooth([utt("u1", "A", "kaum verständlich hier", 0, conf)])
      assert b["hat_luecke"] == true
      assert b["konfidenz"] == "niedrig"
    end

    test "detect_luecke: min_p-Signal" do
      conf = %{"min_p" => 0.05, "token_count" => 9}
      %{blocks: [b]} = Smoothing.smooth([utt("u1", "A", "ein Wort war Matsch", 0, conf)])
      assert b["hat_luecke"] == true
    end

    test "detect_luecke: hängendes Funktionswort / Ellipse (abgebrochenes Syntagma)" do
      %{blocks: [b1]} = Smoothing.smooth([utt("u1", "A", "wir gehen jetzt zu", 0)])
      assert b1["hat_luecke"] == true

      %{blocks: [b2]} = Smoothing.smooth([utt("u1", "A", "und dann…", 0)])
      assert b2["hat_luecke"] == true
    end

    test "detect_luecke: Satzzeichen schließt den Satz — Funktionswort am Ende ist dann KEIN Signal" do
      # Real-Befund Free Seattle (2026-07-16): der frühere Punkt-Trim flaggte
      # „Aber das ist so." (vollständiger Satz) als Lücke — Fehlalarm-Flut
      # (261/744 Blöcke). Punkt/!/? am Ende = geschlossener Satz.
      %{blocks: [b1]} = Smoothing.smooth([utt("u1", "A", "Aber das ist so.", 0)])
      assert b1["hat_luecke"] == false

      %{blocks: [b2]} = Smoothing.smooth([utt("u1", "A", "Machst du das auch?", 0)])
      assert b2["hat_luecke"] == false

      # Ohne Satzzeichen bleibt das hängende Funktionswort ein Signal.
      %{blocks: [b4]} = Smoothing.smooth([utt("u1", "A", "beim Dashboard kannst du auf", 0)])
      assert b4["hat_luecke"] == true
    end

    test "token_count == 0 (Seed-Platzhalter) ist KEIN Lücken-/Unsicherheits-Signal" do
      conf = %{"low_token_fraction" => 0.0, "token_count" => 0, "mean_p" => 1.0, "min_p" => 1.0}
      %{blocks: [b]} = Smoothing.smooth([utt("u1", "A", "Seed-Text ohne echtes ASR", 0, conf)])
      assert b["hat_luecke"] == false
      assert b["asr_unsicher"] == false
    end

    test "BENANNTE GRENZE (F4): so-unserem-Fall — grammatische Lücke bei hoher Konfidenz ist FALSE NEGATIVE" do
      # Der Ur-Fall des Epics: fehlendes „zu", jedes Wort einzeln ASR-konfident,
      # endet nicht auf Funktionswort/Ellipse. Die deterministischen Signal-
      # Regeln fangen ihn NICHT — dokumentierte Grenze, kein stillschweigend
      # gelöster Fall. (Fängt ihn eine künftige Regel, DARF dieser Test grün
      # kippen — dann Erwartung bewusst drehen.)
      conf = %{
        "low_token_fraction" => 0.02,
        "token_count" => 14,
        "mean_p" => 0.96,
        "min_p" => 0.8
      }

      %{blocks: [b]} =
        Smoothing.smooth([
          utt("u1", "A", "Wir kommen mal zurück so unserem kleinen Abenteuer", 0, conf)
        ])

      assert b["hat_luecke"] == false
      assert b["konfidenz"] == "hoch"
    end
  end

  describe "Verdrahtungs-Sanity (#864): Block-Kontext + restrict_to_refs" do
    test "ein Fakt mit Block-ID-Refs bekommt NUR das Ref-Fenster als Kontext, nie das volle Transkript" do
      # DIE Silent-Fail-Falle der Vollumstellung (Kollision A): matchen refs
      # nicht, fällt restrict_to_refs aufs volle Transkript zurück → jeder
      # Decoy fände Halt, die FPR stiege für alle gleichmäßig, nichts crasht.
      # Dieser Test beweist die Verdrahtung to_context ↔ restrict_to_refs.
      utts = [
        utt("u1", "A", "Der König betritt den Raum", 0),
        utt("u2", "B", "Ich beobachte ihn genau", 30),
        utt("u3", "A", "Er verneigt sich tief", 60),
        utt("u4", "B", "Wir folgen ihm leise", 90)
      ]

      %{blocks: blocks} = Smoothing.smooth(utts)
      context = Smoothing.to_context(blocks)
      assert length(context) == 4

      target = Enum.at(context, 2)

      restricted = Worker.Recording.Pipeline.Verify.restrict_to_refs(context, [target.id])

      # Ref-Fenster (Treffer ± grounding_context_window), NICHT alle 4 Blöcke.
      assert length(restricted) < length(context)
      assert Enum.any?(restricted, &(&1.id == target.id))

      # Der dokumentierte Fallback: nicht-matchende Refs → volle Liste
      # (bewusst breiter Kontext — im kuratierten Pfad nie erwünscht, genau
      # deshalb nagelt dieser Test das Match-Verhalten fest).
      assert Worker.Recording.Pipeline.Verify.restrict_to_refs(context, ["b_gibtsnicht"]) ==
               context
    end
  end

  describe "effective_text/3 — Präzedenz Override > Vorschlag > Smoothed" do
    setup do
      {:ok, block: %{"id" => "b_x", "text" => "Wir kommen zurück so unserem Abenteuer"}}
    end

    test "ohne alles → Smoothed-Text", %{block: b} do
      assert Smoothing.effective_text(b, nil, nil) == b["text"]
    end

    test "offener Vorschlag wird angewandt (erste Fundstelle)", %{block: b} do
      v = %{"original" => "so unserem", "vorschlag" => "zu unserem"}
      assert Smoothing.effective_text(b, v, nil) == "Wir kommen zurück zu unserem Abenteuer"
    end

    test "kuratierter Override schlägt den Vorschlag (alle drei Kurations-Status)", %{block: b} do
      v = %{"original" => "so unserem", "vorschlag" => "bei unserem"}

      for st <- ["bestaetigt", "manuell_korrigiert", "original_bestaetigt"] do
        ov = %{"status" => st, "bestaetigter_text" => "Kuratierter Text #{st}"}
        assert Smoothing.effective_text(b, v, ov) == "Kuratierter Text #{st}"
      end
    end

    test "unbrauchbar segnet keinen Text ab → Vorschlag/Smoothed-Kette greift", %{block: b} do
      ov = %{"status" => "unbrauchbar"}
      v = %{"original" => "so unserem", "vorschlag" => "zu unserem"}
      assert Smoothing.effective_text(b, v, ov) == "Wir kommen zurück zu unserem Abenteuer"
      assert Smoothing.effective_text(b, nil, ov) == b["text"]
    end
  end
end
