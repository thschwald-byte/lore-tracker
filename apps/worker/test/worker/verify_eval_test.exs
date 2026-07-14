defmodule Worker.VerifyEvalTest do
  @moduledoc """
  Korrektheits-Anker für `Worker.VerifyEval` (Epic #854 Slice 1).

  Die zentrale Disziplin (#557): `mix lore.eval.verify` gegen den Sweep
  gegenzuprüfen beweist nur, dass beide dasselbe Modul aufrufen — NICHT dass es
  richtig rechnet. Der Beweis kommt aus **Stub-Judges**: ein injizierter
  `ground_fn`/`attr_fn`, dessen Verhalten wir kennen, muss exakt vorhersagbare
  TPR/FPR liefern. Kommt etwas Mittleres raus, misst der Harness sich selbst.

  Reine, deterministische Tests — kein Ollama, kein Sidecar.
  """
  use ExUnit.Case, async: true

  alias Worker.VerifyEval

  # Minimaler kuratierter Satz: 2 Positive, 2 Decoys, alle mit refs + Figur
  # (sonst wäre attributed? #762-vakuum-true und die Achse ungetestet).
  defp positives do
    [
      %{
        "claim" => "Der König beauftragt Holmes.",
        "source_refs" => ["u1"],
        "character_alias" => "König",
        "entity_id" => "könig"
      },
      %{
        "claim" => "Norton heiratet Irene.",
        "source_refs" => ["u2"],
        "character_alias" => "Norton",
        "entity_id" => "norton"
      }
    ]
  end

  defp decoys do
    [
      %{
        "claim" => "Holmes erschießt jemanden.",
        "source_refs" => ["u1"],
        "character_alias" => "Holmes",
        "entity_id" => "holmes"
      },
      %{
        "claim" => "Der König heiratet Irene.",
        "source_refs" => ["u2"],
        "character_alias" => "König",
        "entity_id" => "könig"
      }
    ]
  end

  defp utts do
    [
      %{"id" => "u1", "text" => "Der König bittet Holmes um Hilfe.", "discord_id" => "1"},
      %{"id" => "u2", "text" => "Norton und Irene heiraten in der Kirche.", "discord_id" => "1"}
    ]
  end

  defp always(bool), do: fn _fact, _utts -> bool end
  defp always3(bool), do: fn _fact, _utts, _aliases -> bool end

  describe "score/4 — Stub-Judges (der Korrektheits-Beweis)" do
    test "immer-true-Judge (beide Achsen) → TPR=1, FPR=1 (Plumbing: alles verified?)" do
      r =
        VerifyEval.score(positives(), decoys(), utts(),
          ground_fn: always(true),
          attr_fn: always3(true)
        )

      assert r.tpr == 1.0
      assert r.fpr == 1.0
      assert r.positives.grounded_rate == 1.0
      assert r.positives.attributed_rate == 1.0
      assert r.decoys.grounded_rate == 1.0
    end

    test "immer-false-Grounding → TPR=0, FPR=0 (nichts geerdet → nichts verified)" do
      r =
        VerifyEval.score(positives(), decoys(), utts(),
          ground_fn: always(false),
          attr_fn: always3(true)
        )

      assert r.tpr == 0.0
      assert r.fpr == 0.0
      assert r.positives.grounded_rate == 0.0
    end

    test "geerdet aber NICHT attribuiert → verified?=false, Achsen getrennt sichtbar (#762)" do
      # Genau der Fall, der ohne getrennte Ausweisung unsichtbar wäre: grounded
      # zieht durch, attribution killt verified?. grounded_rate=1, attributed_rate=0.
      r =
        VerifyEval.score(positives(), decoys(), utts(),
          ground_fn: always(true),
          attr_fn: always3(false)
        )

      assert r.tpr == 0.0
      assert r.fpr == 0.0
      assert r.positives.grounded_rate == 1.0
      assert r.positives.attributed_rate == 0.0
    end

    test "gemischter Judge → korrekte Aufteilung nach Label (Positive verified, Decoy nicht)" do
      # ground_fn erdet nur Claims, die 'beauftragt' oder 'Norton heiratet' enthalten
      # (die zwei Positive), lehnt die zwei Decoys ab.
      good = MapSet.new(["Der König beauftragt Holmes.", "Norton heiratet Irene."])
      gfn = fn fact, _ -> MapSet.member?(good, fact["claim"]) end

      r = VerifyEval.score(positives(), decoys(), utts(), ground_fn: gfn, attr_fn: always3(true))

      assert r.tpr == 1.0
      assert r.fpr == 0.0
    end

    test "interner Label-Key leakt NICHT in die Ausgabe-Verdikte" do
      r =
        VerifyEval.score(positives(), decoys(), utts(),
          ground_fn: always(true),
          attr_fn: always3(true)
        )

      Enum.each(r.positives.verdicts ++ r.decoys.verdicts, fn v ->
        refute Map.has_key?(v, "__verifyeval_label__")
        # Die Verify-Flags müssen dran sein.
        assert Map.has_key?(v, "verified?")
      end)
    end

    test "leere Seiten → 0.0 (kein Div-by-Zero)" do
      r = VerifyEval.score([], [], utts(), ground_fn: always(true), attr_fn: always3(true))
      assert r.tpr == 0.0
      assert r.fpr == 0.0
    end
  end

  describe "pure Helfer (aus eval_verify gehoben)" do
    test "best_match_refs/2 wählt die refs des höchsten Wort-Overlaps" do
      facts = [
        %{"claim" => "Norton heiratet Irene in der Kirche", "source_refs" => ["ref-hochzeit"]},
        %{"claim" => "Holmes deduziert Watsons Praxis", "source_refs" => ["ref-deduktion"]}
      ]

      # Decoy über die Hochzeit → matcht den Hochzeits-Fakt.
      assert VerifyEval.best_match_refs("Der König heiratet Irene", facts) == ["ref-hochzeit"]
    end

    test "best_match_refs/2: bei nicht-leerer Fakt-Liste immer refs (auch Overlap 0), [] nur bei leerer Liste" do
      facts = [%{"claim" => "Holmes deduziert", "source_refs" => ["r1"]}]
      # Auch bei null Overlap fällt max_by auf den (einzigen) Fakt → dessen refs.
      # Der []-Fallback greift NUR wenn gar kein Fakt da ist.
      assert VerifyEval.best_match_refs("völlig fremdes Thema xyz", facts) == ["r1"]
      assert VerifyEval.best_match_refs("egal", []) == []
    end

    test "micro/2 mittelt Σ geerdete / Σ gesamt über Sessions" do
      sessions = [
        %{v: [{%{}, true}, {%{}, false}]},
        %{v: [{%{}, true}, {%{}, true}]}
      ]

      assert VerifyEval.micro(sessions, :v) == 0.75
    end

    test "micro/2 auf leerer Menge → 0.0" do
      assert VerifyEval.micro([%{v: []}], :v) == 0.0
    end
  end
end
