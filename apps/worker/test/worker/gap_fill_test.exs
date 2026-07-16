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

  describe "validate/2 — Verflüssigungs-Fehlerpfade" do
    @text "Lotta Lucky Kupfer. Ist ein Mensch ein Straßensamurai? Aber Nicht. Freiwillig, sozusagen."

    test "gültige Verflüssigung → {:ok, ganzer Block-Text als original, Vorschlag}" do
      v =
        "Lotta (Lucky) Kupfer ist ein Mensch und Straßensamurai — allerdings nicht freiwillig, sozusagen."

      assert GapFill.validate(@text, v) == {:ok, @text, v}
    end

    test "kosmetische Edits (nur Interpunktion/Case) sind KEINE Verflüssigung → :skip" do
      # Real-Befund Free Seattle: das 7b umging den Gleichheits-Skip mit
      # Komma-/Großschreibungs-Tweaks → Panel voll Rausch-Vorschläge.
      assert GapFill.validate(
               "die waren auch noch länger die waren",
               "die waren auch noch länger, die waren"
             ) ==
               :skip

      assert GapFill.validate("aufzulösen. Ja. Die", "aufzulösen, Ja. die") == :skip
    end

    test "identischer Text → :skip" do
      assert GapFill.validate(@text, @text) == :skip
    end

    test "Fabulier-Deckel: massiv längerer oder eingedampfter Vorschlag → :laengen_drift" do
      lang = String.duplicate("Und dann passierte noch etwas völlig Neues. ", 20)
      assert GapFill.validate(@text, lang) == {:error, :laengen_drift}
      assert GapFill.validate(@text, "Lotta.") == {:error, :laengen_drift}
    end

    test "leerer Vorschlag" do
      assert GapFill.validate(@text, "") == {:error, :empty_vorschlag}
      assert GapFill.validate(@text, nil) == {:error, :empty_vorschlag}
      assert GapFill.validate(@text, "   ") == {:error, :empty_vorschlag}
    end
  end
end
