defmodule Worker.LueckenKurationTest do
  @moduledoc """
  Issue #865 (Epic #861 D+E): Konvergenz + Reader-Re-Attach + ANY-Klemme +
  F5-Oberflächen-Ausschluss für die Gap-Fill-Welt.

  Abgedeckt (Plan-Testmatrix Teil 2/Backend):
  - LWW-Konvergenz + Doppel-Zustellung + Cascades der zwei neuen Tabellen
  - Read-Zeit-Re-Attach (F2): direkter Treffer / Mengen-Paarung nach
    Rules-Bump / original_bestaetigt-Text-Match / verwaist / Multi-Pair-LWW /
    unbrauchbar-ohne-Text-Match
  - ANY-Quantor der Klemme (E3): EIN uncurierter Lücken-Block in source_refs
    reicht
  - F5: unbrauchbar nimmt den Block aus der Extraktions-Oberfläche
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Materializer
  alias Worker.Recording.Pipeline.Smoothing
  alias Worker.Recording.Pipeline.Verify
  alias Worker.Repo

  @cid "camp-luecke-865"
  @sid "sess-luecke-865"

  setup do
    reset_for_permutation!()
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
    :ok
  end

  defp block(id, text, quell_ids, opts \\ []) do
    %{
      "id" => id,
      "speaker_discord_id" => "SL",
      "text" => text,
      "quell_utterance_ids" => quell_ids,
      "asr_unsicher" => false,
      "hat_luecke" => Keyword.get(opts, :hat_luecke, false),
      "konfidenz" => "hoch"
    }
  end

  defp vorschlag_event(block_id, opts) do
    payload = %{
      "session_id" => @sid,
      "campaign_id" => @cid,
      "block_id" => block_id,
      "original" => Keyword.get(opts, :original, "wir sollten so"),
      "vorschlag" => Keyword.get(opts, :vorschlag, "wir sollten so [zu] unserem"),
      "modell" => Keyword.get(opts, :modell, "gemma-test")
    }

    event("LueckenVorschlagGeneriert", payload, Keyword.fetch!(opts, :seq),
      event_id: Keyword.fetch!(opts, :event_id)
    )
  end

  defp kuration_event(block_id, opts) do
    payload = %{
      "session_id" => @sid,
      "campaign_id" => @cid,
      "block_id" => block_id,
      "status" => Keyword.get(opts, :status, "bestaetigt"),
      "bestaetigter_text" => Keyword.get(opts, :text, "bestätigter Text"),
      "quell_utterance_ids" => Keyword.get(opts, :quell, ["u1"]),
      "set_by" => Keyword.get(opts, :set_by, "member-1")
    }

    event("LueckenKurationSet", payload, Keyword.fetch!(opts, :seq),
      event_id: Keyword.fetch!(opts, :event_id)
    )
  end

  # ── Konvergenz: Vorschläge ────────────────────────────────────────────────

  describe "LueckenVorschlagGeneriert" do
    test "materialisiert → Reader keyed by Block-Content-ID" do
      Materializer.apply_event(vorschlag_event("b_1", seq: 1, event_id: "lv-1"))

      assert %{"b_1" => v} = Repo.luecken_vorschlaege_for_session(@sid)
      assert v["original"] == "wir sollten so"
      assert v["vorschlag"] == "wir sollten so [zu] unserem"
      assert v["modell"] == "gemma-test"
      assert v["event_id"] == "lv-1"
    end

    test "LWW: divergente Vorschläge zum selben Block, höherer event_id gewinnt in jeder Reihenfolge" do
      events = [
        vorschlag_event("b_1", seq: 1, event_id: "lv-1", vorschlag: "alt"),
        vorschlag_event("b_1", seq: 2, event_id: "lv-2", vorschlag: "neu")
      ]

      results =
        materialize_permutations(events, fn -> Repo.luecken_vorschlaege_for_session(@sid) end)

      Enum.each(results, fn m ->
        assert m["b_1"]["vorschlag"] == "neu"
        assert m["b_1"]["event_id"] == "lv-2"
      end)
    end

    test "Doppel-Zustellung idempotent" do
      ev = vorschlag_event("b_1", seq: 1, event_id: "lv-1")
      Materializer.apply_event(ev)
      m1 = Repo.luecken_vorschlaege_for_session(@sid)
      Materializer.apply_event(ev)
      assert Repo.luecken_vorschlaege_for_session(@sid) == m1
    end
  end

  # ── Konvergenz: Kurations-Overlay ─────────────────────────────────────────

  describe "LueckenKurationSet" do
    test "materialisiert; quell_utterance_ids wird sortiert-kanonisch gespeichert" do
      Materializer.apply_event(
        kuration_event("b_1", seq: 1, event_id: "lk-1", quell: ["u9", "u2", "u5"])
      )

      blocks = [block("b_1", "T", ["u2", "u5", "u9"])]
      %{attached: att, verwaist: []} = Repo.luecken_overrides_effective(@sid, blocks)
      assert att["b_1"]["quell_utterance_ids"] == ["u2", "u5", "u9"]
      assert att["b_1"]["set_by"] == "member-1"
    end

    test "LWW: zwei Kurationen desselben Blocks, höherer event_id gewinnt in jeder Reihenfolge" do
      events = [
        kuration_event("b_1", seq: 1, event_id: "lk-1", text: "alt"),
        kuration_event("b_1", seq: 2, event_id: "lk-2", text: "neu", set_by: "member-2")
      ]

      blocks = [block("b_1", "T", ["u1"])]

      results =
        materialize_permutations(events, fn ->
          Repo.luecken_overrides_effective(@sid, blocks)
        end)

      Enum.each(results, fn %{attached: att} ->
        assert att["b_1"]["bestaetigter_text"] == "neu"
        assert att["b_1"]["set_by"] == "member-2"
      end)
    end
  end

  # ── Cascades ──────────────────────────────────────────────────────────────

  describe "Cascade" do
    setup do
      Materializer.apply_event(event("CampaignCreated", %{"id" => @cid, "name" => "C"}, 1))

      Materializer.apply_event(
        event(
          "SessionScheduled",
          %{"id" => @sid, "campaign_id" => @cid, "number" => 1, "name" => "S1"},
          2
        )
      )

      Materializer.apply_event(vorschlag_event("b_1", seq: 3, event_id: "lv-1"))
      Materializer.apply_event(kuration_event("b_1", seq: 4, event_id: "lk-1"))

      assert Repo.luecken_vorschlaege_for_session(@sid) != %{}

      assert %{attached: att} =
               Repo.luecken_overrides_effective(@sid, [block("b_1", "T", ["u1"])])

      assert map_size(att) == 1
      :ok
    end

    test "SessionDeleted räumt Vorschläge + Overrides" do
      Materializer.apply_event(
        event("SessionDeleted", %{"session_id" => @sid, "campaign_id" => @cid}, 5)
      )

      assert Repo.luecken_vorschlaege_for_session(@sid) == %{}

      assert Repo.luecken_overrides_effective(@sid, [block("b_1", "T", ["u1"])]) ==
               %{attached: %{}, verwaist: []}
    end

    test "CampaignDeleted räumt Vorschläge + Overrides campaign-weit" do
      Materializer.apply_event(
        event("CampaignDeleted", %{"campaign_id" => @cid, "id" => @cid}, 5)
      )

      assert Repo.luecken_vorschlaege_for_session(@sid) == %{}

      assert Repo.luecken_overrides_effective(@sid, [block("b_1", "T", ["u1"])]) ==
               %{attached: %{}, verwaist: []}
    end
  end

  # ── Re-Attach (F2): Read-Zeit-Paarung ─────────────────────────────────────

  describe "Re-Attach (luecken_overrides_effective)" do
    test "Rules-Bump: Override paart über identische Utterance-Menge auf die NEUE Block-ID" do
      # Override wurde gegen die alte Block-ID geschrieben …
      Materializer.apply_event(
        kuration_event("b_old", seq: 1, event_id: "lk-1", quell: ["u1", "u2"], text: "korrigiert")
      )

      # … der aktuelle Snapshot trägt nach dem Regel-Bump eine neue ID,
      # aber dieselbe (sortierte) Utterance-Menge.
      blocks = [block("b_new", "Smoothed-Text", ["u2", "u1"])]

      assert %{attached: att, verwaist: []} = Repo.luecken_overrides_effective(@sid, blocks)
      assert att["b_new"]["bestaetigter_text"] == "korrigiert"
    end

    test "original_bestaetigt paart nur bei EXAKTEM Text-Match; sonst verwaist (Review-Queue)" do
      Materializer.apply_event(
        kuration_event("b_old",
          seq: 1,
          event_id: "lk-1",
          status: "original_bestaetigt",
          quell: ["u1"],
          text: "Der Rohtext gilt so"
        )
      )

      # Text unverändert → attached.
      match = [block("b_new", "Der Rohtext gilt so", ["u1"])]
      assert %{attached: att, verwaist: []} = Repo.luecken_overrides_effective(@sid, match)
      assert att["b_new"]["status"] == "original_bestaetigt"

      # Umgebungstext hat sich geändert → verwaist, NIE still weg.
      drift = [block("b_new2", "Ein anderer Smoothed-Text", ["u1"])]
      assert %{attached: att2, verwaist: [orph]} = Repo.luecken_overrides_effective(@sid, drift)
      assert att2 == %{}
      assert orph["status"] == "original_bestaetigt"
    end

    test "keine paarbare Utterance-Menge → verwaist" do
      Materializer.apply_event(kuration_event("b_old", seq: 1, event_id: "lk-1", quell: ["u1"]))

      blocks = [block("b_x", "T", ["u7", "u8"])]
      assert %{attached: %{}, verwaist: [_]} = Repo.luecken_overrides_effective(@sid, blocks)
    end

    test "Multi-Pair: zwei Overrides paaren denselben Block → LWW-by-event_id, deterministisch" do
      # Alter Override via Mengen-Paarung (andere Block-ID, gleiche Menge) …
      Materializer.apply_event(
        kuration_event("b_old", seq: 1, event_id: "lk-1", quell: ["u1"], text: "alt")
      )

      # … neuer Override direkt gegen die aktuelle Block-ID.
      Materializer.apply_event(
        kuration_event("b_new", seq: 2, event_id: "lk-2", quell: ["u1"], text: "neu")
      )

      blocks = [block("b_new", "T", ["u1"])]
      assert %{attached: att} = Repo.luecken_overrides_effective(@sid, blocks)
      assert map_size(att) == 1
      assert att["b_new"]["bestaetigter_text"] == "neu"
      assert att["b_new"]["event_id"] == "lk-2"
    end

    test "unbrauchbar paart über die Menge OHNE Text-Match (segnet keinen Text ab)" do
      Materializer.apply_event(
        kuration_event("b_old",
          seq: 1,
          event_id: "lk-1",
          status: "unbrauchbar",
          quell: ["u1"],
          text: nil
        )
      )

      blocks = [block("b_new", "Voellig anderer Text", ["u1"])]
      assert %{attached: att, verwaist: []} = Repo.luecken_overrides_effective(@sid, blocks)
      assert att["b_new"]["status"] == "unbrauchbar"
    end

    test "Read-Berechnung ist idempotent (2× lesen == 1×)" do
      Materializer.apply_event(kuration_event("b_1", seq: 1, event_id: "lk-1"))
      blocks = [block("b_1", "T", ["u1"])]

      r1 = Repo.luecken_overrides_effective(@sid, blocks)
      r2 = Repo.luecken_overrides_effective(@sid, blocks)
      assert r1 == r2
    end
  end

  # ── Review-Sicht fürs Hub-Panel (Slice E) ─────────────────────────────────

  describe "review_for_campaign (luecken-Snapshot-Key)" do
    setup do
      Materializer.apply_event(event("CampaignCreated", %{"id" => @cid, "name" => "C"}, 1))

      Materializer.apply_event(
        event(
          "SessionScheduled",
          %{"id" => @sid, "campaign_id" => @cid, "number" => 7, "name" => "S7"},
          2
        )
      )

      blocks = [
        Map.put(block("b_gap", "wir sollten so unserem Ziel", ["u1"]), "hat_luecke", true),
        Map.put(block("b_kur", "Der König spricht", ["u2"]), "hat_luecke", true),
        block("b_clean", "Alles klar hier", ["u3"])
      ]

      Materializer.apply_event(
        event(
          "TranscriptSmoothed",
          %{
            "session_id" => @sid,
            "campaign_id" => @cid,
            "smoothed_at" => "2026-07-16T10:00:00Z",
            "blocks" => blocks,
            "ooc_verworfen" => [],
            "rules_version" => 42,
            "merge_gap_seconds" => 8
          },
          3,
          event_id: "sm-1"
        )
      )

      Materializer.apply_event(
        vorschlag_event("b_gap",
          seq: 4,
          event_id: "lv-1",
          original: "so unserem",
          vorschlag: "so zu unserem"
        )
      )

      Materializer.apply_event(
        kuration_event("b_kur",
          seq: 5,
          event_id: "lk-1",
          quell: ["u2"],
          text: "Der König spricht"
        )
      )

      # Verwaister Override: paart auf keine aktuelle Utterance-Menge.
      Materializer.apply_event(
        kuration_event("b_alt", seq: 6, event_id: "lk-2", quell: ["u99"], text: "alt")
      )

      # Roh-Utterance für den Roh→Geglättet-Diff (Nachtrag 2): u1 trägt ein
      # Füllwort, das der Smoothed-Text von b_gap nicht mehr hat.
      Materializer.apply_event(
        event(
          "UtteranceAppended",
          %{
            "id" => "u1",
            "session_id" => @sid,
            "campaign_id" => @cid,
            "discord_id" => "SL",
            "text" => "wir sollten ähm so unserem Ziel",
            "timestamp" => "2026-07-16T10:00:00Z"
          },
          7
        )
      )

      :ok
    end

    test "liefert nur relevante Blöcke, Vorschlags-Text angewandt, Override + verwaist sichtbar" do
      assert [entry] = Repo.luecken_review_for_campaign(@cid)
      assert entry["session_id"] == @sid
      assert entry["session_number"] == 7

      by_id = Map.new(entry["blocks"], &{&1["block_id"], &1})
      # b_clean (keine Lücke, kein Override) ist NICHT dabei.
      assert Map.keys(by_id) |> Enum.sort() == ["b_gap", "b_kur"]

      # Roh→Geglättet (Nachtrag 2): der Roh-Text der Quell-Utterances reist
      # mit (Diff-Anzeige); ohne auffindbare Utterances nil (Fallback).
      assert by_id["b_gap"]["roh_text"] == "wir sollten ähm so unserem Ziel"
      assert by_id["b_kur"]["roh_text"] == nil

      # Gemma-Fill ist auf den Block-Text angewandt (K3: das Hub-UI bestätigt
      # exakt diesen Text).
      assert by_id["b_gap"]["vorschlag_text"] == "wir sollten so zu unserem Ziel"
      assert by_id["b_gap"]["vorschlag_modell"] == "gemma-test"
      assert by_id["b_gap"]["override"] == nil

      assert by_id["b_kur"]["override"]["status"] == "bestaetigt"
      assert by_id["b_kur"]["override"]["set_by"] == "member-1"

      assert [verwaist] = entry["verwaist"]
      assert verwaist["bestaetigter_text"] == "alt"
    end

    test "Session ohne Smoothing-Snapshot taucht nicht auf; override_count zählt" do
      assert Repo.luecken_review_for_campaign("camp-ohne-smoothing") == []
      assert Repo.luecken_override_count() == 2
    end
  end

  # ── Block-Spalte (#871) ───────────────────────────────────────────────────

  describe "smoothed_for_campaign (Block-Spalte)" do
    setup do
      Materializer.apply_event(event("CampaignCreated", %{"id" => @cid, "name" => "C"}, 1))

      Materializer.apply_event(
        event(
          "SessionScheduled",
          %{"id" => @sid, "campaign_id" => @cid, "number" => 3, "name" => "S3"},
          2
        )
      )

      blocks = [
        Map.put(block("b_gap", "wir sollten so unserem Ziel", ["u1"]), "hat_luecke", true),
        block("b_unbrauchbar", "Kauderwelsch", ["u2"]),
        block("b_clean", "Alles klar", ["u3"])
      ]

      Materializer.apply_event(
        event(
          "TranscriptSmoothed",
          %{
            "session_id" => @sid,
            "campaign_id" => @cid,
            "smoothed_at" => "2026-07-16T10:00:00Z",
            "blocks" => blocks,
            "ooc_verworfen" => ["u9", "u10"],
            "rules_version" => 42,
            "merge_gap_seconds" => 8
          },
          3,
          event_id: "sm-1"
        )
      )

      Materializer.apply_event(
        vorschlag_event("b_gap",
          seq: 4,
          event_id: "lv-1",
          original: "so unserem",
          vorschlag: "so zu unserem"
        )
      )

      Materializer.apply_event(
        kuration_event("b_unbrauchbar",
          seq: 5,
          event_id: "lk-1",
          status: "unbrauchbar",
          quell: ["u2"],
          text: nil
        )
      )

      :ok
    end

    test "effektive Texte + Badges + Session-Kopf-Metadaten" do
      assert [sm] = Repo.smoothed_for_campaign(@cid)
      assert sm["session_id"] == @sid
      assert sm["session_number"] == 3
      assert sm["rules_version"] == 42
      assert sm["ooc_verworfen_count"] == 2
      assert sm["hidden_count"] == 0

      by_id = Map.new(sm["blocks"], &{&1["block_id"], &1})

      # Vorschlag fließt in den effektiven Text ein (dieselbe eine Text-Funktion).
      assert by_id["b_gap"]["text"] == "wir sollten so zu unserem Ziel"
      assert by_id["b_gap"]["hat_luecke"] == true
      assert by_id["b_gap"]["status"] == nil

      # unbrauchbar bleibt SICHTBAR (F5-Audit), mit Status fürs Badge.
      assert by_id["b_unbrauchbar"]["status"] == "unbrauchbar"
      assert by_id["b_unbrauchbar"]["text"] == "Kauderwelsch"

      assert by_id["b_clean"]["status"] == nil
      assert by_id["b_clean"]["hat_luecke"] == false
    end

    test "Session ohne Smoothing fehlt; Cap macht den Schnitt sichtbar statt still" do
      assert Repo.smoothed_for_campaign("camp-ohne-glaettung") == []

      # 250 Blöcke → letzte 200 + hidden_count 50.
      many =
        for i <- 1..250 do
          block("b_#{String.pad_leading("#{i}", 3, "0")}", "Text #{i}", ["u#{i}"])
        end

      Materializer.apply_event(
        event(
          "TranscriptSmoothed",
          %{
            "session_id" => @sid,
            "campaign_id" => @cid,
            "smoothed_at" => "2026-07-16T11:00:00Z",
            "blocks" => many,
            "ooc_verworfen" => [],
            "rules_version" => 42,
            "merge_gap_seconds" => 8
          },
          6,
          event_id: "sm-2"
        )
      )

      assert [sm] = Repo.smoothed_for_campaign(@cid)
      assert length(sm["blocks"]) == 200
      assert sm["hidden_count"] == 50
      assert hd(sm["blocks"])["block_id"] == "b_051"
    end
  end

  # ── ANY-Klemme (E3) ───────────────────────────────────────────────────────

  describe "Verify.apply_gap_clamp/2 (ANY-Quantor)" do
    test "EIN geklemmter Block in source_refs reicht → verified? false + gap_geklemmt" do
      facts = [
        %{
          "id" => "f1",
          "claim" => "A",
          "source_refs" => ["b_clean", "b_gap"],
          "verified?" => true
        },
        %{"id" => "f2", "claim" => "B", "source_refs" => ["b_clean"], "verified?" => true}
      ]

      [f1, f2] = Verify.apply_gap_clamp(facts, MapSet.new(["b_gap"]))

      assert f1["verified?"] == false
      assert f1["gap_geklemmt"] == true
      assert f2["verified?"] == true
      refute Map.has_key?(f2, "gap_geklemmt")
    end

    test "nil / leere Klemm-Menge → Fakten unverändert" do
      facts = [%{"id" => "f1", "source_refs" => ["b_gap"], "verified?" => true}]
      assert Verify.apply_gap_clamp(facts, nil) == facts
      assert Verify.apply_gap_clamp(facts, MapSet.new()) == facts
    end
  end

  # ── Klemm-Menge + F5-Oberfläche (Smoothing-Adapter) ───────────────────────

  describe "Smoothing.clamp_block_ids/2 + to_context/3 (F5)" do
    test "hat_luecke ohne kuratierenden Override → geklemmt; Kuration löst die Klemme" do
      blocks = [
        block("b_gap", "T1", ["u1"], hat_luecke: true),
        block("b_kuratiert", "T2", ["u2"], hat_luecke: true),
        block("b_clean", "T3", ["u3"])
      ]

      overrides = %{
        "b_kuratiert" => %{"status" => "bestaetigt", "bestaetigter_text" => "T2 fix"}
      }

      clamp = Smoothing.clamp_block_ids(blocks, overrides)
      assert MapSet.member?(clamp, "b_gap")
      refute MapSet.member?(clamp, "b_kuratiert")
      refute MapSet.member?(clamp, "b_clean")
    end

    test "unbrauchbar ist KEINE Kuration im Klemm-Sinn — aber F5 nimmt den Block aus der Oberfläche" do
      blocks = [
        block("b_kaputt", "Nichts zu retten", ["u1"], hat_luecke: true),
        block("b_clean", "T", ["u2"])
      ]

      overrides = %{"b_kaputt" => %{"status" => "unbrauchbar", "bestaetigter_text" => nil}}

      # Klemm-Menge: unbrauchbar kuratiert nichts.
      assert MapSet.member?(Smoothing.clamp_block_ids(blocks, overrides), "b_kaputt")

      # F5: der Block fehlt in der Extraktions-Oberfläche komplett.
      ctx = Smoothing.to_context(blocks, %{}, overrides)
      assert Enum.map(ctx, & &1.id) == ["b_clean"]
    end

    test "Kurations-Override bestimmt den effektiven Kontext-Text (Einmal-Resolve)" do
      blocks = [block("b_1", "wir sollten so unserem Ziel", ["u1"], hat_luecke: true)]

      vorschlaege = %{
        "b_1" => %{"original" => "so unserem", "vorschlag" => "so zu unserem"}
      }

      overrides = %{
        "b_1" => %{"status" => "manuell_korrigiert", "bestaetigter_text" => "wir folgen dem Ziel"}
      }

      # Override schlägt Vorschlag schlägt Smoothed-Text.
      assert [%{text: "wir folgen dem Ziel"}] =
               Smoothing.to_context(blocks, vorschlaege, overrides)

      assert [%{text: "wir sollten so zu unserem Ziel"}] =
               Smoothing.to_context(blocks, vorschlaege, %{})

      assert [%{text: "wir sollten so unserem Ziel"}] = Smoothing.to_context(blocks, %{}, %{})
    end
  end
end
