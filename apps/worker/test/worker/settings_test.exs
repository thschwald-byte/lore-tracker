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
    test "backend_stage4/5 defaulten auf :local" do
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

    test "J4 (#1207): die Keys der alten Extraktion und von Stufe 3 sind weder Default noch Whitelist" do
      for key <- [
            :backend_stage2,
            :model_stage2_anthropic,
            :model_stage2_openai,
            :model_stage2_google,
            :model_stage2_local_endpoint,
            :model_stage2_think,
            :ctx_stage2,
            :temperature_stage2,
            :top_p_stage2,
            :repeat_penalty_stage2,
            :extract_num_predict_cap,
            :extract_chunk_tokens,
            :backend_stage3,
            :model_stage3_local,
            :model_stage3_local_endpoint,
            :model_stage3_think,
            :model_stage3_anthropic,
            :model_stage3_openai,
            :model_stage3_google,
            :ctx_stage3,
            :temperature_stage3,
            :top_p_stage3,
            :repeat_penalty_stage3,
            :num_predict_stage3,
            :grounding_context_window
          ] do
        refute Map.has_key?(Settings.defaults(), key), "#{key} hat noch einen Default"
        refute MapSet.member?(Settings.known_keys(), key), "#{key} steht noch in der Whitelist"
      end
    end

    test "J4 (#1207): Jacks Modell und der Endpunkt bleiben schreibbar (ohne Default)" do
      for key <- [:model_stage2_local, :local_endpoint] do
        assert MapSet.member?(Settings.known_keys(), key)
        refute Map.has_key?(Settings.defaults(), key)
      end
    end

    test "J4 (#1207): Jacks Regler defaulten exakt auf die Werte der Messreihe C" do
      # Gegen die Quelle geprüft, nicht gegen abgeschriebene Zahlen: laufen
      # die Defaults und `modell_reihe_c/1` auseinander, änderte sich Jacks
      # Verhalten im Betrieb ohne jeden Eingriff.
      {_, reihe_c} = Worker.Jack.Messlauf.modell_reihe_c(endpunkt: "http://x:1")

      assert Settings.get(:jack_temperature) == reihe_c[:temperatur]
      assert Settings.get(:jack_max_tokens) == reihe_c[:max_ausgabe]
      assert Settings.get(:jack_top_p) == reihe_c[:extra]["top_p"]
      assert Settings.get(:jack_frequency_penalty) == reihe_c[:extra]["frequency_penalty"]

      assert Settings.get(:jack_temperature) == 0.7
      assert Settings.get(:jack_top_p) == 0.8
      assert Settings.get(:jack_frequency_penalty) == 0.4
      assert Settings.get(:jack_max_tokens) == 60_000
      assert Settings.get(:ctx_jack) == 98_304

      for key <- [
            :jack_temperature,
            :jack_top_p,
            :jack_frequency_penalty,
            :jack_max_tokens,
            :ctx_jack
          ] do
        assert MapSet.member?(Settings.known_keys(), key)
      end
    end

    test "#783 Phase 2: backend_stage4 + model_stage4_<backend> existieren (Render eigener Slot)" do
      for key <- [:backend_stage4, :model_stage4_local, :model_stage4_anthropic, :ctx_stage4] do
        assert MapSet.member?(Settings.known_keys(), key)
      end

      assert Settings.get(:ctx_stage4) == 8192
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
      # ctx_stage4 hat einen echten Default (kein :no_default) — anders als die
      # entfernten Legacy-Modell-Keys.
      assert Settings.get(:ctx_stage4) == 8192
      :ok = Settings.put(:ctx_stage4, 4096)
      assert Settings.get(:ctx_stage4) == 4096
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
      :ok = Settings.put(:ctx_jack, 32_768)
      assert Settings.source(:ctx_jack) == :store
    end

    test ":default wenn echter Default, nicht persistiert" do
      assert Settings.source(:ctx_jack) == :default
    end

    test ":unset für einen :no_default-Key ohne persistierten Wert" do
      assert Settings.source(:whisper_bin) == :unset
      assert Settings.source(:model_stage2_local) == :unset
    end
  end

  describe "model_for/2 — pro-Backend-Auflösung (#451 Track C, #784 Legacy raus)" do
    test "frische Installation: local ohne Config → nil (fail-loud statt Phantom-Default)" do
      assert Settings.model_for(2, :local) == nil
      assert Settings.model_for(4, :local) == nil
    end

    test "persistierter pro-Backend-Key gewinnt" do
      :ok = Settings.put(:model_stage2_local, "per-backend-modell")
      assert Settings.model_for(2, :local) == "per-backend-modell"
      assert Settings.model_for(2, "local") == "per-backend-modell"
    end

    test "J4 (#1207): Stufe 2 ist nur lokal — ein Cloud-Backend ist ein Fehler, kein stilles nil" do
      for backend <- [:anthropic, :openai, :google, "anthropic"] do
        assert_raise FunctionClauseError, fn -> Settings.model_for(2, backend) end
        assert_raise FunctionClauseError, fn -> Settings.model_key(2, backend) end
      end
    end

    test "J4 (#1207): Stufe 3 gibt es nicht mehr" do
      assert_raise FunctionClauseError, fn -> Settings.model_for(3, :local) end
      assert_raise FunctionClauseError, fn -> Settings.model_key(3, :local) end
    end

    test "Cloud-Backend ohne Config → nil (kein Legacy-Fallback auf lokalen Modellnamen)" do
      assert Settings.model_for(4, :anthropic) == nil
      assert Settings.model_for(4, :openai) == nil
      assert Settings.model_for(5, :google) == nil
    end

    test "Cloud-Backend mit gesetztem pro-Backend-Key; andere Backends bleiben nil" do
      :ok = Settings.put(:model_stage4_google, "gemini-2.5-flash")
      assert Settings.model_for(4, :google) == "gemini-2.5-flash"
      assert Settings.model_for(4, :anthropic) == nil
    end

    test "String-Backend wird normalisiert; leerer pro-Backend-Wert zählt als ungesetzt" do
      :ok = Settings.put(:model_stage4_openai, "")
      assert Settings.model_for(4, "openai") == nil

      :ok = Settings.put(:model_stage2_local, "  ")
      assert Settings.model_for(2, :local) == nil
    end

    test "unbekanntes Backend → nil" do
      assert Settings.model_for(4, :bundled) == nil
    end
  end

  describe "model_key/2 — gewinnender Schreib-Key (#451 Track C, #784)" do
    test "bekanntes Backend → pro-Backend-Key (atom + string)" do
      assert Settings.model_key(2, :local) == :model_stage2_local
      assert Settings.model_key(4, "google") == :model_stage4_google
      assert Settings.model_key(5, :anthropic) == :model_stage5_anthropic
    end

    test "unbekanntes/nil-Backend → Local-Key (sicherer Default statt Legacy)" do
      assert Settings.model_key(4, :bundled) == :model_stage4_local
      assert Settings.model_key(4, nil) == :model_stage4_local
      assert Settings.model_key(5, :bundled) == :model_stage5_local
    end
  end

  describe "model_for/2 — kein Cross-Stage-Bleed (#783 Phase 2)" do
    test "n=2/4/5 lösen unabhängig voneinander auf" do
      :ok = Settings.put(:model_stage2_local, "jack-modell")
      :ok = Settings.put(:model_stage4_local, "resumee-modell")
      :ok = Settings.put(:model_stage5_local, "epos-modell")

      assert Settings.model_for(2, :local) == "jack-modell"
      assert Settings.model_for(4, :local) == "resumee-modell"
      assert Settings.model_for(5, :local) == "epos-modell"
    end
  end
end
