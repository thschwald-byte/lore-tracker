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
        "model_stage4_anthropic" => "claude-haiku-4-5",
        "backend_stage4" => "anthropic"
      }

      assert Options.display_model(settings, 4, "anthropic") == "claude-haiku-4-5"
    end

    test "J4 (#1207): Jacks Modell ist der lokale Stufe-2-Key" do
      assert Options.display_model(%{"model_stage2_local" => "qwen3.8:27b"}, 2, "local") ==
               "qwen3.8:27b"
    end

    test "kein pro-Backend-Key gesetzt → nil (Legacy-Fallback entfernt)" do
      # Ein persistierter Legacy-Key gäbe es nicht mehr im Snapshot; selbst wenn
      # er da wäre, wird er nicht mehr gelesen.
      settings = %{"model_stage4" => "qwen2.5:7b", "backend_stage4" => "local"}

      assert Options.display_model(settings, 4, "local") == nil
    end

    test "leerer String zählt als ungesetzt" do
      settings = %{"model_stage4_google" => "  ", "backend_stage4" => "google"}
      assert Options.display_model(settings, 4, "google") == nil
    end
  end

  describe "normalize_settings_params/1 — Save-Param-Normalisierung" do
    test "numerische Keys werden geparst, leere Werte + live_select-Hilfsfelder fliegen raus" do
      params = %{
        "temperature_stage4" => "0.15",
        "ctx_stage4" => "8192",
        "model_stage2_local" => " qwen2.5:7b ",
        "model_stage2_local_text_input" => "qwen",
        "whisper_lang" => ""
      }

      out = Options.normalize_settings_params(params)

      assert out == %{
               "temperature_stage4" => 0.15,
               "ctx_stage4" => 8192,
               "model_stage2_local" => "qwen2.5:7b"
             }
    end

    test "unparsbare Zahl → Key fliegt raus statt String durchzureichen" do
      assert Options.normalize_settings_params(%{"ctx_jack" => "abc"}) == %{}
    end

    test "J4 (#1207): Jacks Regler werden als Float bzw. ganze Zahl geparst" do
      params = %{
        "jack_temperature" => "0.7",
        "jack_top_p" => "0.8",
        "jack_frequency_penalty" => "0.4",
        "jack_max_tokens" => "60000",
        "ctx_jack" => "98304"
      }

      assert Options.normalize_settings_params(params) == %{
               "jack_temperature" => 0.7,
               "jack_top_p" => 0.8,
               "jack_frequency_penalty" => 0.4,
               "jack_max_tokens" => 60_000,
               "ctx_jack" => 98_304
             }
    end

    test "J4 (#1207): ganzzahlig getippte Float-Regler kommen als Float an" do
      # Ein UI-„1“ bei temperature muss 1.0 werden, nicht der String "1".
      assert Options.normalize_settings_params(%{"jack_temperature" => "1"}) ==
               %{"jack_temperature" => 1.0}
    end

    test "#865: merge_gap_seconds wird als Int geparst" do
      assert Options.normalize_settings_params(%{"merge_gap_seconds" => "8"}) ==
               %{"merge_gap_seconds" => 8}
    end

    test "#865: leeres gapfill_model kommt DURCH (Aus-Schalter, kein Empty-Reject)" do
      out = Options.normalize_settings_params(%{"gapfill_model" => "", "whisper_lang" => ""})
      assert out == %{"gapfill_model" => ""}
    end

    test "#783 Phase 2: Stage-4-Sampling-Keys (Resümee) werden geparst" do
      params = %{
        "temperature_stage4" => "0.3",
        "top_p_stage4" => "0.9",
        "repeat_penalty_stage4" => "1.2",
        "ctx_stage4" => "16384"
      }

      out = Options.normalize_settings_params(params)

      assert out == %{
               "temperature_stage4" => 0.3,
               "top_p_stage4" => 0.9,
               "repeat_penalty_stage4" => 1.2,
               "ctx_stage4" => 16384
             }
    end

    test "#783 Phase 2 Nachtrag: Stage-5-Sampling-Keys (Epos) werden genau wie Stage-4 geparst" do
      params = %{
        "temperature_stage5" => "0.4",
        "top_p_stage5" => "0.85",
        "repeat_penalty_stage5" => "1.05",
        "ctx_stage5" => "32768"
      }

      out = Options.normalize_settings_params(params)

      assert out == %{
               "temperature_stage5" => 0.4,
               "top_p_stage5" => 0.85,
               "repeat_penalty_stage5" => 1.05,
               "ctx_stage5" => 32768
             }
    end
  end
end
