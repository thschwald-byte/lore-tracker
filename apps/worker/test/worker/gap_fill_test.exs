defmodule Worker.GapFillTest do
  @moduledoc """
  Issue #865 (K2): deterministische Pfade der Gap-Fill-Generierung —
  Kandidaten-Auswahl (`maybe_enqueue`: nur uncurierte Lücken-Blöcke ohne
  existierenden Vorschlag; kein Modell = Feature aus) + Vorschlags-Validierung
  (Fehlerpfade: leere Felder, Original nicht im Block, No-Change = :skip).
  Der eigentliche LLM-Call ist nicht Teil dieser Suite (kein Fake-Backend).
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Recording.Pipeline.GapFill

  setup do
    reset_for_permutation!()
    :ok
  end

  defp block(id, opts \\ []) do
    %{
      "id" => id,
      "text" => Keyword.get(opts, :text, "wir sollten so unserem Ziel"),
      "hat_luecke" => Keyword.get(opts, :hat_luecke, true),
      "quell_utterance_ids" => ["u1"]
    }
  end

  describe "maybe_enqueue/5 — Kandidaten-Auswahl" do
    test "keine Lücken-Blöcke → :no_candidates" do
      blocks = [block("b_1", hat_luecke: false)]
      assert GapFill.maybe_enqueue("s1", "c1", blocks, %{}, %{}) == :no_candidates
    end

    test "Block mit existierendem Vorschlag ist KEIN Kandidat (idempotent, K2)" do
      blocks = [block("b_1")]
      vorschlaege = %{"b_1" => %{"vorschlag" => "…"}}
      assert GapFill.maybe_enqueue("s1", "c1", blocks, vorschlaege, %{}) == :no_candidates
    end

    test "kuratierter Block ist KEIN Kandidat (Mensch hat entschieden)" do
      blocks = [block("b_1")]
      overrides = %{"b_1" => %{"status" => "bestaetigt"}}
      assert GapFill.maybe_enqueue("s1", "c1", blocks, %{}, overrides) == :no_candidates
    end

    test "Kandidat vorhanden, aber kein :gapfill_model konfiguriert → :no_model (Feature aus)" do
      blocks = [block("b_1")]
      assert GapFill.maybe_enqueue("s1", "c1", blocks, %{}, %{}) == :no_model
    end
  end

  describe "validate/3 — Vorschlags-Fehlerpfade" do
    @text "wir sollten so unserem Ziel folgen"

    test "gültiger minimaler Fill" do
      assert GapFill.validate(@text, "so unserem", "so zu unserem") ==
               {:ok, "so unserem", "so zu unserem"}
    end

    test "original == vorschlag ist der legitime Keine-Lücke-Ausweg → :skip" do
      assert GapFill.validate(@text, "so unserem", "so unserem") == :skip
    end

    test "kosmetische Edits (nur Interpunktion/Case) sind KEINE Lücken-Füllung → :skip" do
      # Real-Befund Free Seattle (2026-07-16): das 7b umging den exakten
      # Gleichheits-Skip mit Komma-/Großschreibungs-Tweaks und flutete das
      # Panel mit Rausch-Vorschlägen. Die drei Screenshot-Fälle:
      t1 = "Cradstick, also wie Stöcke. die waren auch noch länger die waren"

      assert GapFill.validate(
               t1,
               "die waren auch noch länger die waren",
               "die waren auch noch länger, die waren"
             ) ==
               :skip

      t2 = "die Gesetze so ein bisschen sich aufzulösen. Ja. Die Ortssicherheit"
      assert GapFill.validate(t2, "aufzulösen. Ja. Die", "aufzulösen, Ja. Die") == :skip

      t3 = "wo wir uns treffen. Da ist ein Parkblast"
      assert GapFill.validate(t3, "treffen. Da ist", "treffen. da ist") == :skip
    end

    test "echte Wort-Ergänzung bleibt gültig (kredit-sticks-Fall)" do
      t = "Deswegen kred sticks. also wie Stöcke"

      assert GapFill.validate(t, "kred sticks.", "kredit sticks.") ==
               {:ok, "kred sticks.", "kredit sticks."}
    end

    test "Original kommt nicht im Block vor → mechanisch nicht anwendbar" do
      assert GapFill.validate(@text, "gibt es nicht", "gibt es doch") ==
               {:error, :original_not_in_block}
    end

    test "leere Felder" do
      assert GapFill.validate(@text, "", "x") == {:error, :empty_original}
      assert GapFill.validate(@text, "so", "") == {:error, :empty_vorschlag}
      assert GapFill.validate(@text, nil, "x") == {:error, :empty_original}
    end
  end
end
