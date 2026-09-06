defmodule Worker.GapFillTest do
  @moduledoc """
  Issue #865 (K2) / #924: deterministische Pfade der Gap-Fill-Generierung —
  Kandidaten-Auswahl (`generate_now`: nur uncurierte Lücken-Blöcke ohne
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

  describe "generate_now/5 — Kandidaten-Auswahl (keine Generierung → Map unverändert)" do
    # Ohne Kandidaten/Modell läuft KEIN LLM-Call → generate_now gibt die
    # Eingabe-Vorschlags-Map unverändert zurück (kein Fake-Backend nötig).
    test "keine Lücken-Blöcke → Map unverändert" do
      blocks = [block("b_1", hat_luecke: false)]
      assert GapFill.generate_now("s1", "c1", blocks, %{}, %{}) == %{}
    end

    test "Block mit existierendem Vorschlag ist KEIN Kandidat (idempotent, K2)" do
      blocks = [block("b_1")]
      vorschlaege = %{"b_1" => %{"vorschlag" => "…"}}
      assert GapFill.generate_now("s1", "c1", blocks, vorschlaege, %{}) == vorschlaege
    end

    test "kuratierter Block ist KEIN Kandidat (Mensch hat entschieden)" do
      blocks = [block("b_1")]
      overrides = %{"b_1" => %{"status" => "bestaetigt"}}
      assert GapFill.generate_now("s1", "c1", blocks, %{}, overrides) == %{}
    end

    test "Kandidat vorhanden, aber kein :gapfill_model konfiguriert → Feature aus (Map unverändert)" do
      blocks = [block("b_1")]
      assert GapFill.generate_now("s1", "c1", blocks, %{}, %{}) == %{}
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

  # Issue #874 (Nachtrag): Gap-Fill-eigene Ollama-Lauf-Optionen. Vorher war
  # der Endpoint hart :generate — ein Reasoning-Modell als gapfill_model
  # (gpt-oss) lief damit IMMER in :parse_failed.
  describe "llm_opts/1 — gapfill_local_endpoint + gapfill_think" do
    setup do
      keys = [:gapfill_local_endpoint, :gapfill_think]
      before = Enum.into(keys, %{}, fn k -> {k, Worker.Settings.get(k)} end)

      on_exit(fn ->
        Enum.each(keys, fn k ->
          case before[k] do
            nil -> :ok
            v -> Worker.Settings.put(k, v)
          end
        end)
      end)

      :ok
    end

    test "H: Defaults = :generate + :auto (bisheriges Verhalten)" do
      Worker.Settings.put(:gapfill_local_endpoint, :generate)
      Worker.Settings.put(:gapfill_think, :auto)

      opts = GapFill.llm_opts("gemma3n:e4b")
      assert opts[:endpoint] == :generate
      assert opts[:think] == :auto
      assert opts[:model] == "gemma3n:e4b"
      assert opts[:stage] == :summary
    end

    test "H: chat + medium für Reasoning-Modelle — Atom UND String (UI-Form-Shape)" do
      Worker.Settings.put(:gapfill_local_endpoint, :chat)
      Worker.Settings.put(:gapfill_think, :medium)
      opts = GapFill.llm_opts("gpt-oss:20b")
      assert opts[:endpoint] == :chat
      assert opts[:think] == :medium

      Worker.Settings.put(:gapfill_local_endpoint, "chat")
      Worker.Settings.put(:gapfill_think, "high")
      opts = GapFill.llm_opts("gpt-oss:20b")
      assert opts[:endpoint] == :chat
      assert opts[:think] == "high"
    end

    test "F/N: Garbage-Werte fallen auf :generate/:auto zurück (defensiv)" do
      Worker.Settings.put(:gapfill_local_endpoint, "bogus")
      Worker.Settings.put(:gapfill_think, :nonsense)

      opts = GapFill.llm_opts("gemma3n:e4b")
      assert opts[:endpoint] == :generate
      assert opts[:think] == :auto
    end
  end

  # Issue #1135: Gap-Fill war der EINZIGE LLM-Aufrufer im Repo ohne `num_ctx`
  # und bekam damit ollamas Servervorgabe statt einer Einstellung. Der Defekt
  # ist eine ABWESENHEIT — er wird nicht rot, er wird still teuer (eine
  # serverweite `OLLAMA_CONTEXT_LENGTH=98304` hob die Karte während der
  # längsten Stufe von 76 % auf 93 %). Genau deshalb prüft der erste Test die
  # Anwesenheit des Schlüssels getrennt vom Wert: fiele die Zeile bei einem
  # späteren Umbau weg, bliebe der Wert-Test auf einem `nil` sitzen, ohne dass
  # jemand die Ursache sieht.
  describe "llm_opts/1 — Kontextfenster (#1135)" do
    setup do
      before = Worker.Settings.get(:ctx_gapfill)
      on_exit(fn -> if before, do: Worker.Settings.put(:ctx_gapfill, before) end)
      :ok
    end

    test "H: num_ctx ist überhaupt gesetzt — der Kern des Defekts" do
      opts = GapFill.llm_opts("gemma3n:e4b")

      assert Keyword.has_key?(opts, :num_ctx),
             "ohne num_ctx entscheidet ollamas Servervorgabe über diese Stufe (#1135)"
    end

    test "H: der eingestellte Wert kommt an" do
      Worker.Settings.put(:ctx_gapfill, 16_384)
      assert GapFill.llm_opts("gemma3n:e4b")[:num_ctx] == 16_384
    end

    test "H: Default 8192 deckt den längsten gemessenen Block" do
      # Über alle 6499 Blöcke des Bestands (2026-09-06): längster 5478 Bytes
      # ≈ 1826 Token, Median 43, keiner über 2000. Der Vorschlag formuliert den
      # ganzen Block neu, ist also etwa eingabegroß — Eingabe + Ausgabe +
      # Prompt-Rahmen liegen damit grob bei 4000-4500. Eine Denkphase fällt
      # bei `gapfill_think: :auto` nicht an (`think_payload(:auto, true)` ist
      # `false`); wer auf medium/high dreht, braucht mehr und findet den
      # Hinweis am Feld in /settings.
      assert Worker.Settings.defaults()[:ctx_gapfill] == 8192
    end

    test "N: der Rückfallwert im Aufrufer driftet nicht vom Default ab" do
      # `llm_opts/1` ruft `Settings.get(:ctx_gapfill, 8192)`. Stünde dort eine
      # andere Zahl als in `@settings`, entschiede die Reihenfolge — Map-Default
      # bei gefülltem Store, Code-Fallback bei leerem. Zwei Zahlen für eine
      # Einstellung sind genau die stille Sorte Fehler, die dieses Ticket
      # überhaupt erst nötig gemacht hat.
      quelle = File.read!("lib/worker/recording/pipeline/gap_fill.ex")

      [_, im_code] = Regex.run(~r/Settings\.get\(:ctx_gapfill,\s*(\d[\d_]*)\)/, quelle)

      assert String.to_integer(String.replace(im_code, "_", "")) ==
               Worker.Settings.defaults()[:ctx_gapfill]
    end
  end
end
