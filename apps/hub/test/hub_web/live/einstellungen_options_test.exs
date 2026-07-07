defmodule HubWeb.EinstellungenLive.OptionsTest do
  @moduledoc """
  Issue #451 (Track C): die puren Options-/Normalisierungs-Helfer der
  Settings-LV (`HubWeb.EinstellungenLive.Options`) — insbesondere die
  Anzeige-Auflösung `display_model/3` (pro-Backend-Key vs. Legacy-Key)
  und die Form-Param-Normalisierung der Save-Pfade.
  """

  use ExUnit.Case, async: true

  alias HubWeb.EinstellungenLive.Options

  describe "display_model/3 — Anzeige-Modell einer Backend-Box" do
    test "pro-Backend-Key gewinnt" do
      settings = %{
        "model_stage2_anthropic" => "claude-haiku-4-5",
        "model_stage2" => "qwen2.5:7b",
        "backend_stage2" => "anthropic"
      }

      assert Options.display_model(settings, 2, "anthropic") == "claude-haiku-4-5"
    end

    test "Legacy-Key zählt NUR für das aktive Backend (pre-Track-C-Semantik)" do
      settings = %{"model_stage2" => "qwen2.5:7b", "backend_stage2" => "local"}

      assert Options.display_model(settings, 2, "local") == "qwen2.5:7b"
      # Unter einem INAKTIVEN Backend wäre der Legacy-Wert irreführend.
      assert Options.display_model(settings, 2, "anthropic") == nil
    end

    test "fehlendes backend_stage{n} zählt als local aktiv" do
      settings = %{"model_stage3" => "command-r"}
      assert Options.display_model(settings, 3, "local") == "command-r"
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
      assert Options.normalize_settings_params(%{"ctx_stage3" => "abc"}) == %{}
    end
  end
end
