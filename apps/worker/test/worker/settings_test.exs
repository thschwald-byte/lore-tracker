defmodule Worker.SettingsTest do
  @moduledoc """
  Default value + round-trip tests for `Worker.Settings`. Uses Mnesia
  (bootstrapped by test_helper); not async to avoid cross-test stomping
  on the singleton worker_state table.
  """

  use ExUnit.Case, async: false

  alias Worker.Settings

  setup do
    # Wipe the worker_state table so each test sees @defaults only.
    {:atomic, :ok} = :mnesia.clear_table(Worker.Schema.Mnesia.worker_state())
    :ok
  end

  describe "defaults" do
    test "backend_stage2/3/4/5 defaulten auf :local" do
      assert Settings.get(:backend_stage2) == :local
      assert Settings.get(:backend_stage3) == :local
      assert Settings.get(:backend_stage4) == :local
      assert Settings.get(:backend_stage5) == :local
    end

    test "#783 Phase 2: judge_model + render_model (Phase 1) sind komplett entfernt" do
      for key <- [:judge_model, :render_model] do
        refute MapSet.member?(Settings.known_keys(), key)
      end
    end

    test "#786: die Chain-only-Keys (pipeline_mode, format_corrector, …) bleiben komplett raus" do
      for key <- [
            :pipeline_mode,
            :stage2_chunk_tokens,
            :num_predict_stage2,
            :pipeline_max_format_retries,
            :format_corrector_window_size,
            :temperature_min_stage2
          ] do
        refute Map.has_key?(Settings.defaults(), key)
        refute MapSet.member?(Settings.known_keys(), key)
      end
    end

    test "#783 Phase 2: backend_stage3/4 + model_stage3/4_<backend> existieren jetzt (Verify/Render eigene Slots)" do
      assert Settings.get(:backend_stage3) == :local
      assert Settings.get(:backend_stage4) == :local

      for key <- [
            :backend_stage3,
            :backend_stage4,
            :model_stage3_local,
            :model_stage4_anthropic,
            :ctx_stage3,
            :ctx_stage4,
            :temperature_stage3,
            :temperature_stage4
          ] do
        assert MapSet.member?(Settings.known_keys(), key)
      end

      assert Settings.get(:ctx_stage3) == 8192
      assert Settings.get(:ctx_stage4) == 8192
      assert Settings.get(:model_stage3_local) == nil
      assert Settings.get(:model_stage4_anthropic) == nil
    end

    test "#783 Phase 2 (Nachtrag): backend_stage5 + model_stage5_<backend> existieren (Epos eigener Slot, getrennt von Resümee/Stage 4)" do
      assert Settings.get(:backend_stage5) == :local

      for key <- [
            :backend_stage5,
            :model_stage5_local,
            :model_stage5_anthropic,
            :ctx_stage5,
            :temperature_stage5
          ] do
        assert MapSet.member?(Settings.known_keys(), key)
      end

      assert Settings.get(:ctx_stage5) == 8192
      assert Settings.get(:model_stage5_local) == nil
    end
  end

  describe "put/get round-trip" do
    test "put overrides default" do
      # ctx_stage2 hat einen echten Default (kein :no_default) — anders als die
      # entfernten Legacy-Modell-Keys.
      assert Settings.get(:ctx_stage2) == 8192
      :ok = Settings.put(:ctx_stage2, 4096)
      assert Settings.get(:ctx_stage2) == 4096
    end

    test "get liefert nil für einen :no_default-Key ohne persistierten Wert" do
      assert Settings.get(:whisper_bin) == nil
      assert Settings.get(:ffmpeg_bin) == nil
      assert Settings.get(:local_endpoint) == nil
      assert Settings.get(:model_stage2_local) == nil
    end
  end

  describe "Whitelist-Entkopplung (#784)" do
    test "known_keys ist Obermenge der echten Default-Keys" do
      default_keys = Settings.defaults() |> Map.keys() |> MapSet.new()
      assert MapSet.subset?(default_keys, Settings.known_keys())
    end

    test ":no_default-Keys sind in known_keys (schreibbar), aber nicht in defaults" do
      for key <- [:whisper_bin, :ffmpeg_bin, :local_endpoint, :model_stage2_local] do
        assert MapSet.member?(Settings.known_keys(), key)
        refute Map.has_key?(Settings.defaults(), key)
      end
    end

    test "entfernte Legacy-Keys sind weder Default noch in der Whitelist" do
      for key <- [:model_stage2, :model_stage3, :model_stage4] do
        refute Map.has_key?(Settings.defaults(), key)
        refute MapSet.member?(Settings.known_keys(), key)
      end
    end
  end

  describe "source/1 (#784)" do
    test ":store wenn persistiert" do
      :ok = Settings.put(:ctx_stage2, 1234)
      assert Settings.source(:ctx_stage2) == :store
    end

    test ":default wenn echter Default, nicht persistiert" do
      assert Settings.source(:ctx_stage2) == :default
    end

    test ":unset für einen :no_default-Key ohne persistierten Wert" do
      assert Settings.source(:whisper_bin) == :unset
      assert Settings.source(:model_stage2_local) == :unset
    end
  end

  describe "grounding_method (Issue #677, Default-Flip #675)" do
    test "default ist :llm_judge" do
      assert Settings.get(:grounding_method) == :llm_judge
    end

    test "lässt sich auf :nli zurückstellen" do
      :ok = Settings.put(:grounding_method, :nli)
      assert Settings.get(:grounding_method) == :nli
    end
  end

  describe "model_for/2 — pro-Backend-Auflösung (#451 Track C, #784 Legacy raus)" do
    test "frische Installation: local ohne Config → nil (fail-loud statt Phantom-Default)" do
      assert Settings.model_for(2, :local) == nil
    end

    test "persistierter pro-Backend-Key gewinnt" do
      :ok = Settings.put(:model_stage2_local, "per-backend-modell")
      assert Settings.model_for(2, :local) == "per-backend-modell"
    end

    test "Cloud-Backend ohne Config → nil (kein Legacy-Fallback auf lokalen Modellnamen)" do
      assert Settings.model_for(2, :anthropic) == nil
      assert Settings.model_for(2, :openai) == nil
      assert Settings.model_for(2, :google) == nil
    end

    test "Cloud-Backend mit gesetztem pro-Backend-Key; andere Backends bleiben nil" do
      :ok = Settings.put(:model_stage2_google, "gemini-2.5-flash")
      assert Settings.model_for(2, :google) == "gemini-2.5-flash"
      assert Settings.model_for(2, :anthropic) == nil
    end

    test "String-Backend wird normalisiert; leerer pro-Backend-Wert zählt als ungesetzt" do
      :ok = Settings.put(:model_stage2_openai, "")
      assert Settings.model_for(2, "openai") == nil
    end

    test "unbekanntes Backend → nil" do
      assert Settings.model_for(2, :bundled) == nil
    end
  end

  describe "model_key/2 — gewinnender Schreib-Key (#451 Track C, #784)" do
    test "bekanntes Backend → pro-Backend-Key (atom + string)" do
      assert Settings.model_key(2, :local) == :model_stage2_local
      assert Settings.model_key(2, "google") == :model_stage2_google
    end

    test "unbekanntes/nil-Backend → Local-Key (sicherer Default statt Legacy)" do
      assert Settings.model_key(2, :bundled) == :model_stage2_local
      assert Settings.model_key(2, nil) == :model_stage2_local
    end
  end

  describe "model_for/2 + model_key/2 — Stage 3 (Verify) + Stage 4 (Render), #783 Phase 2" do
    test "n=3/4 lösen unabhängig von n=2 auf (kein Cross-Stage-Bleed)" do
      :ok = Settings.put(:model_stage2_local, "extraktor-modell")
      :ok = Settings.put(:model_stage3_local, "verify-modell")
      :ok = Settings.put(:model_stage4_local, "render-modell")

      assert Settings.model_for(2, :local) == "extraktor-modell"
      assert Settings.model_for(3, :local) == "verify-modell"
      assert Settings.model_for(4, :local) == "render-modell"
    end

    test "Cloud-Backend ohne Config → nil, für n=3 und n=4 gleichermaßen" do
      assert Settings.model_for(3, :anthropic) == nil
      assert Settings.model_for(4, :openai) == nil
    end

    test "model_key/2 baut den richtigen pro-Backend-Key für n=3/4" do
      assert Settings.model_key(3, :anthropic) == :model_stage3_anthropic
      assert Settings.model_key(4, "google") == :model_stage4_google
      assert Settings.model_key(3, :bundled) == :model_stage3_local
    end
  end

  describe "model_for/2 + model_key/2 — Stage 5 (Epos, #783 Phase 2 Nachtrag)" do
    test "n=5 löst unabhängig von n=4 (Resümee) auf — Resümee und Epos-Kapitel dürfen verschiedene Modelle haben" do
      :ok = Settings.put(:model_stage4_local, "resumee-modell")
      :ok = Settings.put(:model_stage5_local, "epos-modell")

      assert Settings.model_for(4, :local) == "resumee-modell"
      assert Settings.model_for(5, :local) == "epos-modell"
    end

    test "Cloud-Backend ohne Config → nil" do
      assert Settings.model_for(5, :anthropic) == nil
    end

    test "model_key/2 baut den richtigen pro-Backend-Key für n=5" do
      assert Settings.model_key(5, :anthropic) == :model_stage5_anthropic
      assert Settings.model_key(5, :bundled) == :model_stage5_local
    end
  end
end
