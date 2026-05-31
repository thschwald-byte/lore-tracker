defmodule HubWeb.CampaignLiveHelpersTest do
  @moduledoc """
  Issue #379: Public Helper-Funktionen aus `HubWeb.CampaignLive` für
  Utterance-Status + ASR-Confidence-Flag.
  """

  use ExUnit.Case, async: true

  alias HubWeb.CampaignLive

  describe "asr_uncertain?/1" do
    test "true bei niedrigem min_p + confirmed-Status + echter ASR-Variation" do
      u = %{
        "status" => "confirmed",
        "confidence" => %{"mean_p" => 0.72, "min_p" => 0.42}
      }

      assert CampaignLive.asr_uncertain?(u)
    end

    test "true bei live-Status (Live-Transkription)" do
      u = %{"status" => "live", "confidence" => %{"mean_p" => 0.6, "min_p" => 0.3}}
      assert CampaignLive.asr_uncertain?(u)
    end

    test "false bei hohem min_p" do
      u = %{"status" => "confirmed", "confidence" => %{"mean_p" => 0.95, "min_p" => 0.85}}
      refute CampaignLive.asr_uncertain?(u)
    end

    test "false bei edited-Status (menschliche Korrektur, kein ASR-Flag)" do
      u = %{"status" => "edited", "confidence" => %{"mean_p" => 0.5, "min_p" => 0.2}}
      refute CampaignLive.asr_uncertain?(u)
    end

    test "false bei Platzhalter-Confidence (mean == min — typisch für to_confidence_map-Float-Upgrade)" do
      # Materializer-Bug: manual fällt auf :confirmed zurück.
      # Defense-in-depth: zusätzlicher mean==min-Check fängt das ab.
      u = %{"status" => "confirmed", "confidence" => %{"mean_p" => 0.3, "min_p" => 0.3}}
      refute CampaignLive.asr_uncertain?(u)
    end

    test "false bei nil-Confidence (keine Messung)" do
      u = %{"status" => "confirmed", "confidence" => nil}
      refute CampaignLive.asr_uncertain?(u)
    end

    test "false bei fehlendem Confidence-Key" do
      u = %{"status" => "confirmed"}
      refute CampaignLive.asr_uncertain?(u)
    end

    test "false bei Float-Altwert (kein Map-Pattern-Match)" do
      u = %{"status" => "confirmed", "confidence" => 0.42}
      refute CampaignLive.asr_uncertain?(u)
    end

    test "Threshold-Boundary: exakt 0.5 ist NICHT geflaggt (Schwelle ist strict <)" do
      u = %{"status" => "confirmed", "confidence" => %{"mean_p" => 0.7, "min_p" => 0.5}}
      refute CampaignLive.asr_uncertain?(u)
    end

    test "Threshold-Boundary: 0.499 IST geflaggt" do
      u = %{"status" => "confirmed", "confidence" => %{"mean_p" => 0.7, "min_p" => 0.499}}
      assert CampaignLive.asr_uncertain?(u)
    end
  end

  describe "uncertainty_tooltip/1" do
    test "formatiert min_p und mean_p auf 2 Dezimalen" do
      u = %{"confidence" => %{"min_p" => 0.4234, "mean_p" => 0.7567}}
      tooltip = CampaignLive.uncertainty_tooltip(u)

      assert tooltip =~ "0.42"
      assert tooltip =~ "0.76"
      assert tooltip =~ "ASR-Unsicherheit"
      assert tooltip =~ "kein Fehler-Marker"
    end

    test "enthält Längen-Bias-Caveat (Real-Data-Reminder)" do
      u = %{"confidence" => %{"min_p" => 0.3, "mean_p" => 0.7}}
      assert CampaignLive.uncertainty_tooltip(u) =~ "lange Utterances"
    end

    test "Fallback bei fehlender Confidence" do
      assert CampaignLive.uncertainty_tooltip(%{}) == "ASR-Unsicherheit"
      assert CampaignLive.uncertainty_tooltip(%{"confidence" => nil}) == "ASR-Unsicherheit"
    end
  end

  describe "status_label/1" do
    test "alle vier bekannten Status" do
      assert CampaignLive.status_label("confirmed") == "bestätigt"
      assert CampaignLive.status_label("live") == "live (Transkription läuft)"
      assert CampaignLive.status_label("edited") == "editiert"
      assert CampaignLive.status_label("manual") == "manuell hinzugefügt"
    end

    test "nil → confirmed-Default (Seed-Events ohne explicit status)" do
      assert CampaignLive.status_label(nil) == "bestätigt"
    end

    test "unbekannter Status → sichtbar mit Wert (kein stilles Verschwinden)" do
      label = CampaignLive.status_label("refined")
      assert label =~ "unbekannter Status"
      assert label =~ "refined"
    end
  end

  describe "status_dot_class/1" do
    test "mappt jeden bekannten Status auf eine Theme-Token-Klasse" do
      assert CampaignLive.status_dot_class("confirmed") == "bg-success"
      assert CampaignLive.status_dot_class("live") =~ "bg-accent"
      assert CampaignLive.status_dot_class("live") =~ "animate-pulse"
      assert CampaignLive.status_dot_class("edited") == "bg-warning"
      assert CampaignLive.status_dot_class("manual") == "bg-accent-soft"
    end

    test "deleted → nil (Tombstone, kein Render)" do
      assert CampaignLive.status_dot_class("deleted") == nil
    end

    test "unbekannter Status → bg-ink-2 (sichtbar grau statt stilles Weglassen)" do
      assert CampaignLive.status_dot_class("refined") == "bg-ink-2"
      assert CampaignLive.status_dot_class("garbage") == "bg-ink-2"
    end

    test "nil → confirmed-Default" do
      assert CampaignLive.status_dot_class(nil) == "bg-success"
    end
  end
end
