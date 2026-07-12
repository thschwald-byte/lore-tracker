defmodule HubWeb.EinstellungenLive.OptionsTest do
  @moduledoc """
  Issue #451 (Track C): die puren Options-/Normalisierungs-Helfer der
  Settings-LV (`HubWeb.EinstellungenLive.Options`) — insbesondere die
  Anzeige-Auflösung `display_model/3` (pro-Backend-Key vs. Legacy-Key)
  und die Form-Param-Normalisierung der Save-Pfade.
  """

  use ExUnit.Case, async: true

  alias HubWeb.EinstellungenLive.Options

  describe "display_model/3 — Anzeige-Modell einer Backend-Box (#784: nur pro-Backend)" do
    test "pro-Backend-Key wird angezeigt" do
      settings = %{
        "model_stage2_anthropic" => "claude-haiku-4-5",
        "backend_stage2" => "anthropic"
      }

      assert Options.display_model(settings, 2, "anthropic") == "claude-haiku-4-5"
    end

    test "kein pro-Backend-Key gesetzt → nil (Legacy-Fallback entfernt)" do
      # Ein persistierter Legacy-Key gäbe es nicht mehr im Snapshot; selbst wenn
      # er da wäre, wird er nicht mehr gelesen.
      settings = %{"model_stage2" => "qwen2.5:7b", "backend_stage2" => "local"}

      assert Options.display_model(settings, 2, "local") == nil
    end

    test "leerer String zählt als ungesetzt" do
      settings = %{"model_stage2_google" => "  ", "backend_stage2" => "google"}
      assert Options.display_model(settings, 2, "google") == nil
    end
  end

  describe "normalize_settings_params/1 — Save-Param-Normalisierung" do
    test "numerische Keys werden geparst, leere Werte + live_select-Hilfsfelder fliegen raus" do
      params = %{
        "temperature_stage2" => "0.15",
        "ctx_stage2" => "8192",
        "model_stage2_local" => " qwen2.5:7b ",
        "model_stage2_local_text_input" => "qwen",
        "whisper_lang" => ""
      }

      out = Options.normalize_settings_params(params)

      assert out == %{
               "temperature_stage2" => 0.15,
               "ctx_stage2" => 8192,
               "model_stage2_local" => "qwen2.5:7b"
             }
    end

    test "unparsbare Zahl → Key fliegt raus statt String durchzureichen" do
      assert Options.normalize_settings_params(%{"ctx_stage2" => "abc"}) == %{}
    end

    test "#783 Phase 2: Stage-3/4-Sampling-Keys werden genau wie Stage-2 geparst" do
      params = %{
        "temperature_stage3" => "0.0",
        "top_p_stage3" => "0.7",
        "repeat_penalty_stage3" => "1.1",
        "ctx_stage3" => "8192",
        "temperature_stage4" => "0.3",
        "top_p_stage4" => "0.9",
        "repeat_penalty_stage4" => "1.2",
        "ctx_stage4" => "16384"
      }

      out = Options.normalize_settings_params(params)

      assert out == %{
               "temperature_stage3" => 0.0,
               "top_p_stage3" => 0.7,
               "repeat_penalty_stage3" => 1.1,
               "ctx_stage3" => 8192,
               "temperature_stage4" => 0.3,
               "top_p_stage4" => 0.9,
               "repeat_penalty_stage4" => 1.2,
               "ctx_stage4" => 16384
             }
    end
  end
end
